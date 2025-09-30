#!/bin/bash
######################################################################
# MEDIALAB
######################################################################

set -e

CONFIG_FILE="s3-notification-config.json"

echo "============================================="
echo "S3 Event Notification Configuration Script"
echo "============================================="
echo

validate_arn() {
    local arn="$1"
    if [[ ! "$arn" =~ ^arn:aws:sqs:[a-z0-9-]+:[0-9]+:[a-zA-Z0-9_-]+$ ]]; then
        echo "Invalid ARN format. Expected: arn:aws:sqs:region:account-id:queue-name"
        return 1
    fi
    return 0
}

validate_and_convert_bucket() {
    local input="$1"

    if [[ "$input" =~ ^arn:aws:s3:::(.+)$ ]]; then
        bucket_name="${BASH_REMATCH[1]}"
        if validate_bucket_name "$bucket_name"; then
            echo "$bucket_name"
            return 0
        else
            echo "Invalid bucket name extracted from ARN: $bucket_name" >&2
            return 1
        fi
    fi

    if validate_bucket_name "$input"; then
        echo "$input"
        return 0
    fi

    if [[ "$input" =~ ^arn:(aws).*:(s3|s3-object-lambda):[a-z\-0-9]*:[0-9]{12}:accesspoint[/:][a-zA-Z0-9\-.]{1,63}$ ]] || \
       [[ "$input" =~ ^arn:(aws).*:s3-outposts:[a-z\-0-9]+:[0-9]{12}:outpost[/:][a-zA-Z0-9\-]{1,63}[/:]accesspoint[/:][a-zA-Z0-9\-]{1,63}$ ]]; then
        echo "$input"
        return 0
    fi

    echo "Invalid input. Use either:" >&2
    echo "  - Bucket name: my-bucket-name" >&2
    echo "  - Bucket ARN: arn:aws:s3:::my-bucket-name (will extract bucket name)" >&2
    echo "  - Access point ARN (passed through as-is)" >&2
    return 1
}

validate_bucket_name() {
    local bucket="$1"

    # Basic length check
    if [[ ${#bucket} -lt 3 || ${#bucket} -gt 63 ]]; then
        return 1
    fi

    if [[ ! "$bucket" =~ ^[a-z0-9] ]] || [[ ! "$bucket" =~ [a-z0-9]$ ]]; then
        return 1
    fi

    if [[ ! "$bucket" =~ ^[a-z0-9.-]+$ ]]; then
        return 1
    fi

    if [[ "$bucket" =~ \.\. ]]; then
        return 1
    fi

    if [[ "$bucket" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 1
    fi

    return 0
}

while true; do
    echo -n "Enter the SQS Queue ARN: "
    read -r SQS_ARN

    if [ -z "$SQS_ARN" ]; then
        echo "Error: SQS ARN cannot be empty"
        continue
    fi

    if validate_arn "$SQS_ARN"; then
        break
    fi
done

echo
echo "SQS ARN: $SQS_ARN"
echo

validate_and_convert_bucket() {
    local input="$1"

    if [[ "$input" =~ ^arn:aws:s3:::(.+)$ ]]; then
        bucket_name="${BASH_REMATCH[1]}"
        echo "$bucket_name"
        return 0
    fi

    echo "$input"
    return 0
}

echo "Enter S3 bucket names or ARNs (one per line, press Enter on empty line to finish):"
echo "Examples:"
echo "  - Bucket name: my-bucket-name"
echo "  - Bucket ARN:  arn:aws:s3:::my-bucket-name (bucket name will be extracted)"
BUCKET_CONFIGS=()
bucket_count=0

while true; do
    echo -n "Bucket/ARN $((bucket_count + 1)): "
    read -r bucket_input

    if [ -z "$bucket_input" ]; then
        break
    fi

    converted_bucket=$(validate_and_convert_bucket "$bucket_input")

    echo -n "  Path filter (optional, e.g., 'clips/', press Enter for entire bucket): "
    read -r path_filter

    if [ -n "$path_filter" ] && [[ ! "$path_filter" =~ /$ ]]; then
        path_filter="$path_filter/"
        echo "  → Auto-corrected path to: $path_filter"
    fi

    BUCKET_CONFIGS+=("$converted_bucket|$path_filter")
    ((bucket_count++))

    if [ -n "$path_filter" ]; then
        if [ "$bucket_input" != "$converted_bucket" ]; then
            echo "  ✓ Added: $converted_bucket (extracted from ARN) with path filter: $path_filter"
        else
            echo "  ✓ Added: $converted_bucket with path filter: $path_filter"
        fi
    else
        if [ "$bucket_input" != "$converted_bucket" ]; then
            echo "  ✓ Added: $converted_bucket (extracted from ARN) - entire bucket"
        else
            echo "  ✓ Added: $converted_bucket - entire bucket"
        fi
    fi
done

if [ ${#BUCKET_CONFIGS[@]} -eq 0 ]; then
    echo "Error: No valid buckets/ARNs provided. Exiting."
    exit 1
fi

echo
echo "Summary:"
echo "--------"
echo "SQS ARN: $SQS_ARN"
echo "Bucket configurations: ${#BUCKET_CONFIGS[@]}"
for i in "${!BUCKET_CONFIGS[@]}"; do
    IFS='|' read -r bucket path <<< "${BUCKET_CONFIGS[$i]}"
    if [ -n "$path" ]; then
        echo "  $((i + 1)). $bucket (path: $path)"
    else
        echo "  $((i + 1)). $bucket (entire bucket)"
    fi
done

echo
read -p "Proceed with configuration? (y/N): " -r confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Configuration cancelled."
    exit 0
fi

echo
echo "=== Starting Configuration ==="

echo
echo "Select events to monitor:"
echo "1. Basic events (Created, Removed)"
echo "2. All events (Created, Removed, Lifecycle, Restore)"
echo -n "Enter choice (1 or 2) [default: 2]: "
read -r event_choice

case "$event_choice" in
    1)
        events='["s3:ObjectCreated:*","s3:ObjectRemoved:*"]'
        echo "Selected: Basic events"
        ;;
    *)
        events='["s3:ObjectCreated:*","s3:ObjectRemoved:*","s3:LifecycleTransition","s3:ObjectRestore:*"]'
        echo "Selected: All events"
        ;;
esac

echo
echo "Creating notification configuration..."

queue_configs=""
config_count=0

for bucket_config in "${BUCKET_CONFIGS[@]}"; do
    IFS='|' read -r bucket path <<< "$bucket_config"

    if [ $config_count -gt 0 ]; then
        queue_configs+=","
    fi

    config_entry="    {
      \"Id\": \"S3EventNotification-$((config_count + 1))\",
      \"QueueArn\": \"$SQS_ARN\",
      \"Events\": $events"

    if [ -n "$path" ]; then
        config_entry+=",
      \"Filter\": {
        \"Key\": {
          \"FilterRules\": [
            {
              \"Name\": \"prefix\",
              \"Value\": \"$path\"
            }
          ]
        }
      }"
    fi

    config_entry+="
    }"

    queue_configs+="$config_entry"
    ((config_count++))
done

cat > "$CONFIG_FILE" << EOF
{
  "QueueConfigurations": [
$queue_configs
  ]
}
EOF

echo "Configuration file created: $CONFIG_FILE"

echo
echo "Applying configuration to buckets..."
failed_buckets=()
error_messages=()

for bucket_config in "${BUCKET_CONFIGS[@]}"; do
    IFS='|' read -r bucket path <<< "$bucket_config"

    echo -n "Configuring bucket: $bucket"
    if [ -n "$path" ]; then
        echo -n " (path: $path)"
    fi
    echo -n "... "

    if [ -n "$path" ]; then
        cat > "$CONFIG_FILE" << EOF
{
  "QueueConfigurations": [
    {
      "Id": "MediaLabSQSNotification",
      "QueueArn": "$SQS_ARN",
      "Events": $events,
      "Filter": {
        "Key": {
          "FilterRules": [
            {
              "Name": "prefix",
              "Value": "$path"
            }
          ]
        }
      }
    }
  ]
}
EOF
    else
        cat > "$CONFIG_FILE" << EOF
{
  "QueueConfigurations": [
    {
      "Id": "MediaLabSQSNotification",
      "QueueArn": "$SQS_ARN",
      "Events": $events
    }
  ]
}
EOF
    fi

    error_output=$(mktemp)
    if aws s3api put-bucket-notification-configuration \
        --bucket "$bucket" \
        --notification-configuration "file://$CONFIG_FILE" \
        --skip-destination-validation 2>"$error_output"; then
        echo "✓ Success"
        rm -f "$error_output"
    else
        echo "✗ Failed"
        failed_buckets+=("$bucket")
        error_msg=$(cat "$error_output" 2>/dev/null || echo "Unknown error")
        error_messages+=("$bucket: $error_msg")
        rm -f "$error_output"
    fi
done

unique_bucket_count=${#BUCKET_CONFIGS[@]}

echo
echo "=== Configuration Summary ==="
echo "Total buckets: $unique_bucket_count"
echo "Successfully configured: $((unique_bucket_count - ${#failed_buckets[@]}))"
echo "Failed: ${#failed_buckets[@]}"

if [ ${#failed_buckets[@]} -gt 0 ]; then
    echo
    echo "Failed buckets with error details:"
    for i in "${!error_messages[@]}"; do
        echo "  - ${error_messages[$i]}"
    done
fi

if [ $((${#BUCKETS[@]} - ${#failed_buckets[@]})) -gt 0 ]; then
    echo
    echo "Verifying configuration (checking first successful bucket)..."
    for bucket in "${BUCKETS[@]}"; do
        if [[ ! " ${failed_buckets[*]} " =~ " ${bucket} " ]]; then
            echo "Verification for bucket: $bucket"
            if aws s3api get-bucket-notification-configuration --bucket "$bucket" --output table 2>/dev/null; then
                echo "✓ Notification configuration verified"
            else
                echo "⚠ Could not verify configuration for $bucket"
            fi
            break
        fi
    done
fi

echo
echo "Cleaning up configuration file..."
rm -f "$CONFIG_FILE"

echo
echo "=== Configuration Complete ==="
if [ ${#failed_buckets[@]} -eq 0 ]; then
    echo "✓ All buckets configured successfully"
    echo "S3 events will now be sent to the specified SQS queue"
    exit 0
else
    echo "⚠ Some buckets failed to configure. Check error details above."
    echo "Successfully configured buckets will send events to the SQS queue"
    exit 1
fi
