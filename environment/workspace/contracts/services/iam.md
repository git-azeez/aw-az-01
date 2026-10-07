# IAM Roles and Least-Privilege Policies (`services/iam.md`)

Provision six distinct IAM roles (`aws_iam_role`) with role-specific inline or attached policies (`aws_iam_role_policy` or `aws_iam_policy` + `aws_iam_role_policy_attachment`).

## Global Least-Privilege Rules

- Never use wildcard actions (`Action = "*"` or `service:*`) or wildcard resources (`Resource = "*"`) in any role policy.
- **Per-workload CloudWatch Log Group isolation**: Each logging workload (`ecs_execution`, `ecs_task`, `projector`, `relay`, `archiver`) may only grant CloudWatch Logs write permissions (`logs:CreateLogStream`, `logs:PutLogEvents`, `logs:DescribeLogStreams`) on its **own** dedicated CloudWatch Log Group ARN (`arn:aws:logs:<region>:<account>:log-group:/clearledger/<resource_prefix>/<workload>*`). Do not use a shared `/clearledger/<resource_prefix>/*` or `/clearledger/*` log group wildcard that permits one workload to write into another workload's log group, and do not grant any CloudWatch Logs actions to `scheduler_role_arn`.
- **Strict KMS key isolation across all six roles**: Each workload may only be granted `kms:Decrypt`, `kms:GenerateDataKey`, and `kms:DescribeKey` on the specific customer-managed KMS keys required for the data stores it accesses at runtime. No role may grant `kms:Decrypt` or `kms:GenerateDataKey` on any of the other KMS keys, and `ecs_execution_role_arn` and `scheduler_role_arn` must not grant access to any of the four KMS keys.

## Role Responsibilities and Access Boundaries

1. **`ecs_execution_role_arn`**:
   - **Trust principal**: `ecs-tasks.amazonaws.com` (and no other service or wildcard principal).
   - **Allowed access**: CloudWatch Logs stream creation/writing (`logs:CreateLogStream`, `logs:PutLogEvents`, `logs:DescribeLogStreams`) scoped strictly to `logs.api_log_group`.
   - **Forbidden access**: Must not grant any SQS, DynamoDB, S3, Lambda, KMS, or non-API CloudWatch Log Group permissions.
2. **`ecs_task_role_arn`**:
   - **Trust principal**: `ecs-tasks.amazonaws.com`.
   - **Allowed access**:
     - Publish-only access on the main SQS queue ARN (`sqs:SendMessage`, `sqs:GetQueueAttributes`, `sqs:GetQueueUrl`).
     - Read-only access on the projection DynamoDB table ARN and its `AccountIndex` GSI ARN `<table_arn>/index/AccountIndex` (`dynamodb:GetItem`, `dynamodb:Query`, `dynamodb:DescribeTable`).
     - Cryptographic usage (`kms:Decrypt`, `kms:GenerateDataKey`, `kms:DescribeKey`) on the `messaging` and `projection` KMS key ARNs only.
     - CloudWatch Logs stream creation/writing scoped strictly to `logs.api_log_group`.
   - **Forbidden access**: Must not allow consuming or deleting SQS messages (`sqs:ReceiveMessage`, `sqs:DeleteMessage`) or publishing to the DLQ; must not allow mutating DynamoDB (`dynamodb:PutItem`, `dynamodb:UpdateItem`, `dynamodb:DeleteItem`); must not allow S3 access; must not allow `kms:Decrypt` or `kms:GenerateDataKey` on the `database` or `audit` KMS keys; must not allow writing to any non-API log group.
3. **`projector_role_arn`**:
   - **Trust principal**: `lambda.amazonaws.com`.
   - **Allowed access**:
     - Consume-only access on the main SQS queue ARN (`sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:GetQueueAttributes`, `sqs:ChangeMessageVisibility`) and dead-letter forwarding (`sqs:SendMessage`) on the DLQ ARN.
     - Append/monotonic-upsert access on the projection DynamoDB table ARN and its `AccountIndex` GSI ARN (`dynamodb:GetItem`, `dynamodb:PutItem`, `dynamodb:UpdateItem`, `dynamodb:Query`).
     - Cryptographic usage (`kms:Decrypt`, `kms:GenerateDataKey`, `kms:DescribeKey`) on the `messaging` and `projection` KMS key ARNs only.
     - CloudWatch Logs stream creation/writing scoped strictly to `logs.projector_log_group`.
   - **Forbidden access**: Must not allow `sqs:SendMessage` on the main queue or `sqs:ReceiveMessage`/`sqs:DeleteMessage` on the DLQ; must not allow deleting DynamoDB items (`dynamodb:DeleteItem`) or tables (`dynamodb:DeleteTable`); must not allow S3 access; must not allow `kms:Decrypt` or `kms:GenerateDataKey` on the `database` or `audit` KMS keys; must not allow writing to any non-projector log group.
4. **`relay_role_arn`**:
   - **Trust principal**: `lambda.amazonaws.com`.
   - **Allowed access**:
     - Publish-only access on the main SQS queue ARN (`sqs:SendMessage`, `sqs:GetQueueAttributes`, `sqs:GetQueueUrl`).
     - Cryptographic usage (`kms:Decrypt`, `kms:GenerateDataKey`, `kms:DescribeKey`) on the `messaging` and `database` KMS key ARNs only.
     - CloudWatch Logs stream creation/writing scoped strictly to `logs.relay_log_group`.
   - **Forbidden access**: Must not allow `sqs:ReceiveMessage`, `sqs:DeleteMessage`, or DLQ access; must not allow any DynamoDB or S3 actions; must not allow `kms:Decrypt` or `kms:GenerateDataKey` on the `projection` or `audit` KMS keys; must not allow writing to any non-relay log group.
5. **`archiver_role_arn`**:
   - **Trust principal**: `lambda.amazonaws.com`.
   - **Allowed access**:
     - Append-only object access (`s3:PutObject`, `s3:GetObject`, `s3:AbortMultipartUpload`) scoped strictly to `<audit_bucket_arn>/ledger-audit/*`, plus bucket-level read metadata (`s3:ListBucket`, `s3:GetBucketLocation`) on `<audit_bucket_arn>`.
     - Cryptographic usage (`kms:Decrypt`, `kms:GenerateDataKey`, `kms:DescribeKey`) on the `audit` and `database` KMS key ARNs only.
     - CloudWatch Logs stream creation/writing scoped strictly to `logs.archiver_log_group`.
   - **Forbidden access**: Must not grant `s3:PutObject` on the unscoped `<audit_bucket_arn>/*` root wildcard; must not grant `s3:DeleteObject` or `s3:DeleteObjectVersion` anywhere on the audit bucket; must not allow any SQS or DynamoDB actions; must not allow `kms:Decrypt` or `kms:GenerateDataKey` on the `messaging` or `projection` KMS keys; must not allow writing to any non-archiver log group.
6. **`scheduler_role_arn`**:
   - **Trust principal**: `scheduler.amazonaws.com`.
   - **Allowed access**:
     - `lambda:InvokeFunction` scoped strictly to the Outbox Relay (`workers.outbox_relay.function_arn`) and Audit Archiver (`workers.audit_archiver.function_arn`) Lambda function ARNs.
   - **Forbidden access**: Must not allow invoking the Projector Lambda (`workers.projector.function_arn`), and must not allow any SQS, DynamoDB, S3, KMS, or CloudWatch Logs actions.
