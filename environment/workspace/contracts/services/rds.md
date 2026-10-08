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

## Required Database Schema, Relational Invariants, and State-Transition Triggers

The pre-built Rust binaries (`clearledger-api`, `clearledger-outbox-relay`, and `clearledger-audit-archiver`) do **not** run database migrations on startup. Moreover, `clearledger-api` relies on PostgreSQL constraints and triggers to enforce domain and state-transition invariants (mapping SQLSTATE `23514`, `23503`, `23502`, and PL/pgSQL `P0001` exceptions to HTTP `400 Bad Request`).

`deploy.sh` must idempotently initialize the `clearledger` schema, all four tables, their relational `CHECK` / `UNIQUE` / `FOREIGN KEY` constraints, their state-transition and append-only triggers, and all three indexes on the RDS PostgreSQL instance before `/health/ready` reports `200 OK` (`checks.postgres = "UP"`). Re-running `deploy.sh` against an already-initialized database must succeed cleanly without failing on existing tables, constraints, functions, triggers, or indexes.

### 1. Table `clearledger.settlements`

- **Columns**:
  - `settlement_id UUID NOT NULL PRIMARY KEY`
  - `account_id TEXT NOT NULL`
  - `reference TEXT NOT NULL`
  - `debit_party TEXT NOT NULL`
  - `credit_party TEXT NOT NULL`
  - `current_status TEXT NOT NULL`
  - `current_stage TEXT NOT NULL`
  - `last_entry_id UUID NULL`
  - `last_memo TEXT NULL`
  - `version INTEGER NOT NULL`
  - `entry_count INTEGER NOT NULL DEFAULT 0`
  - `created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`
  - `updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`
- **Row-level & cross-column invariants**:
  - `account_id`, `reference`, `debit_party`, `credit_party`, and `current_stage` must be non-empty after whitespace trimming (`account_id` at least 3 trimmed characters; `current_stage` at least 2 trimmed characters).
  - Self-dealing is prohibited: `debit_party` and `credit_party` must be distinct.
  - `current_status` must be one of `'INITIATED'`, `'VALIDATED'`, `'RESERVED'`, `'CLEARED'`, `'SETTLED'`, `'RECONCILED'`, `'DISPUTED'`.
  - `version >= 1`.
  - Initiation vs. post-initiation coherence:
    - At initial creation (`version = 1`), `entry_count` must be `0`, `current_status` must be `'INITIATED'`, and `last_entry_id` must be `NULL`.
    - After any ledger entry is appended (`version > 1`), `entry_count` must equal `version - 1`, `current_status` must not be `'INITIATED'`, and `last_entry_id` must be `NOT NULL`.
- **Update state-transition invariants (`BEFORE UPDATE` trigger)**:
  - Immutable settlement header fields (`settlement_id`, `account_id`, `reference`, `debit_party`, `credit_party`, `created_at`) must never be modified after insertion.
  - Optimistic version step invariant: every update must increment `version` by exactly `+1` and increment `entry_count` by `+1`.
  - Ordered clearing lifecycle state machine:
    - The normal clearing stage progression order is `INITIATED` -> `VALIDATED` -> `RESERVED` -> `CLEARED` -> `SETTLED` -> `RECONCILED`.
    - When neither the prior status nor the new status is `'DISPUTED'`, `current_status` must advance or stay at the same stage in this progression order (backward regressions such as `RESERVED` -> `VALIDATED`, `CLEARED` -> `RESERVED`, `SETTLED` -> `CLEARED`, or `RECONCILED` -> `SETTLED` must be rejected).
    - `'DISPUTED'` is an exception status reachable from any status except terminal `'RECONCILED'`. Once a settlement is in `'DISPUTED'`, subsequent updates may only remain `'DISPUTED'` or resolve to terminal `'RECONCILED'` (never regress from `'DISPUTED'` back to `'VALIDATED'`, `'RESERVED'`, `'CLEARED'`, or `'SETTLED'`).
    - `'RECONCILED'` is terminal: once `current_status` is `'RECONCILED'`, subsequent updates may only keep `current_status = 'RECONCILED'` (never transition to `'DISPUTED'` or any earlier status).

### 2. Table `clearledger.events`

- **Columns**:
  - `seq BIGSERIAL NOT NULL PRIMARY KEY`
  - `event_id UUID NOT NULL UNIQUE`
  - `settlement_id UUID NOT NULL REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE`
  - `aggregate_version INTEGER NOT NULL`
  - `event_type TEXT NOT NULL`
  - `correlation_id TEXT NOT NULL`
  - `idempotency_key TEXT NOT NULL`
  - `occurred_at TIMESTAMPTZ NOT NULL`
  - `payload JSONB NOT NULL`
  - `created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`
- **Row-level & cross-column invariants**:
  - Composite `UNIQUE (settlement_id, aggregate_version)`.
  - `aggregate_version >= 1`, `correlation_id` must have at least 4 non-whitespace characters, and `idempotency_key` must be between 8 and 128 trimmed characters.
  - Event-type / version coupling: `'SettlementInitiated'` is permitted only when `aggregate_version = 1`; `'LedgerEntryRecorded'` is permitted only when `aggregate_version >= 2`.
  - Full `ClearLedgerDomainEventEnvelope` (`schemas/events.schema.json`) coherence on `payload`:
    - `payload` must be a JSON object whose top-level envelope fields (`schemaVersion = "1.0"`, `aggregateType = "settlement"`, `eventId`, `aggregateId`, `aggregateVersion`, `eventType`, `correlationId`, `idempotencyKey`, and non-empty `occurredAt`) are present and match the row columns (`event_id`, `settlement_id`, `aggregate_version`, `event_type`, `correlation_id`, `idempotency_key`).
    - `payload.data` must be a nested JSON object satisfying the domain event data contract in `schemas/events.schema.json`: non-empty `accountId` (`>= 3` trimmed chars) and `clearingStage` (`>= 2` trimmed chars), and:
      - When `event_type = 'SettlementInitiated'` (`aggregate_version = 1`): `data.kind = "settlementInitiated"`, `data.status = "INITIATED"`, `data.entryId` is absent or JSON `null`, and `data.reference`, `data.debitParty`, `data.creditParty` are non-empty trimmed strings with `data.debitParty <> data.creditParty`.
      - When `event_type = 'LedgerEntryRecorded'` (`aggregate_version >= 2`): `data.kind = "ledgerEntryRecorded"`, `data.status` is one of `'VALIDATED'`, `'RESERVED'`, `'CLEARED'`, `'SETTLED'`, `'RECONCILED'`, `'DISPUTED'`, and `data.entryId` is a non-empty UUID string.
- **Cross-table parent coherence, contiguous sequencing & append-only immutability (`BEFORE INSERT` and `BEFORE UPDATE OR DELETE` triggers)**:
  - On `INSERT`:
    - Per-settlement event versions must be strictly contiguous starting at `1`: `aggregate_version` must equal `COALESCE(MAX(aggregate_version), 0) + 1` for `settlement_id` in `clearledger.events` (no version gaps).
    - Because `clearledger-api` inserts/updates `clearledger.settlements` prior to inserting into `clearledger.events` within the same transaction, the inserted event row must match the current parent row in `clearledger.settlements` for `settlement_id`: `aggregate_version = settlements.version`, `data.accountId = settlements.account_id`, `data.status = settlements.current_status`, `data.clearingStage = settlements.current_stage`, and (for `aggregate_version >= 2`) `data.entryId = settlements.last_entry_id::text`.
  - On `UPDATE` or `DELETE`:
    - `clearledger.events` is strictly an immutable append-only event log: any `UPDATE` or `DELETE` operation on `clearledger.events` must be rejected by raising an exception.

### 3. Table `clearledger.outbox`

- **Columns**:
  - `seq BIGSERIAL NOT NULL PRIMARY KEY`
  - `event_id UUID NOT NULL UNIQUE REFERENCES clearledger.events(event_id) ON DELETE CASCADE`
  - `settlement_id UUID NOT NULL REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE`
  - `aggregate_version INTEGER NOT NULL`
  - `correlation_id TEXT NOT NULL`
  - `payload JSONB NOT NULL`
  - `created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`
  - `published_at TIMESTAMPTZ NULL`
  - `archived_at TIMESTAMPTZ NULL`
  - `attempts INTEGER NOT NULL DEFAULT 0`
  - `last_error TEXT NULL`
- **Row-level & cross-column invariants**:
  - Composite `UNIQUE (settlement_id, aggregate_version)` and composite `FOREIGN KEY (settlement_id, aggregate_version) REFERENCES clearledger.events(settlement_id, aggregate_version) ON DELETE CASCADE`.
  - `aggregate_version >= 1`, `attempts >= 0`, and `correlation_id` must have at least 4 trimmed characters.
  - Delivery & archival state coherence:
    - When `published_at IS NOT NULL`, `attempts` must be `>= 1` and `last_error` must be `NULL`.
    - `archived_at` must be `NULL` unless `published_at IS NOT NULL` and `archived_at >= published_at`.
  - Full `ClearLedgerDomainEventEnvelope` (`schemas/events.schema.json`) coherence on `payload`:
    - `payload` must be a JSON object whose top-level (`schemaVersion`, `aggregateType`, `eventId`, `aggregateId`, `aggregateVersion`, `eventType`, `correlationId`, `idempotencyKey`, `occurredAt`) and nested `payload.data` fields satisfy `schemas/events.schema.json` and match `event_id`, `settlement_id`, `aggregate_version`, and `correlation_id`.
- **Cross-table event-mirror coherence & envelope immutability (`BEFORE INSERT` and `BEFORE UPDATE OR DELETE` triggers)**:
  - On `INSERT`, the outbox row's `settlement_id`, `aggregate_version`, `correlation_id`, and `payload` must exactly equal the referenced row in `clearledger.events` for `event_id`.
  - Outbox rows are never deleted (`DELETE` on `clearledger.outbox` must be rejected).
  - On `UPDATE`, the envelope identity columns (`seq`, `event_id`, `settlement_id`, `aggregate_version`, `correlation_id`, `payload`, `created_at`) must remain unchanged, and `attempts` must be monotonically non-decreasing (`NEW.attempts >= OLD.attempts`).

### 4. Table `clearledger.idempotency_keys`

- **Columns**:
  - `scope TEXT NOT NULL`
  - `idempotency_key TEXT NOT NULL`
  - `request_hash TEXT NOT NULL`
  - `status_code INTEGER NOT NULL`
  - `response_body JSONB NOT NULL`
  - `created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`
  - Composite `PRIMARY KEY (scope, idempotency_key)`
- **Row-level invariants**:
  - `scope` and `request_hash` must be non-empty after whitespace trimming; `idempotency_key` length must be between `8` and `128` characters.
  - `status_code` must be between `100` and `599` inclusive, and `response_body` must be a JSON object (`jsonb_typeof(response_body) = 'object'`).

### 5. Required Indexes in `clearledger` Schema

- `idx_clearledger_outbox_unpublished`: on `clearledger.outbox (seq)` with partial predicate `WHERE published_at IS NULL`
- `idx_clearledger_outbox_unarchived`: on `clearledger.outbox (seq)` with partial predicate `WHERE published_at IS NOT NULL AND archived_at IS NULL`
- `idx_clearledger_events_settlement_version`: on `clearledger.events (settlement_id, aggregate_version)`
