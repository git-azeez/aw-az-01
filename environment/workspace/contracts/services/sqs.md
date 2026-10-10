# SQS Main Queue and Dead-Letter Queue (`services/sqs.md`)

- Provision a dead-letter queue (`aws_sqs_queue`) encrypted with the customer-managed `messaging` KMS key (`kms_master_key_id = kms.messaging_arn`) and `message_retention_seconds = 1209600` (14 days).
- Provision the main event queue (`aws_sqs_queue`) with:
  - `kms_master_key_id = kms.messaging_arn`
  - `visibility_timeout_seconds = 3`
  - `receive_wait_time_seconds = 2`
  - `message_retention_seconds = 172800` (2 days)
  - Redrive policy (configured either inline via `redrive_policy` on `aws_sqs_queue` or via a standalone `aws_sqs_queue_redrive_policy` resource) routing failed messages to the DLQ with `maxReceiveCount = 4` (`manifest.messaging.max_receive_count = 4`).
- Attach resource-based queue policies (`aws_sqs_queue.policy` or `aws_sqs_queue_policy`) to both the main event queue and the DLQ:
  - **Main event queue policy**:
    - Explicitly allows (`Effect = "Allow"`) `sqs:SendMessage`, `sqs:GetQueueAttributes`, and `sqs:GetQueueUrl` for `iam.ecs_task_role_arn` and `iam.relay_role_arn`, and `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:GetQueueAttributes`, and `sqs:ChangeMessageVisibility` for `iam.projector_role_arn`.
    - Explicitly denies (`Effect = "Deny"`) `sqs:SendMessage` on the main queue ARN for `iam.ecs_execution_role_arn`, `iam.projector_role_arn`, `iam.archiver_role_arn`, and `iam.scheduler_role_arn`, and explicitly denies (`Effect = "Deny"`) `sqs:ReceiveMessage` and `sqs:DeleteMessage` on the main queue ARN for `iam.ecs_execution_role_arn`, `iam.ecs_task_role_arn`, `iam.relay_role_arn`, `iam.archiver_role_arn`, and `iam.scheduler_role_arn`.
  - **Dead-letter queue (DLQ) policy**:
    - Explicitly allows (`Effect = "Allow"`) `sqs:SendMessage` on the DLQ ARN for `iam.projector_role_arn`.
    - Explicitly denies (`Effect = "Deny"`) `sqs:ReceiveMessage` and `sqs:DeleteMessage` on the DLQ ARN for all six ClearLedger workload IAM role ARNs (`ecs_execution`, `ecs_task`, `projector`, `relay`, `archiver`, `scheduler`), and explicitly denies (`Effect = "Deny"`) `sqs:SendMessage` on the DLQ ARN for the five non-projector ClearLedger workload IAM role ARNs (`ecs_execution`, `ecs_task`, `relay`, `archiver`, `scheduler`).
- If the main queue or its Lambda event source mapping is deleted during an outage drill, or if queue attributes or queue policies drift out-of-band, re-running `deploy.sh` must reconcile or recreate the queue and policies, re-bind its Lambda event source mapping cleanly, update `manifest.json`, and drain/reconcile any pending outbox events, projections, and audit archives before exiting `0`.
