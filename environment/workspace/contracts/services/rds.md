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

## Required Database Schema Initialization

The pre-built Rust binaries (`clearledger-api`, `clearledger-outbox-relay`, and `clearledger-audit-archiver`) do **not** auto-migrate the database on startup. `deploy.sh` must idempotently initialize the `clearledger` schema, tables, and indexes on the RDS PostgreSQL instance (connecting to host `aws` on the allocated RDS port with `db_name`, `db_username`, and `db_password`) before `/health/ready` reports `200 OK` (`checks.postgres = "UP"`):

```sql
CREATE SCHEMA IF NOT EXISTS clearledger;

CREATE TABLE IF NOT EXISTS clearledger.settlements (
    settlement_id UUID PRIMARY KEY,
    account_id TEXT NOT NULL,
    reference TEXT NOT NULL,
    debit_party TEXT NOT NULL,
    credit_party TEXT NOT NULL,
    current_status TEXT NOT NULL,
    current_stage TEXT NOT NULL,
    last_entry_id UUID NULL,
    last_memo TEXT NULL,
    version INTEGER NOT NULL,
    entry_count INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS clearledger.events (
    seq BIGSERIAL PRIMARY KEY,
    event_id UUID NOT NULL UNIQUE,
    settlement_id UUID NOT NULL REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE,
    aggregate_version INTEGER NOT NULL,
    event_type TEXT NOT NULL,
    correlation_id TEXT NOT NULL,
    idempotency_key TEXT NOT NULL,
    occurred_at TIMESTAMPTZ NOT NULL,
    payload JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (settlement_id, aggregate_version)
);

CREATE TABLE IF NOT EXISTS clearledger.outbox (
    seq BIGSERIAL PRIMARY KEY,
    event_id UUID NOT NULL UNIQUE,
    settlement_id UUID NOT NULL,
    aggregate_version INTEGER NOT NULL,
    correlation_id TEXT NOT NULL,
    payload JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    published_at TIMESTAMPTZ NULL,
    archived_at TIMESTAMPTZ NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    last_error TEXT NULL
);

CREATE TABLE IF NOT EXISTS clearledger.idempotency_keys (
    scope TEXT NOT NULL,
    idempotency_key TEXT NOT NULL,
    request_hash TEXT NOT NULL,
    status_code INTEGER NOT NULL,
    response_body JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (scope, idempotency_key)
);

CREATE INDEX IF NOT EXISTS idx_clearledger_outbox_unpublished
    ON clearledger.outbox (seq)
    WHERE published_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_clearledger_outbox_unarchived
    ON clearledger.outbox (seq)
    WHERE published_at IS NOT NULL AND archived_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_clearledger_events_settlement_version
    ON clearledger.events (settlement_id, aggregate_version);
```
