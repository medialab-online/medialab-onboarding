# S3 Event Notification Configuration Script

Configure your S3 buckets to send event notifications to MediaLab's SQS queue.

## Quick Start

```bash
chmod +x configure-s3-events.sh
./configure-s3-events.sh
```

## Usage

The script will prompt you for:

1. **SQS Queue ARN**

    Use SQS queue ARN provided by MediaLab. 
   ```
   arn:aws:sqs:region:account-id:queue-name
   ```

2. **Your S3 Buckets** (one per line, empty line to finish)
    - Bucket name: `my-bucket`
    - Bucket ARN: `arn:aws:s3:::my-bucket`

3. **Path filter** (optional, for each bucket)
    - Leave empty for entire bucket
    - Enter folder path: `clips` or `videos/processed`
    - Trailing slash is added automatically

4. **Event types**
    - Basic: Created, Removed
    - All: Created, Removed, Lifecycle, Restore

## Prerequisites

- AWS CLI installed and configured with credentials for your S3 buckets
- Permissions: `s3:PutBucketNotification` on your buckets

## Example

```
Enter the SQS Queue ARN: arn:aws:sqs:region:account-id:queue-name

Bucket/ARN 1: my-videos
  Path filter: uploads
  → Auto-corrected path to: uploads/
  ✓ Added: my-videos with path filter: uploads/

Bucket/ARN 2: my-photos
  Path filter: 
  ✓ Added: my-photos - entire bucket

Bucket/ARN 3: 

Proceed with configuration? (y/N): y
```