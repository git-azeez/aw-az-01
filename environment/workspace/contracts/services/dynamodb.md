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
- One aggregate state item with `PK = "SETTLEMENT#<settlement_id>"`, `SK = "STATE"`, `GSI1PK = "ACCOUNT#<account_id>"`, `GSI1SK = "SETTLEMENT#<settlement_id>"`, and attributes `settlement_id`, `account_id`, `reference`, `debit_party`, `credit_party`, `status`, `clearing_stage`, `version` (`N`), `entry_count` (`N`), `updated_at`, and optional `last_entry_id` / `last_memo`.
- Ordered ledger event items with `PK = "SETTLEMENT#<settlement_id>"` and `SK = "EVENT#<8-digit-zero-padded-version>"` (`EVENT#00000001` .. `EVENT#<version:08>`) containing `settlement_id`, `event_id`, `version` (`N`), `event_type`, `status`, `clearing_stage`, `occurred_at`, `correlation_id`, `envelope`, and optional `entry_id` / `memo`.

Because `clearledger-projector` writes `EVENT#*` items with `attribute_not_exists(PK) AND attribute_not_exists(SK)` and updates `STATE` only when `aggregateVersion > current_version`, `deploy.sh` must reconcile DynamoDB against PostgreSQL (`clearledger.settlements` and `clearledger.events`) by purging any orphan `SETTLEMENT#*` partitions not present in `clearledger.settlements` and verifying all `STATE` attributes (including `status`, `clearing_stage`, `account_id`, `reference`, `debit_party`, `credit_party`, `version`, `entry_count`, `GSI1PK`, and `GSI1SK`) as well as every `EVENT#*` item (`version`, `event_id`, `event_type`, `status`, `clearing_stage`, `envelope`) against PostgreSQL—deleting any corrupted (whether inflated-version or same-version in-place mutated) or phantom `STATE` / `EVENT#*` items before replaying the settlement's ordered events through the projector.
