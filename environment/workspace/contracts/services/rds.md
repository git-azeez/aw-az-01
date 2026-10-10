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
- Tag the DB subnet group and RDS instance with `ClearLedgerDeployment = <resource_prefix>`. Re-running `deploy.sh` must never replace the RDS instance or lose committed data, and must restore the `ClearLedgerDeployment = <resource_prefix>` tag on the RDS instance if removed out-of-band.

## Required Database Schema, Relational Invariants, and Triggers

The pre-built Rust binaries (`clearledger-api`, `clearledger-outbox-relay`, and `clearledger-audit-archiver`) do **not** run database migrations on startup. `clearledger-api` relies on PostgreSQL `CHECK`/`UNIQUE`/`FOREIGN KEY` constraints and PL/pgSQL triggers to enforce domain, schema, and state-transition invariants at the database layer (mapping SQLSTATE `23514`, `23503`, `23502`, `23505`, and `P0001` exceptions to HTTP `400 Bad Request`), and `GET /health/ready` verifies that all four tables, required indexes, and user-defined triggers on all four tables exist in the `clearledger` schema before reporting `checks.postgres = "UP"`.

`deploy.sh` must idempotently initialize and enforce the `clearledger` schema, all four tables, their canonical `CHECK`/`UNIQUE`/`FOREIGN KEY` constraints (replacing any altered or weakened `CHECK` constraint definitions), their triggers, and all six required indexes on the RDS PostgreSQL instance, and ensure all user-defined triggers on all four tables remain enabled (`tgenabled = 'O'` in `pg_trigger`).

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
  - `last_memo TEXT NOT NULL`
  - `version INTEGER NOT NULL`
  - `entry_count INTEGER NOT NULL DEFAULT 0`
  - `created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`
  - `updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`
- **Required invariants (enforced via `CHECK` constraints and `BEFORE UPDATE`/`BEFORE DELETE` triggers)**:
  - Canonical trimmed strings and length bounds: `account_id`, `reference`, `debit_party`, `credit_party`, `current_stage`, and `last_memo` must be non-null and stored in canonical trimmed form (`col = btrim(col)`, no leading or trailing whitespace) and match the length bounds and allowed status values of `CreateSettlementRequest` and `AppendEntryRequest` in `openapi.yaml` (`1..256` characters for `last_memo`), with `debit_party <> credit_party` and `version >= 1`.
  - At initiation (`version = 1`), `entry_count = 0`, `current_status = 'INITIATED'`, `current_stage = 'INITIATED@' || debit_party`, `last_entry_id IS NULL`, `last_memo = 'Settlement initiated'`, and `updated_at = created_at`. For `version > 1`, `entry_count = version - 1`, `current_status <> 'INITIATED'`, `last_entry_id IS NOT NULL`, `last_memo IS NOT NULL`, and `updated_at > created_at`.
  - On `UPDATE`:
    - Because `POST /v1/settlements/{id}/entries` allows `memo` to be omitted (`NULL` in the `UPDATE clearledger.settlements` statement executed by `clearledger-api`), when `NEW.last_memo IS NULL` on `UPDATE`, the `BEFORE UPDATE` trigger must retain the previous non-null memo (`NEW.last_memo := COALESCE(NEW.last_memo, OLD.last_memo)`) so `clearledger.settlements.last_memo` is never `NULL` and always matches `clearledger-projector`'s `STATE.last_memo` projection.
    - Header columns (`settlement_id`, `account_id`, `reference`, `debit_party`, `credit_party`, `created_at`) are immutable; each update must step `version` and `entry_count` by `+1` with a new `last_entry_id` (`NEW.last_entry_id IS DISTINCT FROM OLD.last_entry_id`) and a strictly increasing `updated_at` timestamp (`NEW.updated_at > OLD.updated_at`); and `current_status` must follow the clearing lifecycle progression:
    - The non-`DISPUTED` clearing status rank order is `INITIATED` (`0`) < `VALIDATED` (`1`) < `RESERVED` (`2`) < `CLEARED` (`3`) < `SETTLED` (`4`) < `RECONCILED` (`5`).
    - `RECONCILED` is strictly terminal: once `OLD.current_status = 'RECONCILED'`, any `UPDATE` on the settlement row must be rejected (even if `NEW.current_status = 'RECONCILED'`).
    - From any non-`RECONCILED`, non-`DISPUTED` status (`INITIATED`, `VALIDATED`, `RESERVED`, `CLEARED`, `SETTLED`), `NEW.current_status` may transition to `'DISPUTED'` or to any status whose rank is monotonic non-decreasing (`rank(NEW.current_status) >= rank(OLD.current_status)` — permitting same-status updates such as `CLEARED` -> `CLEARED` and single- or multi-stage forward advances such as `INITIATED` -> `VALIDATED` or `INITIATED` -> `CLEARED`, while rejecting any backward rank regression where `rank(NEW.current_status) < rank(OLD.current_status)` such as `CLEARED` -> `RESERVED`).
    - From `OLD.current_status = 'DISPUTED'`, `NEW.current_status` may only remain `'DISPUTED'` or resolve to terminal `'RECONCILED'`.
  - `clearledger.settlements` is an append-only ledger aggregate root (`DELETE` must be rejected).

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
- **Required invariants (enforced via `UNIQUE`/`CHECK` constraints and `BEFORE INSERT`/`UPDATE`/`DELETE` triggers)**:
  - Composite `UNIQUE (settlement_id, aggregate_version)` and `UNIQUE (settlement_id, idempotency_key)`, with canonical trimmed storage (`col = btrim(col)`) and length bounds on `correlation_id` and `idempotency_key` matching `openapi.yaml`.
  - `payload` must conform strictly to `ClearLedgerDomainEventEnvelope` in `schemas/events.schema.json` (including `additionalProperties: false` on both the envelope and `payload.data`, required non-null canonically trimmed `accountId`, `reference`, `debitParty`, `creditParty`, `status`, and `clearingStage` in `payload.data` with length bounds matching `openapi.yaml` and `1..256` canonically trimmed characters when `data.memo` is non-null, column-to-envelope equality across `event_id`, `settlement_id`, `aggregate_version`, `event_type`, `correlation_id`, `idempotency_key`, and `occurred_at` compared as `TIMESTAMPTZ`, and version/kind/status/entryId coupling for `SettlementInitiated` at `v = 1` with `data.clearingStage = 'INITIATED@' || (data.debitParty)` and `data.memo = 'Settlement initiated'` vs `LedgerEntryRecorded` at `v >= 2`).
  - On `INSERT`: per-settlement `aggregate_version` must be contiguous starting at `1`; `data.entryId` must be unique per settlement across all `LedgerEntryRecorded` events; the event must match the parent row in `clearledger.settlements` (including header fields, `current_status`, `current_stage`, `last_entry_id`, `version`, `occurred_at = updated_at`, plus `occurred_at = created_at` at `v = 1`, and `last_memo` matching `NEW.payload->'data'->>'memo'` when non-null or the most recent non-null `payload->'data'->>'memo'` from prior events of `NEW.settlement_id` when `NEW.payload->'data'->>'memo'` is `NULL`); and for `aggregate_version >= 2`, `NEW.occurred_at` must be strictly greater (`>`) than the immediately preceding event's `occurred_at` (`aggregate_version = NEW.aggregate_version - 1`) and the status transition from that preceding event's `data.status` to `NEW.payload->'data'->>'status'` must satisfy the settlement status transition rules above (monotonic non-decreasing rank, reachable `DISPUTED` from non-`RECONCILED`, `DISPUTED` only to `DISPUTED` or `RECONCILED`, and no transitions out of or repeating `RECONCILED`).
  - `clearledger.events` is strictly append-only (`UPDATE` and `DELETE` must be rejected).

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
- **Required invariants (enforced via `UNIQUE`/`FOREIGN KEY`/`CHECK` constraints and triggers)**:
  - Composite `UNIQUE (settlement_id, aggregate_version)` and `FOREIGN KEY (settlement_id, aggregate_version) REFERENCES clearledger.events(settlement_id, aggregate_version) ON DELETE CASCADE`, with canonical trimmed `correlation_id` (`correlation_id = btrim(correlation_id)`).
  - `payload` must conform to `ClearLedgerDomainEventEnvelope` (`schemas/events.schema.json`) and on `INSERT` must exactly mirror the corresponding row in `clearledger.events` in contiguous per-settlement `aggregate_version` order starting at `1`.
  - Delivery/archival lifecycle: `attempts >= 0`; when `attempts = 0`, both `published_at` and `last_error` must be `NULL`; when `published_at IS NOT NULL`, `attempts >= 1`, `last_error IS NULL`, and `published_at >= created_at`; when `last_error IS NOT NULL`, `published_at IS NULL`, `attempts >= 1`, `length(btrim(last_error)) > 0`, and `last_error = btrim(last_error)`; `archived_at` requires `published_at IS NOT NULL` and `archived_at >= published_at`.
  - `DELETE` is forbidden; on `UPDATE`, envelope columns are immutable, `attempts` cannot decrease, publishing an unpublished row requires incrementing `attempts` with `archived_at IS NULL`, while `published_at` remains `NOT NULL` (such as during archival or resetting `archived_at = NULL` for S3 re-archival), `published_at`, `attempts`, and `last_error` cannot be mutated (resetting `published_at = NULL, archived_at = NULL` for operational replay is permitted), and once `OLD.archived_at IS NOT NULL` and `NEW.archived_at IS NOT NULL`, `NEW.archived_at` cannot be mutated to a different timestamp without first resetting `archived_at = NULL`.

### 4. Table `clearledger.idempotency_keys`

- **Columns**:
  - `scope TEXT NOT NULL`
  - `idempotency_key TEXT NOT NULL`
  - `request_hash TEXT NOT NULL`
  - `status_code INTEGER NOT NULL`
  - `response_body JSONB NOT NULL`
  - `created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`
  - Composite `PRIMARY KEY (scope, idempotency_key)`
- **Required invariants (enforced via `CHECK` constraints and triggers)**:
  - `scope` (`create:<settlement_uuid>` or `entry:<settlement_uuid>`), canonically trimmed `idempotency_key` (`idempotency_key = btrim(idempotency_key)` and `8..128` chars), lowercase hex SHA-256 `request_hash`, `status_code` (`201` for `create:*` at `version = 1`; `202` for `entry:*` at `version >= 2`), and closed-schema `response_body` (`WriteAcceptedResponse` in `openapi.yaml` with `accepted = true` and `idempotentReplay = false`).
  - On `INSERT`, the referenced event (`eventId`, `settlementId`, `version`, `idempotency_key`) must exist in both `clearledger.events` and `clearledger.outbox`, and each `response_body->>'eventId'` (as well as each `(response_body->>'settlementId', (response_body->>'version')::integer)` pair) must be unique across `clearledger.idempotency_keys`. `UPDATE` and `DELETE` must be rejected.

### 5. Required Indexes in `clearledger` Schema

Create and maintain all six of the following indexes in the `clearledger` schema (recreating any missing index during `deploy.sh`):

- `idx_clearledger_outbox_unpublished`: on `clearledger.outbox (seq)` with partial predicate `WHERE published_at IS NULL`
- `idx_clearledger_outbox_unarchived`: on `clearledger.outbox (seq)` with partial predicate `WHERE published_at IS NOT NULL AND archived_at IS NULL`
- `idx_clearledger_events_settlement_version`: on `clearledger.events (settlement_id, aggregate_version)`
- `idx_clearledger_idempotency_event`: `UNIQUE INDEX` on `clearledger.idempotency_keys (((response_body->>'eventId')::uuid))`
- `idx_clearledger_idempotency_version`: `UNIQUE INDEX` on `clearledger.idempotency_keys (((response_body->>'settlementId')::uuid), ((response_body->>'version')::integer))`
- `idx_clearledger_entry_id`: `UNIQUE INDEX` on `clearledger.events (settlement_id, ((payload->'data'->>'entryId')::uuid))` with partial predicate `WHERE event_type = 'LedgerEntryRecorded'`

