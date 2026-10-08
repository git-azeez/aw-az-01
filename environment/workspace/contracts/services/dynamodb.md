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

## Projection Item Structure and Reconciliation Invariants

For each settlement `<settlement_id>`, the table stores:
- One aggregate state item with `PK = "SETTLEMENT#<settlement_id>"`, `SK = "STATE"`, `GSI1PK = "ACCOUNT#<account_id>"`, `GSI1SK = "SETTLEMENT#<settlement_id>"`, and attributes `settlement_id`, `account_id`, `reference`, `debit_party`, `credit_party`, `status`, `clearing_stage`, `version` (`N`), `entry_count` (`N - 1`), `updated_at` (RFC3339 timestamp of the latest event), and optional `last_entry_id` / `last_memo`.
- Ordered ledger event items with `PK = "SETTLEMENT#<settlement_id>"` and `SK = "EVENT#<8-digit-zero-padded-version>"` (`EVENT#00000001` .. `EVENT#<version:08d>`) containing `settlement_id`, `event_id`, `version` (`N`), `event_type`, `status`, `clearing_stage`, `occurred_at`, `correlation_id`, `envelope`, and optional `entry_id` / `memo`.

Because `clearledger-projector` writes `EVENT#*` items conditionally with `attribute_not_exists(PK) AND attribute_not_exists(SK)` and updates `STATE` conditionally only when `aggregateVersion > current_version`, `deploy.sh` must ensure full 1-to-1 convergence between PostgreSQL (`clearledger.settlements` and `clearledger.events`) and DynamoDB/Valkey so that no orphan partitions, stray sort keys, missing event items, or stale/divergent attributes remain in either DynamoDB or Valkey.

