# IAM Roles and Least-Privilege Policies (`services/iam.md`)

Provision six distinct IAM roles (`aws_iam_role`) with role-specific inline or attached policies (`aws_iam_role_policy` or `aws_iam_policy` + `aws_iam_role_policy_attachment`).

## Global Least-Privilege Rules

- Never use wildcard actions (`Action = "*"` or `service:*`) or wildcard resources (`Resource = "*"`) in any `Allow` statement across any role policy.
- **Per-workload CloudWatch Log Group isolation**: Each logging workload (`ecs_execution`, `ecs_task`, `projector`, `relay`, `archiver`) may only grant CloudWatch Logs write permissions (`logs:CreateLogStream`, `logs:PutLogEvents`, `logs:DescribeLogStreams`) on its **own** dedicated CloudWatch Log Group ARN (`arn:aws:logs:<region>:<account>:log-group:/clearledger/<resource_prefix>/<workload>*`). Do not use a shared `/clearledger/<resource_prefix>/*` or `/clearledger/*` log group wildcard that permits one workload to write into another workload's log group, and do not grant any CloudWatch Logs actions to `scheduler_role_arn`.
- **Strict KMS key isolation across all six roles**: Each workload may only be granted `kms:Decrypt`, `kms:GenerateDataKey`, and `kms:DescribeKey` on the specific customer-managed KMS keys required for the data stores it accesses at runtime. No role may grant `kms:Decrypt` or `kms:GenerateDataKey` on any of the other KMS keys, and `ecs_execution_role_arn` and `scheduler_role_arn` must not grant access to any of the four KMS keys.
- **Defense-in-depth explicit `Deny` guardrail statements**: Do not rely solely on implicit omission for forbidden permissions. Every role's policy document must include explicit `Effect = "Deny"` statement(s) covering all forbidden actions and resources listed under **Forbidden access (`Effect = "Deny"` required)** for that role below.
- **Out-of-band IAM policy drift reconciliation in `deploy.sh`**: During `deploy.sh`, any out-of-band inline policies (`DeleteRolePolicy`) or attached customer-managed/AWS-managed policies (`DetachRolePolicy`) added to any of the six ClearLedger IAM roles outside Terraform/OpenTofu must be removed so that each role retains only its canonical least-privilege policy.

## Role Responsibilities and Access Boundaries

1. **`ecs_execution_role_arn`**:
   - **Trust principal**: `ecs-tasks.amazonaws.com` (and no other service or wildcard principal).
   - **Allowed access (`Effect = "Allow"`)**: CloudWatch Logs stream creation/writing (`logs:CreateLogStream`, `logs:PutLogEvents`, `logs:DescribeLogStreams`) scoped strictly to `logs.api_log_group`.
   - **Forbidden access (`Effect = "Deny"` required)**: Must not allow, and must explicitly deny via `Effect = "Deny"`, any SQS actions (`sqs:SendMessage`, `sqs:ReceiveMessage`, `sqs:DeleteMessage`) on the main queue or DLQ, any DynamoDB actions (`dynamodb:GetItem`, `dynamodb:PutItem`, `dynamodb:UpdateItem`, `dynamodb:DeleteItem`, `dynamodb:Query`) on the projection table or `AccountIndex`, any S3 actions (`s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:ListBucket`) on the audit bucket (`<audit_bucket_arn>` and `<audit_bucket_arn>/*`), `kms:Decrypt` or `kms:GenerateDataKey` on all four KMS keys (`database`, `messaging`, `projection`, `audit`), and `logs:CreateLogStream` or `logs:PutLogEvents` on the three non-API CloudWatch Log Groups (`projector`, `relay`, `archiver`).
2. **`ecs_task_role_arn`**:
   - **Trust principal**: `ecs-tasks.amazonaws.com`.
   - **Allowed access (`Effect = "Allow"`)**:
     - Publish-only access on the main SQS queue ARN (`sqs:SendMessage`, `sqs:GetQueueAttributes`, `sqs:GetQueueUrl`).
     - Read-only access on the projection DynamoDB table ARN and its specific `AccountIndex` GSI ARN `<table_arn>/index/AccountIndex` (`dynamodb:GetItem`, `dynamodb:Query`, `dynamodb:DescribeTable`; do not use `<table_arn>/index/*` or `<table_arn>/*` wildcards).
     - Cryptographic usage (`kms:Decrypt`, `kms:GenerateDataKey`, `kms:DescribeKey`) on the `messaging` and `projection` KMS key ARNs only.
     - CloudWatch Logs stream creation/writing scoped strictly to `logs.api_log_group`.
   - **Forbidden access (`Effect = "Deny"` required)**: Must not allow, and must explicitly deny via `Effect = "Deny"`, consuming or deleting SQS messages (`sqs:ReceiveMessage`, `sqs:DeleteMessage`) on the main queue or `sqs:SendMessage`/`sqs:ReceiveMessage`/`sqs:DeleteMessage` on the DLQ; mutating DynamoDB (`dynamodb:PutItem`, `dynamodb:UpdateItem`, `dynamodb:DeleteItem`, `dynamodb:DeleteTable`) on the projection table; any S3 access (`s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:ListBucket`) on `<audit_bucket_arn>` and `<audit_bucket_arn>/*`; `kms:Decrypt` or `kms:GenerateDataKey` on the `database` and `audit` KMS keys; and `logs:CreateLogStream` or `logs:PutLogEvents` on any non-API log group (`projector`, `relay`, `archiver`). Furthermore, must not grant `dynamodb:Query` on `<table_arn>/index/*`.
3. **`projector_role_arn`**:
   - **Trust principal**: `lambda.amazonaws.com`.
   - **Allowed access (`Effect = "Allow"`)**:
     - Consume-only access on the main SQS queue ARN (`sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:GetQueueAttributes`, `sqs:ChangeMessageVisibility`) and dead-letter forwarding (`sqs:SendMessage`) on the DLQ ARN.
     - Append/monotonic-upsert access on the projection DynamoDB table ARN and its specific `AccountIndex` GSI ARN `<table_arn>/index/AccountIndex` (`dynamodb:GetItem`, `dynamodb:PutItem`, `dynamodb:UpdateItem`, `dynamodb:Query`; do not use `<table_arn>/index/*` or `<table_arn>/*` wildcards).
     - Cryptographic usage (`kms:Decrypt`, `kms:GenerateDataKey`, `kms:DescribeKey`) on the `messaging` and `projection` KMS key ARNs only.
     - CloudWatch Logs stream creation/writing scoped strictly to `logs.projector_log_group`.
   - **Forbidden access (`Effect = "Deny"` required)**: Must not allow, and must explicitly deny via `Effect = "Deny"`, `sqs:SendMessage` on the main queue or `sqs:ReceiveMessage`/`sqs:DeleteMessage` on the DLQ; deleting DynamoDB items (`dynamodb:DeleteItem`) or tables (`dynamodb:DeleteTable`) on the projection table; any S3 access (`s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:ListBucket`) on `<audit_bucket_arn>` and `<audit_bucket_arn>/*`; `kms:Decrypt` or `kms:GenerateDataKey` on the `database` and `audit` KMS keys; and `logs:CreateLogStream` or `logs:PutLogEvents` on any non-projector log group (`api`, `relay`, `archiver`). Furthermore, must not grant `dynamodb:Query` on `<table_arn>/index/*`.
4. **`relay_role_arn`**:
   - **Trust principal**: `lambda.amazonaws.com`.
   - **Allowed access (`Effect = "Allow"`)**:
     - Publish-only access on the main SQS queue ARN (`sqs:SendMessage`, `sqs:GetQueueAttributes`, `sqs:GetQueueUrl`).
     - Cryptographic usage (`kms:Decrypt`, `kms:GenerateDataKey`, `kms:DescribeKey`) on the `messaging` and `database` KMS key ARNs only.
     - CloudWatch Logs stream creation/writing scoped strictly to `logs.relay_log_group`.
   - **Forbidden access (`Effect = "Deny"` required)**: Must not allow, and must explicitly deny via `Effect = "Deny"`, `sqs:ReceiveMessage` or `sqs:DeleteMessage` on the main queue, `sqs:SendMessage`/`sqs:ReceiveMessage`/`sqs:DeleteMessage` on the DLQ, any DynamoDB actions (`dynamodb:GetItem`, `dynamodb:PutItem`, `dynamodb:UpdateItem`, `dynamodb:DeleteItem`, `dynamodb:Query`) on the projection table or `AccountIndex`, any S3 actions (`s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:ListBucket`) on `<audit_bucket_arn>` and `<audit_bucket_arn>/*`, `kms:Decrypt` or `kms:GenerateDataKey` on the `projection` and `audit` KMS keys, and `logs:CreateLogStream` or `logs:PutLogEvents` on any non-relay log group (`api`, `projector`, `archiver`).
5. **`archiver_role_arn`**:
   - **Trust principal**: `lambda.amazonaws.com`.
   - **Allowed access (`Effect = "Allow"`)**:
     - Append-only object access (`s3:PutObject`, `s3:GetObject`, `s3:AbortMultipartUpload`) scoped strictly to `<audit_bucket_arn>/ledger-audit/*`, and bucket-level metadata (`s3:ListBucket`, `s3:GetBucketLocation`) scoped strictly to `<audit_bucket_arn>` (keep object-level and bucket-level statements separated by resource type).
     - Cryptographic usage (`kms:Decrypt`, `kms:GenerateDataKey`, `kms:DescribeKey`) on the `audit` and `database` KMS key ARNs only.
     - CloudWatch Logs stream creation/writing scoped strictly to `logs.archiver_log_group`.
   - **Forbidden access (`Effect = "Deny"` required)**: Must not grant `s3:PutObject` on the bucket ARN `<audit_bucket_arn>` or unscoped `<audit_bucket_arn>/*` root wildcard, and must not grant `s3:ListBucket` on object ARNs. Must explicitly deny via `Effect = "Deny"` `s3:DeleteObject` and `s3:DeleteObjectVersion` on `<audit_bucket_arn>` and `<audit_bucket_arn>/*`, any SQS actions (`sqs:SendMessage`, `sqs:ReceiveMessage`, `sqs:DeleteMessage`) on the main queue or DLQ, any DynamoDB actions (`dynamodb:GetItem`, `dynamodb:PutItem`, `dynamodb:UpdateItem`, `dynamodb:DeleteItem`, `dynamodb:Query`) on the projection table or `AccountIndex`, `kms:Decrypt` or `kms:GenerateDataKey` on the `messaging` and `projection` KMS keys, and `logs:CreateLogStream` or `logs:PutLogEvents` on any non-archiver log group (`api`, `projector`, `relay`).
6. **`scheduler_role_arn`**:
   - **Trust principal**: `scheduler.amazonaws.com`.
   - **Allowed access (`Effect = "Allow"`)**:
     - `lambda:InvokeFunction` scoped strictly to the Outbox Relay (`workers.outbox_relay.function_arn`) and Audit Archiver (`workers.audit_archiver.function_arn`) Lambda function ARNs.
   - **Forbidden access (`Effect = "Deny"` required)**: Must not allow, and must explicitly deny via `Effect = "Deny"`, `lambda:InvokeFunction` on the Projector Lambda (`workers.projector.function_arn`), any SQS actions (`sqs:SendMessage`, `sqs:ReceiveMessage`, `sqs:DeleteMessage`) on the main queue or DLQ, any DynamoDB actions (`dynamodb:GetItem`, `dynamodb:PutItem`, `dynamodb:UpdateItem`, `dynamodb:DeleteItem`, `dynamodb:Query`) on the projection table or `AccountIndex`, any S3 actions (`s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:ListBucket`) on `<audit_bucket_arn>` and `<audit_bucket_arn>/*`, `kms:Decrypt` or `kms:GenerateDataKey` on all four KMS keys (`database`, `messaging`, `projection`, `audit`), and `logs:CreateLogStream` or `logs:PutLogEvents` on all four CloudWatch Log Groups (`api`, `projector`, `relay`, `archiver`).
