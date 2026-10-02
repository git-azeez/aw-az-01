# DynamoDB Projection Store (`services/dynamodb.md`)

Provision a DynamoDB table (`aws_dynamodb_table`) for settlement projections and ordered ledger events:

- `billing_mode = "PAY_PER_REQUEST"`
- Primary key:
  - Partition key (`hash_key`): `PK` (`S`)
  - Sort key (`range_key`): `SK` (`S`)
- Global Secondary Index (`global_secondary_index`):
  - `name = "AccountIndex"` (`manifest.projections.gsi_name = "AccountIndex"`)
  - `hash_key = "GSI1PK"` (`S`)
  - `range_key = "GSI1SK"` (`S`)
  - `projection_type = "ALL"`
- Point-in-time recovery (`point_in_time_recovery`):
  - `enabled = true`
- Server-side encryption (`server_side_encryption`):
  - `enabled = true`
  - `kms_key_arn = kms.projection_arn`
