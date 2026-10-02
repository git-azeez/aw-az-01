# SQS Main Queue and Dead-Letter Queue (`services/sqs.md`)

- Provision a dead-letter queue (`aws_sqs_queue`) encrypted with the customer-managed `messaging` KMS key (`kms_master_key_id = kms.messaging_arn`) and `message_retention_seconds = 1209600` (14 days).
- Provision the main event queue (`aws_sqs_queue`) with:
  - `kms_master_key_id = kms.messaging_arn`
  - `visibility_timeout_seconds = 3`
  - `receive_wait_time_seconds = 2`
  - `message_retention_seconds = 172800` (2 days)
  - `redrive_policy` routing failed messages to the DLQ with `maxReceiveCount = 4` (`manifest.messaging.max_receive_count = 4`)
- If the main queue is deleted during an outage drill, re-running `deploy.sh` must recreate the queue and re-bind its Lambda event source mapping cleanly.
