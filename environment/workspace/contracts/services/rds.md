# RDS PostgreSQL (`services/rds.md`)

- Provision a DB subnet group (`aws_db_subnet_group`) spanning strictly the private subnets (`network.private_subnet_ids`).
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

## Required Database Schema, Relational Invariants, and Triggers

The pre-built Rust binaries (`clearledger-api`, `clearledger-outbox-relay`, and `clearledger-audit-archiver`) do **not** run database migrations on startup. `clearledger-api` relies on PostgreSQL constraints and triggers to enforce domain, schema, and state-transition invariants (mapping SQLSTATE `23514`, `23503`, `23502`, `23505`, and PL/pgSQL `P0001` exceptions to HTTP `400 Bad Request`), and `GET /health/ready` verifies that all four tables, all three indexes, and user-defined triggers on all four tables exist in the `clearledger` schema before reporting `checks.postgres = "UP"`.

`deploy.sh` must idempotently initialize the `clearledger` schema, all four tables, their relational constraints, their triggers, and all three indexes on the RDS PostgreSQL instance. Re-running `deploy.sh` against an already-initialized database must succeed cleanly.

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
  - Trimmed string bounds must match `CreateSettlementRequest` / `AppendEntryRequest` in `openapi.yaml`: `account_id` (`3..64` trimmed chars), `reference` (`3..64` trimmed chars), `debit_party` (`2..64` trimmed chars), `credit_party` (`2..64` trimmed chars), `current_stage` (`2..64` trimmed chars), and `last_memo` (either `NULL` or `1..256` trimmed chars).
  - Self-dealing is prohibited: trimmed `debit_party` and trimmed `credit_party` must be distinct.
  - `current_status` must be one of `'INITIATED'`, `'VALIDATED'`, `'RESERVED'`, `'CLEARED'`, `'SETTLED'`, `'RECONCILED'`, `'DISPUTED'`.
  - `version >= 1` and `updated_at >= created_at`.
  - Initiation vs. post-initiation coherence:
    - At initial creation (`version = 1`), `entry_count` must be `0`, `current_status` must be `'INITIATED'`, and `last_entry_id` must be `NULL`.
    - After any ledger entry is appended (`version > 1`), `entry_count` must equal `version - 1`, `current_status` must not be `'INITIATED'`, and `last_entry_id` must be `NOT NULL`.
- **Update state-transition invariants (`BEFORE UPDATE` trigger)**:
  - Immutable settlement header fields (`settlement_id`, `account_id`, `reference`, `debit_party`, `credit_party`, `created_at`) must never be modified after insertion.
  - Optimistic version & entry progression: every update must increment `version` by `+1`, increment `entry_count` by `+1`, advance or preserve `updated_at` (`NEW.updated_at >= OLD.updated_at`), and set a distinct `last_entry_id` (`NEW.last_entry_id IS DISTINCT FROM OLD.last_entry_id`).
  - Ordered clearing lifecycle state machine:
    - Normal clearing stage progression order is `INITIATED` -> `VALIDATED` -> `RESERVED` -> `CLEARED` -> `SETTLED` -> `RECONCILED`.
    - When neither the prior status nor the new status is `'DISPUTED'`, `current_status` must advance or remain at the same stage in this progression order (backward regressions such as `RESERVED` -> `VALIDATED`, `CLEARED` -> `RESERVED`, `SETTLED` -> `CLEARED`, or `RECONCILED` -> `SETTLED` must be rejected).
    - `'DISPUTED'` is an exception status reachable from any status except terminal `'RECONCILED'`. Once in `'DISPUTED'`, subsequent updates may only remain `'DISPUTED'` or resolve to terminal `'RECONCILED'`.
    - `'RECONCILED'` is terminal: once `current_status` is `'RECONCILED'`, subsequent updates may only keep `current_status = 'RECONCILED'`.

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
  - Composite `UNIQUE (settlement_id, aggregate_version)` and composite `UNIQUE (settlement_id, idempotency_key)`.
  - `aggregate_version >= 1`, `correlation_id` must be `4..128` trimmed characters, and `idempotency_key` must be `8..128` trimmed characters.
  - Event-type / version coupling: `'SettlementInitiated'` is permitted only when `aggregate_version = 1`; `'LedgerEntryRecorded'` is permitted only when `aggregate_version >= 2`.
  - Strict `ClearLedgerDomainEventEnvelope` (`schemas/events.schema.json`) coherence on `payload`:
    - `payload` must be a JSON object with no unknown top-level properties (`additionalProperties: false`: only the 10 schema properties are permitted) whose top-level fields (`schemaVersion = "1.0"`, `aggregateType = "settlement"`, `eventId`, `aggregateId`, `aggregateVersion`, `eventType`, `correlationId`, `idempotencyKey`, and `occurredAt`) match the row columns (`event_id`, `settlement_id`, `aggregate_version`, `event_type`, `correlation_id`, `idempotency_key`, and `occurred_at` as a `TIMESTAMPTZ` instant).
    - `payload.data` must be a JSON object with no unknown properties (`additionalProperties: false`: only `kind`, `accountId`, `reference`, `debitParty`, `creditParty`, `entryId`, `status`, `clearingStage`, `memo` are permitted), non-empty `accountId` (`3..64` trimmed chars), `clearingStage` (`2..64` trimmed chars), `reference` (`3..64` trimmed chars), `debitParty` (`2..64` trimmed chars), `creditParty` (`2..64` trimmed chars) with `debitParty <> creditParty`, and:
      - When `event_type = 'SettlementInitiated'` (`aggregate_version = 1`): `data.kind = "settlementInitiated"`, `data.status = "INITIATED"`, and `data.entryId` is absent or JSON `null`.
      - When `event_type = 'LedgerEntryRecorded'` (`aggregate_version >= 2`): `data.kind = "ledgerEntryRecorded"`, `data.status` is one of `'VALIDATED'`, `'RESERVED'`, `'CLEARED'`, `'SETTLED'`, `'RECONCILED'`, `'DISPUTED'`, and `data.entryId` is a valid UUID string.
- **Cross-table parent coherence, contiguous sequencing, unique entryId & append-only immutability (`BEFORE INSERT` and `BEFORE UPDATE OR DELETE` triggers)**:
  - On `INSERT`:
    - Per-settlement event versions must be strictly contiguous starting at `1` (`1, 2, 3, ...` with no version gaps).
    - Within any single settlement (`settlement_id`), `data.entryId` across `LedgerEntryRecorded` events (`aggregate_version >= 2`) must be unique.
    - Because `clearledger-api` inserts/updates `clearledger.settlements` prior to inserting into `clearledger.events` within the same transaction, the inserted event row must match the current parent row in `clearledger.settlements` for `settlement_id` across `version`, `account_id`, `reference`, `debit_party`, `credit_party`, `current_status`, `current_stage`, `last_memo`, and (for `aggregate_version >= 2`) `last_entry_id`.
  - On `UPDATE` or `DELETE`:
    - `clearledger.events` is strictly an immutable append-only event log: any `UPDATE` or `DELETE` operation must be rejected.

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
  - `aggregate_version >= 1`, `attempts >= 0`, and `correlation_id` must be `4..128` trimmed characters.
  - Delivery & archival state coherence:
    - When `published_at IS NOT NULL`, `attempts` must be `>= 1` and `last_error` must be `NULL`.
    - `archived_at` must be `NULL` unless `published_at IS NOT NULL` and `archived_at >= published_at`.
  - Strict `ClearLedgerDomainEventEnvelope` (`schemas/events.schema.json`) coherence on `payload` (including `additionalProperties: false` on top-level `payload` and `payload.data`, and matching `event_id`, `settlement_id`, `aggregate_version`, and `correlation_id`).
- **Cross-table event-mirror coherence, contiguous sequencing & state-transition immutability (`BEFORE INSERT` and `BEFORE UPDATE OR DELETE` triggers)**:
  - On `INSERT`:
    - Per-settlement outbox versions must be strictly contiguous starting at `1` (no version gaps).
    - The outbox row's `settlement_id`, `aggregate_version`, `correlation_id`, and `payload` must exactly equal the referenced row in `clearledger.events` for `event_id`.
  - Outbox rows are never deleted (`DELETE` on `clearledger.outbox` must be rejected).
  - On `UPDATE`:
    - The envelope identity columns (`seq`, `event_id`, `settlement_id`, `aggregate_version`, `correlation_id`, `payload`, `created_at`) must remain unchanged, and `attempts` must be monotonically non-decreasing.
    - Transitioning an unpublished row (`OLD.published_at IS NULL`) to published (`NEW.published_at IS NOT NULL`) requires incrementing `attempts` and keeping `NEW.archived_at IS NULL`.
    - Transitioning a published row (`OLD.published_at IS NOT NULL AND OLD.archived_at IS NULL`) to archived (`NEW.archived_at IS NOT NULL`) must preserve `NEW.published_at = OLD.published_at` and `NEW.attempts = OLD.attempts`.

### 4. Table `clearledger.idempotency_keys`

- **Columns**:
  - `scope TEXT NOT NULL`
  - `idempotency_key TEXT NOT NULL`
  - `request_hash TEXT NOT NULL`
  - `status_code INTEGER NOT NULL`
  - `response_body JSONB NOT NULL`
  - `created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`
  - Composite `PRIMARY KEY (scope, idempotency_key)`
- **Row-level & cross-column invariants**:
  - `scope` must be formatted as `create:<settlement_uuid>` or `entry:<settlement_uuid>`.
  - `idempotency_key` must be `8..128` trimmed characters.
  - `request_hash` must be a 64-character lowercase hexadecimal SHA-256 digest.
  - `response_body` must be a JSON object conforming strictly to `WriteAcceptedResponse` in `openapi.yaml` (containing only the 5 keys `settlementId`, `eventId`, `version`, `accepted`, and `idempotentReplay`, with `settlementId` matching the UUID in `scope`, valid UUID `eventId`, integer `version`, `accepted = true`, and `idempotentReplay = false`).
  - Scope / status / version coupling:
    - For `create:<settlement_uuid>`: `status_code = 201` and `version = 1`.
    - For `entry:<settlement_uuid>`: `status_code = 202` and `version >= 2`.
- **Cross-table event/outbox coherence & append-only immutability (`BEFORE INSERT` and `BEFORE UPDATE OR DELETE` triggers)**:
  - On `INSERT`: because `clearledger-api` records the idempotency entry after inserting into `clearledger.events` and `clearledger.outbox` within the same transaction, the trigger must verify that the referenced event (`eventId`, `settlementId`, `version`, `idempotency_key`) exists in **both** `clearledger.events` and `clearledger.outbox`.
  - On `UPDATE` or `DELETE`: `clearledger.idempotency_keys` is strictly an append-only idempotency ledger; any `UPDATE` or `DELETE` operation must be rejected.

### 5. Required Indexes in `clearledger` Schema

- `idx_clearledger_outbox_unpublished`: on `clearledger.outbox (seq)` with partial predicate `WHERE published_at IS NULL`
- `idx_clearledger_outbox_unarchived`: on `clearledger.outbox (seq)` with partial predicate `WHERE published_at IS NOT NULL AND archived_at IS NULL`
- `idx_clearledger_events_settlement_version`: on `clearledger.events (settlement_id, aggregate_version)`

