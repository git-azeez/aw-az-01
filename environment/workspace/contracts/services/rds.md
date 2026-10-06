# RDS PostgreSQL (`services/rds.md`)

- Provision a DB subnet group (`aws_db_subnet_group`) spanning the private subnets.
- Provision a single PostgreSQL 16 RDS instance (`aws_db_instance`) with:
  - `engine = "postgres"`
  - `engine_version = "16.3"` (or `16.*`)
  - `instance_class = "db.t4g.micro"`
  - `db_name`, `username`, and `password` from `/workspace/config/config.json`
  - `storage_encrypted = true`
  - `kms_key_id` set to the customer-managed `database` KMS key ARN (`kms.database_arn`)
  - `publicly_accessible = false`
  - `skip_final_snapshot = true`
  - `vpc_security_group_ids` containing the `rds` security group
- Re-running `deploy.sh` must never replace the RDS instance or lose committed data.

## Required Database Schema & Relational Integrity Specification

The pre-built Rust binaries (`clearledger-api`, `clearledger-outbox-relay`, and `clearledger-audit-archiver`) do **not** auto-migrate the database on startup. Moreover, `clearledger-api` relies on PostgreSQL relational `CHECK` and `FOREIGN KEY` constraints to enforce domain invariants (mapping SQLSTATE `23514` / `23503` constraint violations to HTTP `400 Bad Request`).

`deploy.sh` must idempotently initialize the `clearledger` schema, all 4 tables with their relational constraints, and all 3 indexes on the RDS PostgreSQL instance (connecting to host `aws` on the allocated RDS port with `db_name`, `db_username`, and `db_password`) before `/health/ready` reports `200 OK` (`checks.postgres = "UP"`).

### 1. Table `clearledger.settlements`

| Column | Type | Nullability & Default | Constraints |
|---|---|---|---|
| `settlement_id` | `UUID` | `NOT NULL` | `PRIMARY KEY` |
| `account_id` | `TEXT` | `NOT NULL` | — |
| `reference` | `TEXT` | `NOT NULL` | — |
| `debit_party` | `TEXT` | `NOT NULL` | Table `CHECK`: `debit_party <> credit_party` (self-dealing settlements are prohibited) |
| `credit_party` | `TEXT` | `NOT NULL` | Table `CHECK`: `debit_party <> credit_party` |
| `current_status` | `TEXT` | `NOT NULL` | `CHECK`: must be one of `'INITIATED'`, `'VALIDATED'`, `'RESERVED'`, `'CLEARED'`, `'SETTLED'`, `'RECONCILED'`, `'DISPUTED'` |
| `current_stage` | `TEXT` | `NOT NULL` | — |
| `last_entry_id` | `UUID` | `NULL` | — |
| `last_memo` | `TEXT` | `NULL` | — |
| `version` | `INTEGER` | `NOT NULL` | `CHECK`: `version >= 1` |
| `entry_count` | `INTEGER` | `NOT NULL DEFAULT 0` | `CHECK`: `entry_count >= 0 AND entry_count = version - 1` |
| `created_at` | `TIMESTAMPTZ` | `NOT NULL DEFAULT NOW()` | — |
| `updated_at` | `TIMESTAMPTZ` | `NOT NULL DEFAULT NOW()` | — |

### 2. Table `clearledger.events`

| Column | Type | Nullability & Default | Constraints |
|---|---|---|---|
| `seq` | `BIGSERIAL` | `NOT NULL` | `PRIMARY KEY` |
| `event_id` | `UUID` | `NOT NULL` | `UNIQUE` |
| `settlement_id` | `UUID` | `NOT NULL` | `REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE` |
| `aggregate_version` | `INTEGER` | `NOT NULL` | `CHECK (aggregate_version >= 1)`; composite `UNIQUE (settlement_id, aggregate_version)` |
| `event_type` | `TEXT` | `NOT NULL` | `CHECK`: must be one of `'SettlementInitiated'`, `'LedgerEntryRecorded'` |
| `correlation_id` | `TEXT` | `NOT NULL` | — |
| `idempotency_key` | `TEXT` | `NOT NULL` | — |
| `occurred_at` | `TIMESTAMPTZ` | `NOT NULL` | — |
| `payload` | `JSONB` | `NOT NULL` | — |
| `created_at` | `TIMESTAMPTZ` | `NOT NULL DEFAULT NOW()` | — |

### 3. Table `clearledger.outbox`

| Column | Type | Nullability & Default | Constraints |
|---|---|---|---|
| `seq` | `BIGSERIAL` | `NOT NULL` | `PRIMARY KEY` |
| `event_id` | `UUID` | `NOT NULL` | `UNIQUE REFERENCES clearledger.events(event_id) ON DELETE CASCADE` |
| `settlement_id` | `UUID` | `NOT NULL` | `REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE` |
| `aggregate_version` | `INTEGER` | `NOT NULL` | `CHECK (aggregate_version >= 1)` |
| `correlation_id` | `TEXT` | `NOT NULL` | — |
| `payload` | `JSONB` | `NOT NULL` | — |
| `created_at` | `TIMESTAMPTZ` | `NOT NULL DEFAULT NOW()` | — |
| `published_at` | `TIMESTAMPTZ` | `NULL` | — |
| `archived_at` | `TIMESTAMPTZ` | `NULL` | — |
| `attempts` | `INTEGER` | `NOT NULL DEFAULT 0` | `CHECK (attempts >= 0)` |
| `last_error` | `TEXT` | `NULL` | — |

### 4. Table `clearledger.idempotency_keys`

| Column | Type | Nullability & Default | Constraints |
|---|---|---|---|
| `scope` | `TEXT` | `NOT NULL` | Composite `PRIMARY KEY (scope, idempotency_key)` |
| `idempotency_key` | `TEXT` | `NOT NULL` | Composite `PRIMARY KEY (scope, idempotency_key)` |
| `request_hash` | `TEXT` | `NOT NULL` | — |
| `status_code` | `INTEGER` | `NOT NULL` | `CHECK (status_code >= 100 AND status_code <= 599)` |
| `response_body` | `JSONB` | `NOT NULL` | — |
| `created_at` | `TIMESTAMPTZ` | `NOT NULL DEFAULT NOW()` | — |

### 5. Required Indexes in `clearledger` Schema

| Index Name | Target Table & Key Columns | Partial Index Predicate |
|---|---|---|
| `idx_clearledger_outbox_unpublished` | `clearledger.outbox (seq)` | `WHERE published_at IS NULL` |
| `idx_clearledger_outbox_unarchived` | `clearledger.outbox (seq)` | `WHERE published_at IS NOT NULL AND archived_at IS NULL` |
| `idx_clearledger_events_settlement_version` | `clearledger.events (settlement_id, aggregate_version)` | *(none)* |
