# Customer-Managed KMS Keys (`services/kms.md`)

Provision four separate customer-managed KMS keys (`aws_kms_key`) and four KMS aliases (`aws_kms_alias`):

- `kms.database_arn` with alias `alias/<resource_prefix>-database`: encrypts the RDS PostgreSQL instance
- `kms.messaging_arn` with alias `alias/<resource_prefix>-messaging`: encrypts the main SQS queue and DLQ
- `kms.projection_arn` with alias `alias/<resource_prefix>-projection`: encrypts the DynamoDB projection table
- `kms.audit_arn` with alias `alias/<resource_prefix>-audit`: encrypts the S3 audit archive bucket

Each of the four KMS keys must be configured with:
- `enable_key_rotation = true`
- `deletion_window_in_days = 10` (must be `10..30` days)
- Tags `ClearLedgerDeployment = <resource_prefix>` and `ClearLedgerKeyUsage = <database|messaging|projection|audit>` (matching its respective role: `database`, `messaging`, `projection`, or `audit`)
- **Resource-based KMS key policy (`aws_kms_key.policy` or `aws_kms_key_policy`)**:
  - Grants key administration to the AWS account root principal (`arn:aws:iam::000000000000:root`).
  - Explicitly allows (`Effect = "Allow"`) cryptographic usage (`kms:Decrypt`, `kms:GenerateDataKey`, `kms:DescribeKey`) to the exact ClearLedger workload IAM role ARNs authorized for that key:
    - `database`: `iam.relay_role_arn` and `iam.archiver_role_arn`
    - `messaging`: `iam.ecs_task_role_arn`, `iam.projector_role_arn`, and `iam.relay_role_arn`
    - `projection`: `iam.ecs_task_role_arn` and `iam.projector_role_arn`
    - `audit`: `iam.archiver_role_arn`
  - Explicitly denies (`Effect = "Deny"`) `kms:DisableKey` and `kms:ScheduleKeyDeletion` when the principal is any of the six ClearLedger workload IAM role ARNs (`ecs_execution`, `ecs_task`, `projector`, `relay`, `archiver`, `scheduler`), and explicitly denies (`Effect = "Deny"`) `kms:Decrypt` and `kms:GenerateDataKey` when the principal is any of the ClearLedger workload IAM role ARNs not authorized for that key.
- Re-running `deploy.sh` must ensure all four KMS keys remain enabled (`KeyState = "Enabled"`), have `enable_key_rotation = true`, retain their canonical `ClearLedgerDeployment` and `ClearLedgerKeyUsage` tags, and enforce their canonical key policies.
