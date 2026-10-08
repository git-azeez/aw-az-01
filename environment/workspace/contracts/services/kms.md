# Customer-Managed KMS Keys (`services/kms.md`)

Provision four separate customer-managed KMS keys (`aws_kms_key`) and four KMS aliases (`aws_kms_alias`):

- `kms.database_arn` with alias `alias/<resource_prefix>-database`: encrypts the RDS PostgreSQL instance
- `kms.messaging_arn` with alias `alias/<resource_prefix>-messaging`: encrypts the main SQS queue and DLQ
- `kms.projection_arn` with alias `alias/<resource_prefix>-projection`: encrypts the DynamoDB projection table
- `kms.audit_arn` with alias `alias/<resource_prefix>-audit`: encrypts the S3 audit archive bucket

Each of the four KMS keys must be configured with:
- `enable_key_rotation = true`
- `deletion_window_in_days = 10` (must be `10..30` days)
- Tag `ClearLedgerDeployment = <resource_prefix>`

