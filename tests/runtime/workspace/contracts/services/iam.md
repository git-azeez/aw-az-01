# IAM Roles and Least-Privilege Policies (`services/iam.md`)

Provision six distinct IAM roles (`aws_iam_role`) with role-specific inline or attached policies (`aws_iam_role_policy`). Every policy must follow least privilege: do not use `Action = "*"` or `Resource = "*"` on any role policy.

1. **`ecs_execution_role_arn`**:
   - Principal: `ecs-tasks.amazonaws.com`
   - Permissions: write logs (`logs:CreateLogStream`, `logs:PutLogEvents`, `logs:DescribeLogStreams`) scoped to the API CloudWatch Log Group ARN.
2. **`ecs_task_role_arn`**:
   - Principal: `ecs-tasks.amazonaws.com`
   - Permissions:
     - `sqs:SendMessage`, `sqs:GetQueueAttributes`, `sqs:GetQueueUrl` on the main SQS queue ARN.
     - `dynamodb:GetItem`, `dynamodb:Query`, `dynamodb:DescribeTable` on the projection DynamoDB table ARN and its `index/*` ARN.
     - `kms:Decrypt`, `kms:GenerateDataKey`, `kms:DescribeKey` on the `messaging` and `projection` KMS key ARNs.
     - CloudWatch Logs write actions on the API log group ARN.
3. **`projector_role_arn`**:
   - Principal: `lambda.amazonaws.com`
   - Permissions:
     - `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:GetQueueAttributes`, `sqs:ChangeMessageVisibility` on the main SQS queue ARN, plus `sqs:SendMessage` on the DLQ ARN.
     - `dynamodb:GetItem`, `dynamodb:PutItem`, `dynamodb:UpdateItem`, `dynamodb:Query` on the projection DynamoDB table ARN and its `index/*` ARN.
     - `kms:Decrypt`, `kms:GenerateDataKey`, `kms:DescribeKey` on the `messaging` and `projection` KMS key ARNs.
     - CloudWatch Logs write actions on the projector log group ARN.
4. **`relay_role_arn`**:
   - Principal: `lambda.amazonaws.com`
   - Permissions:
     - `sqs:SendMessage`, `sqs:GetQueueAttributes`, `sqs:GetQueueUrl` on the main SQS queue ARN.
     - `kms:Decrypt`, `kms:GenerateDataKey`, `kms:DescribeKey` on the `messaging` and `database` KMS key ARNs.
     - CloudWatch Logs write actions on the relay log group ARN.
5. **`archiver_role_arn`**:
   - Principal: `lambda.amazonaws.com`
   - Permissions:
     - `s3:PutObject`, `s3:GetObject`, `s3:AbortMultipartUpload` on `<audit_bucket_arn>/ledger-audit/*` and `s3:ListBucket`, `s3:GetBucketLocation` on `<audit_bucket_arn>`.
     - `kms:Decrypt`, `kms:GenerateDataKey`, `kms:DescribeKey` on the `audit` and `database` KMS key ARNs.
     - CloudWatch Logs write actions on the archiver log group ARN.
6. **`scheduler_role_arn`**:
   - Principal: `scheduler.amazonaws.com`
   - Permissions:
     - `lambda:InvokeFunction` scoped strictly to the Outbox Relay and Audit Archiver Lambda function ARNs.
