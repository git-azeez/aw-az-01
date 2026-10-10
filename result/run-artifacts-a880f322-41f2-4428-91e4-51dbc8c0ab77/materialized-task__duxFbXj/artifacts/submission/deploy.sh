#!/usr/bin/env bash
# ClearLedger deployment: terraform apply + PostgreSQL schema + manifest +
# readiness wait + data-plane convergence. Safe to re-run (idempotent repair).
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${SCRIPT_DIR}/infra"
CONFIG_PATH="${CL_CONFIG:-/workspace/config/config.json}"
MANIFEST_PATH="${SCRIPT_DIR}/manifest.json"
STATE_PATH="${INFRA_DIR}/terraform.tfstate"

log() { printf '[deploy %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

[[ -f "${CONFIG_PATH}" ]] || die "config not found: ${CONFIG_PATH}"

PREFIX="$(jq -r '.resource_prefix' "${CONFIG_PATH}")"
REGION="$(jq -r '.region' "${CONFIG_PATH}")"
ENDPOINT="$(jq -r '.aws_endpoint_url' "${CONFIG_PATH}")"
DB_PASSWORD="$(jq -r '.db_password' "${CONFIG_PATH}")"

export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_REGION="${REGION}"
export AWS_DEFAULT_REGION="${REGION}"
export AWS_ENDPOINT_URL="${ENDPOINT}"
export AWS_EC2_METADATA_DISABLED=true
export TF_IN_AUTOMATION=1
export TF_INPUT=0
export CL_CONFIG="${CONFIG_PATH}"
export CL_STATE="${STATE_PATH}"
export PYTHONUNBUFFERED=1

if command -v terraform >/dev/null 2>&1; then TF=terraform; elif command -v tofu >/dev/null 2>&1; then TF=tofu; else die "terraform/tofu not found"; fi

WORK="$(mktemp -d /tmp/clearledger-deploy.XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT

log "deploying ClearLedger prefix=${PREFIX} region=${REGION} endpoint=${ENDPOINT} (${TF})"

# ---------------------------------------------------------------------------
# Embedded helpers
# ---------------------------------------------------------------------------
cat > "${WORK}/schema.sql" <<'CLEARLEDGER_SQL'
-- ClearLedger PostgreSQL schema (idempotent).
SET lock_timeout = '15s';
SET statement_timeout = '120s';
SET client_min_messages = warning;

CREATE SCHEMA IF NOT EXISTS clearledger;

-- ---------------------------------------------------------------------------
-- Helper functions
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION clearledger.status_rank(s text)
RETURNS integer LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE s
    WHEN 'INITIATED'  THEN 0
    WHEN 'VALIDATED'  THEN 1
    WHEN 'RESERVED'   THEN 2
    WHEN 'CLEARED'    THEN 3
    WHEN 'SETTLED'    THEN 4
    WHEN 'RECONCILED' THEN 5
    ELSE NULL
  END
$$;

CREATE OR REPLACE FUNCTION clearledger.status_transition_ok(old_s text, new_s text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN old_s IS NULL OR new_s IS NULL THEN false
    WHEN new_s NOT IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED') THEN false
    WHEN old_s = 'RECONCILED' THEN false
    WHEN old_s = 'DISPUTED' THEN new_s IN ('DISPUTED', 'RECONCILED')
    WHEN new_s = 'DISPUTED' THEN true
    ELSE COALESCE(clearledger.status_rank(new_s) >= clearledger.status_rank(old_s), false)
  END
$$;

CREATE OR REPLACE FUNCTION clearledger.is_trimmed_text(v text, min_len integer, max_len integer)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT v IS NOT NULL
     AND v = btrim(v)
     AND char_length(v) BETWEEN min_len AND max_len
$$;

CREATE OR REPLACE FUNCTION clearledger.is_uuid_text(v text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT v IS NOT NULL
     AND v ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$$;

-- Strict validation of ClearLedgerDomainEventEnvelope (events.schema.json).
CREATE OR REPLACE FUNCTION clearledger.is_valid_envelope(p jsonb)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  d       jsonb;
  v       bigint;
  et      text;
  kind    text;
  st      text;
  stage   text;
  debit   text;
  credit  text;
  ts      timestamptz;
  env_keys  constant text[] := ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId',
                                     'aggregateVersion','occurredAt','correlationId','idempotencyKey','data'];
  data_keys constant text[] := ARRAY['kind','accountId','reference','debitParty','creditParty',
                                     'entryId','status','clearingStage','memo'];
  data_req  constant text[] := ARRAY['kind','accountId','reference','debitParty','creditParty',
                                     'status','clearingStage'];
  k text;
BEGIN
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN
    RETURN false;
  END IF;
  IF NOT (p ?& env_keys) THEN
    RETURN false;
  END IF;
  FOR k IN SELECT jsonb_object_keys(p) LOOP
    IF NOT (k = ANY (env_keys)) THEN
      RETURN false;
    END IF;
  END LOOP;

  IF jsonb_typeof(p->'schemaVersion') <> 'string' OR p->>'schemaVersion' <> '1.0' THEN RETURN false; END IF;
  IF jsonb_typeof(p->'eventId') <> 'string' OR NOT clearledger.is_uuid_text(p->>'eventId') THEN RETURN false; END IF;
  IF jsonb_typeof(p->'eventType') <> 'string' OR p->>'eventType' NOT IN ('SettlementInitiated','LedgerEntryRecorded') THEN RETURN false; END IF;
  IF jsonb_typeof(p->'aggregateType') <> 'string' OR p->>'aggregateType' <> 'settlement' THEN RETURN false; END IF;
  IF jsonb_typeof(p->'aggregateId') <> 'string' OR NOT clearledger.is_uuid_text(p->>'aggregateId') THEN RETURN false; END IF;
  IF jsonb_typeof(p->'aggregateVersion') <> 'number' OR (p->>'aggregateVersion') !~ '^[0-9]{1,9}$' THEN RETURN false; END IF;
  v := (p->>'aggregateVersion')::bigint;
  IF v < 1 THEN RETURN false; END IF;
  IF jsonb_typeof(p->'occurredAt') <> 'string'
     OR (p->>'occurredAt') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?([Zz]|[+-][0-9]{2}:[0-9]{2})$' THEN
    RETURN false;
  END IF;
  ts := (p->>'occurredAt')::timestamptz;
  IF jsonb_typeof(p->'correlationId') <> 'string' OR NOT clearledger.is_trimmed_text(p->>'correlationId', 4, 128) THEN RETURN false; END IF;
  IF jsonb_typeof(p->'idempotencyKey') <> 'string' OR NOT clearledger.is_trimmed_text(p->>'idempotencyKey', 8, 128) THEN RETURN false; END IF;

  d := p->'data';
  IF jsonb_typeof(d) <> 'object' THEN RETURN false; END IF;
  FOR k IN SELECT jsonb_object_keys(d) LOOP
    IF NOT (k = ANY (data_keys)) THEN
      RETURN false;
    END IF;
  END LOOP;
  FOREACH k IN ARRAY data_req LOOP
    IF NOT (d ? k) OR jsonb_typeof(d->k) <> 'string' THEN
      RETURN false;
    END IF;
  END LOOP;

  et     := p->>'eventType';
  kind   := d->>'kind';
  st     := d->>'status';
  stage  := d->>'clearingStage';
  debit  := d->>'debitParty';
  credit := d->>'creditParty';

  IF NOT clearledger.is_trimmed_text(d->>'accountId', 3, 64) THEN RETURN false; END IF;
  IF NOT clearledger.is_trimmed_text(d->>'reference', 3, 64) THEN RETURN false; END IF;
  IF NOT clearledger.is_trimmed_text(debit, 2, 64) THEN RETURN false; END IF;
  IF NOT clearledger.is_trimmed_text(credit, 2, 64) THEN RETURN false; END IF;
  IF debit = credit THEN RETURN false; END IF;
  IF st NOT IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED') THEN RETURN false; END IF;
  IF stage IS NULL OR stage <> btrim(stage) OR char_length(stage) < 2 THEN RETURN false; END IF;

  IF d ? 'entryId' AND jsonb_typeof(d->'entryId') NOT IN ('string', 'null') THEN RETURN false; END IF;
  IF jsonb_typeof(d->'entryId') = 'string' AND NOT clearledger.is_uuid_text(d->>'entryId') THEN RETURN false; END IF;
  IF d ? 'memo' AND jsonb_typeof(d->'memo') NOT IN ('string', 'null') THEN RETURN false; END IF;
  IF jsonb_typeof(d->'memo') = 'string' AND NOT clearledger.is_trimmed_text(d->>'memo', 1, 256) THEN RETURN false; END IF;

  IF et = 'SettlementInitiated' THEN
    IF kind <> 'settlementInitiated' OR v <> 1 OR st <> 'INITIATED' THEN RETURN false; END IF;
    IF stage <> ('INITIATED@' || debit) THEN RETURN false; END IF;
    IF (d->>'memo') IS DISTINCT FROM 'Settlement initiated' THEN RETURN false; END IF;
    IF (d->>'entryId') IS NOT NULL THEN RETURN false; END IF;
  ELSE
    IF kind <> 'ledgerEntryRecorded' OR v < 2 OR st = 'INITIATED' THEN RETURN false; END IF;
    IF char_length(stage) > 64 THEN RETURN false; END IF;
    IF (d->>'entryId') IS NULL THEN RETURN false; END IF;
  END IF;

  RETURN true;
EXCEPTION WHEN others THEN
  RETURN false;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.event_matches_envelope(
  p jsonb, c_event_id uuid, c_settlement_id uuid, c_version integer, c_event_type text,
  c_correlation_id text, c_idempotency_key text, c_occurred_at timestamptz)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF NOT clearledger.is_valid_envelope(p) THEN
    RETURN false;
  END IF;
  RETURN (p->>'eventId')::uuid = c_event_id
     AND (p->>'aggregateId')::uuid = c_settlement_id
     AND (p->>'aggregateVersion')::integer = c_version
     AND p->>'eventType' = c_event_type
     AND p->>'correlationId' = c_correlation_id
     AND p->>'idempotencyKey' = c_idempotency_key
     AND (p->>'occurredAt')::timestamptz = c_occurred_at;
EXCEPTION WHEN others THEN
  RETURN false;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.outbox_matches_envelope(
  p jsonb, c_event_id uuid, c_settlement_id uuid, c_version integer, c_correlation_id text)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF NOT clearledger.is_valid_envelope(p) THEN
    RETURN false;
  END IF;
  RETURN (p->>'eventId')::uuid = c_event_id
     AND (p->>'aggregateId')::uuid = c_settlement_id
     AND (p->>'aggregateVersion')::integer = c_version
     AND p->>'correlationId' = c_correlation_id;
EXCEPTION WHEN others THEN
  RETURN false;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.is_valid_write_response(scope text, status_code integer, r jsonb)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  k text;
  v bigint;
  allowed constant text[] := ARRAY['settlementId','eventId','version','accepted','idempotentReplay'];
BEGIN
  IF r IS NULL OR jsonb_typeof(r) <> 'object' OR NOT (r ?& allowed) THEN
    RETURN false;
  END IF;
  FOR k IN SELECT jsonb_object_keys(r) LOOP
    IF NOT (k = ANY (allowed)) THEN
      RETURN false;
    END IF;
  END LOOP;
  IF jsonb_typeof(r->'settlementId') <> 'string' OR NOT clearledger.is_uuid_text(r->>'settlementId') THEN RETURN false; END IF;
  IF jsonb_typeof(r->'eventId') <> 'string' OR NOT clearledger.is_uuid_text(r->>'eventId') THEN RETURN false; END IF;
  IF jsonb_typeof(r->'version') <> 'number' OR (r->>'version') !~ '^[0-9]{1,9}$' THEN RETURN false; END IF;
  v := (r->>'version')::bigint;
  IF v < 1 THEN RETURN false; END IF;
  IF r->'accepted' <> 'true'::jsonb THEN RETURN false; END IF;
  IF r->'idempotentReplay' <> 'false'::jsonb THEN RETURN false; END IF;
  IF scope IS NULL OR scope !~ '^(create|entry):[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN
    RETURN false;
  END IF;
  IF split_part(scope, ':', 2)::uuid <> (r->>'settlementId')::uuid THEN RETURN false; END IF;
  IF split_part(scope, ':', 1) = 'create' THEN
    RETURN status_code = 201 AND v = 1;
  ELSE
    RETURN status_code = 202 AND v >= 2;
  END IF;
EXCEPTION WHEN others THEN
  RETURN false;
END
$$;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS clearledger.settlements (
  settlement_id  UUID        NOT NULL,
  account_id     TEXT        NOT NULL,
  reference      TEXT        NOT NULL,
  debit_party    TEXT        NOT NULL,
  credit_party   TEXT        NOT NULL,
  current_status TEXT        NOT NULL,
  current_stage  TEXT        NOT NULL,
  last_entry_id  UUID        NULL,
  last_memo      TEXT        NULL,
  version        INTEGER     NOT NULL,
  entry_count    INTEGER     NOT NULL DEFAULT 0,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT settlements_pkey PRIMARY KEY (settlement_id)
);

CREATE TABLE IF NOT EXISTS clearledger.events (
  seq               BIGSERIAL   NOT NULL,
  event_id          UUID        NOT NULL,
  settlement_id     UUID        NOT NULL,
  aggregate_version INTEGER     NOT NULL,
  event_type        TEXT        NOT NULL,
  correlation_id    TEXT        NOT NULL,
  idempotency_key   TEXT        NOT NULL,
  occurred_at       TIMESTAMPTZ NOT NULL,
  payload           JSONB       NOT NULL,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT events_pkey PRIMARY KEY (seq)
);

CREATE TABLE IF NOT EXISTS clearledger.outbox (
  seq               BIGSERIAL   NOT NULL,
  event_id          UUID        NOT NULL,
  settlement_id     UUID        NOT NULL,
  aggregate_version INTEGER     NOT NULL,
  correlation_id    TEXT        NOT NULL,
  payload           JSONB       NOT NULL,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  published_at      TIMESTAMPTZ NULL,
  archived_at       TIMESTAMPTZ NULL,
  attempts          INTEGER     NOT NULL DEFAULT 0,
  last_error        TEXT        NULL,
  CONSTRAINT outbox_pkey PRIMARY KEY (seq)
);

CREATE TABLE IF NOT EXISTS clearledger.idempotency_keys (
  scope           TEXT        NOT NULL,
  idempotency_key TEXT        NOT NULL,
  request_hash    TEXT        NOT NULL,
  status_code     INTEGER     NOT NULL,
  response_body   JSONB       NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT idempotency_keys_pkey PRIMARY KEY (scope, idempotency_key)
);

-- ---------------------------------------------------------------------------
-- Constraints (added only when missing)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pg_temp.ensure_constraint(tbl text, cname text, ddl text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE n.nspname = 'clearledger' AND t.relname = tbl AND c.conname = cname
  ) THEN
    EXECUTE format('ALTER TABLE clearledger.%I ADD CONSTRAINT %I %s', tbl, cname, ddl);
  END IF;
END
$$;

SELECT pg_temp.ensure_constraint('settlements', 'settlements_pkey', 'PRIMARY KEY (settlement_id)');
SELECT pg_temp.ensure_constraint('events', 'events_pkey', 'PRIMARY KEY (seq)');
SELECT pg_temp.ensure_constraint('outbox', 'outbox_pkey', 'PRIMARY KEY (seq)');
SELECT pg_temp.ensure_constraint('idempotency_keys', 'idempotency_keys_pkey', 'PRIMARY KEY (scope, idempotency_key)');

-- clearledger.settlements
SELECT pg_temp.ensure_constraint('settlements', 'settlements_account_id_check',
  $c$CHECK (clearledger.is_trimmed_text(account_id, 3, 64))$c$);
SELECT pg_temp.ensure_constraint('settlements', 'settlements_reference_check',
  $c$CHECK (clearledger.is_trimmed_text(reference, 3, 64))$c$);
SELECT pg_temp.ensure_constraint('settlements', 'settlements_debit_party_check',
  $c$CHECK (clearledger.is_trimmed_text(debit_party, 2, 64))$c$);
SELECT pg_temp.ensure_constraint('settlements', 'settlements_credit_party_check',
  $c$CHECK (clearledger.is_trimmed_text(credit_party, 2, 64))$c$);
SELECT pg_temp.ensure_constraint('settlements', 'settlements_parties_distinct_check',
  $c$CHECK (debit_party <> credit_party)$c$);
SELECT pg_temp.ensure_constraint('settlements', 'settlements_status_check',
  $c$CHECK (current_status IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED'))$c$);
SELECT pg_temp.ensure_constraint('settlements', 'settlements_stage_check',
  $c$CHECK (current_stage = btrim(current_stage) AND char_length(current_stage) >= 2
            AND (version = 1 OR char_length(current_stage) <= 64))$c$);
SELECT pg_temp.ensure_constraint('settlements', 'settlements_last_memo_check',
  $c$CHECK (last_memo IS NULL OR clearledger.is_trimmed_text(last_memo, 1, 256))$c$);
SELECT pg_temp.ensure_constraint('settlements', 'settlements_version_check',
  $c$CHECK (version >= 1 AND entry_count >= 0 AND entry_count = version - 1)$c$);
SELECT pg_temp.ensure_constraint('settlements', 'settlements_initiation_check',
  $c$CHECK (version <> 1 OR (
        entry_count = 0
    AND current_status = 'INITIATED'
    AND current_stage = 'INITIATED@' || debit_party
    AND last_entry_id IS NULL
    AND last_memo = 'Settlement initiated'
    AND updated_at = created_at))$c$);
SELECT pg_temp.ensure_constraint('settlements', 'settlements_progress_check',
  $c$CHECK (version = 1 OR (
        entry_count = version - 1
    AND current_status <> 'INITIATED'
    AND last_entry_id IS NOT NULL
    AND updated_at > created_at))$c$);

-- clearledger.events
SELECT pg_temp.ensure_constraint('events', 'events_event_id_key', 'UNIQUE (event_id)');
SELECT pg_temp.ensure_constraint('events', 'events_settlement_version_key', 'UNIQUE (settlement_id, aggregate_version)');
SELECT pg_temp.ensure_constraint('events', 'events_settlement_idempotency_key', 'UNIQUE (settlement_id, idempotency_key)');
SELECT pg_temp.ensure_constraint('events', 'events_settlement_id_fkey',
  'FOREIGN KEY (settlement_id) REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE');
SELECT pg_temp.ensure_constraint('events', 'events_aggregate_version_check', 'CHECK (aggregate_version >= 1)');
SELECT pg_temp.ensure_constraint('events', 'events_event_type_check',
  $c$CHECK (event_type IN ('SettlementInitiated','LedgerEntryRecorded'))$c$);
SELECT pg_temp.ensure_constraint('events', 'events_correlation_id_check',
  $c$CHECK (clearledger.is_trimmed_text(correlation_id, 4, 128))$c$);
SELECT pg_temp.ensure_constraint('events', 'events_idempotency_key_check',
  $c$CHECK (clearledger.is_trimmed_text(idempotency_key, 8, 128))$c$);
SELECT pg_temp.ensure_constraint('events', 'events_version_kind_check',
  $c$CHECK ((event_type = 'SettlementInitiated' AND aggregate_version = 1)
         OR (event_type = 'LedgerEntryRecorded' AND aggregate_version >= 2))$c$);
SELECT pg_temp.ensure_constraint('events', 'events_payload_envelope_check',
  $c$CHECK (clearledger.event_matches_envelope(payload, event_id, settlement_id, aggregate_version,
            event_type, correlation_id, idempotency_key, occurred_at))$c$);

-- clearledger.outbox
SELECT pg_temp.ensure_constraint('outbox', 'outbox_event_id_key', 'UNIQUE (event_id)');
SELECT pg_temp.ensure_constraint('outbox', 'outbox_settlement_version_key', 'UNIQUE (settlement_id, aggregate_version)');
SELECT pg_temp.ensure_constraint('outbox', 'outbox_event_id_fkey',
  'FOREIGN KEY (event_id) REFERENCES clearledger.events(event_id) ON DELETE CASCADE');
SELECT pg_temp.ensure_constraint('outbox', 'outbox_settlement_id_fkey',
  'FOREIGN KEY (settlement_id) REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE');
SELECT pg_temp.ensure_constraint('outbox', 'outbox_settlement_version_fkey',
  'FOREIGN KEY (settlement_id, aggregate_version) REFERENCES clearledger.events(settlement_id, aggregate_version) ON DELETE CASCADE');
SELECT pg_temp.ensure_constraint('outbox', 'outbox_aggregate_version_check', 'CHECK (aggregate_version >= 1)');
SELECT pg_temp.ensure_constraint('outbox', 'outbox_correlation_id_check',
  $c$CHECK (clearledger.is_trimmed_text(correlation_id, 4, 128))$c$);
SELECT pg_temp.ensure_constraint('outbox', 'outbox_payload_envelope_check',
  $c$CHECK (clearledger.outbox_matches_envelope(payload, event_id, settlement_id, aggregate_version, correlation_id))$c$);
SELECT pg_temp.ensure_constraint('outbox', 'outbox_attempts_check', 'CHECK (attempts >= 0)');
SELECT pg_temp.ensure_constraint('outbox', 'outbox_unattempted_check',
  'CHECK (attempts <> 0 OR (published_at IS NULL AND last_error IS NULL))');
SELECT pg_temp.ensure_constraint('outbox', 'outbox_published_check',
  'CHECK (published_at IS NULL OR (attempts >= 1 AND last_error IS NULL AND published_at >= created_at))');
SELECT pg_temp.ensure_constraint('outbox', 'outbox_last_error_check',
  $c$CHECK (last_error IS NULL OR (published_at IS NULL AND attempts >= 1
            AND length(btrim(last_error)) > 0 AND last_error = btrim(last_error)))$c$);
SELECT pg_temp.ensure_constraint('outbox', 'outbox_archived_check',
  'CHECK (archived_at IS NULL OR (published_at IS NOT NULL AND archived_at >= published_at))');

-- clearledger.idempotency_keys
SELECT pg_temp.ensure_constraint('idempotency_keys', 'idempotency_keys_scope_check',
  $c$CHECK (scope ~ '^(create|entry):[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')$c$);
SELECT pg_temp.ensure_constraint('idempotency_keys', 'idempotency_keys_key_check',
  $c$CHECK (clearledger.is_trimmed_text(idempotency_key, 8, 128))$c$);
SELECT pg_temp.ensure_constraint('idempotency_keys', 'idempotency_keys_request_hash_check',
  $c$CHECK (request_hash ~ '^[0-9a-f]{64}$')$c$);
SELECT pg_temp.ensure_constraint('idempotency_keys', 'idempotency_keys_status_code_check',
  $c$CHECK ((scope LIKE 'create:%' AND status_code = 201) OR (scope LIKE 'entry:%' AND status_code = 202))$c$);
SELECT pg_temp.ensure_constraint('idempotency_keys', 'idempotency_keys_response_body_check',
  $c$CHECK (clearledger.is_valid_write_response(scope, status_code, response_body))$c$);

-- ---------------------------------------------------------------------------
-- Trigger functions
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION clearledger.trg_reject_mutation()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'clearledger.%: % is not permitted (append-only ledger)', TG_TABLE_NAME, TG_OP
    USING ERRCODE = 'P0001';
END
$$;

CREATE OR REPLACE FUNCTION clearledger.trg_settlements_before_update()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.current_status = 'RECONCILED' THEN
    RAISE EXCEPTION 'settlement % is RECONCILED (terminal)', OLD.settlement_id USING ERRCODE = 'P0001';
  END IF;
  IF NEW.settlement_id IS DISTINCT FROM OLD.settlement_id
     OR NEW.account_id IS DISTINCT FROM OLD.account_id
     OR NEW.reference IS DISTINCT FROM OLD.reference
     OR NEW.debit_party IS DISTINCT FROM OLD.debit_party
     OR NEW.credit_party IS DISTINCT FROM OLD.credit_party
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'settlement % header columns are immutable', OLD.settlement_id USING ERRCODE = 'P0001';
  END IF;
  IF NEW.version IS DISTINCT FROM OLD.version + 1 THEN
    RAISE EXCEPTION 'settlement % version must advance by exactly 1', OLD.settlement_id USING ERRCODE = 'P0001';
  END IF;
  IF NEW.entry_count IS DISTINCT FROM OLD.entry_count + 1 THEN
    RAISE EXCEPTION 'settlement % entry_count must advance by exactly 1', OLD.settlement_id USING ERRCODE = 'P0001';
  END IF;
  IF NEW.last_entry_id IS NULL OR NEW.last_entry_id IS NOT DISTINCT FROM OLD.last_entry_id THEN
    RAISE EXCEPTION 'settlement % requires a new last_entry_id', OLD.settlement_id USING ERRCODE = 'P0001';
  END IF;
  IF NOT (NEW.updated_at > OLD.updated_at) THEN
    RAISE EXCEPTION 'settlement % updated_at must strictly increase', OLD.settlement_id USING ERRCODE = 'P0001';
  END IF;
  IF NOT clearledger.status_transition_ok(OLD.current_status, NEW.current_status) THEN
    RAISE EXCEPTION 'settlement % illegal status transition % -> %', OLD.settlement_id, OLD.current_status, NEW.current_status
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.trg_events_before_insert()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  s     clearledger.settlements%ROWTYPE;
  d     jsonb;
  max_v integer;
  prev  clearledger.events%ROWTYPE;
BEGIN
  IF NOT clearledger.event_matches_envelope(NEW.payload, NEW.event_id, NEW.settlement_id, NEW.aggregate_version,
                                            NEW.event_type, NEW.correlation_id, NEW.idempotency_key, NEW.occurred_at) THEN
    RAISE EXCEPTION 'event % payload does not match ClearLedgerDomainEventEnvelope or its columns', NEW.event_id
      USING ERRCODE = '23514';
  END IF;
  d := NEW.payload->'data';

  SELECT * INTO s FROM clearledger.settlements WHERE settlement_id = NEW.settlement_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'event % references unknown settlement %', NEW.event_id, NEW.settlement_id USING ERRCODE = '23503';
  END IF;

  SELECT max(aggregate_version) INTO max_v FROM clearledger.events WHERE settlement_id = NEW.settlement_id;
  IF NEW.aggregate_version IS DISTINCT FROM COALESCE(max_v, 0) + 1 THEN
    RAISE EXCEPTION 'event % aggregate_version % is not contiguous', NEW.event_id, NEW.aggregate_version
      USING ERRCODE = 'P0001';
  END IF;

  IF NEW.event_type = 'LedgerEntryRecorded' AND EXISTS (
       SELECT 1 FROM clearledger.events e
       WHERE e.settlement_id = NEW.settlement_id
         AND e.event_type = 'LedgerEntryRecorded'
         AND (e.payload->'data'->>'entryId')::uuid = (d->>'entryId')::uuid) THEN
    RAISE EXCEPTION 'event % reuses entryId % for settlement %', NEW.event_id, d->>'entryId', NEW.settlement_id
      USING ERRCODE = '23505';
  END IF;

  IF d->>'accountId' IS DISTINCT FROM s.account_id
     OR d->>'reference' IS DISTINCT FROM s.reference
     OR d->>'debitParty' IS DISTINCT FROM s.debit_party
     OR d->>'creditParty' IS DISTINCT FROM s.credit_party
     OR d->>'status' IS DISTINCT FROM s.current_status
     OR d->>'clearingStage' IS DISTINCT FROM s.current_stage
     OR (d->>'entryId')::uuid IS DISTINCT FROM s.last_entry_id
     OR d->>'memo' IS DISTINCT FROM s.last_memo
     OR NEW.aggregate_version IS DISTINCT FROM s.version
     OR NEW.occurred_at IS DISTINCT FROM s.updated_at THEN
    RAISE EXCEPTION 'event % does not match settlement % state', NEW.event_id, NEW.settlement_id USING ERRCODE = 'P0001';
  END IF;

  IF NEW.aggregate_version = 1 THEN
    IF NEW.occurred_at IS DISTINCT FROM s.created_at THEN
      RAISE EXCEPTION 'initiation event % occurred_at must equal settlement created_at', NEW.event_id USING ERRCODE = 'P0001';
    END IF;
  ELSE
    SELECT * INTO prev FROM clearledger.events
     WHERE settlement_id = NEW.settlement_id AND aggregate_version = NEW.aggregate_version - 1;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'event % has no predecessor', NEW.event_id USING ERRCODE = 'P0001';
    END IF;
    IF NOT (NEW.occurred_at > prev.occurred_at) THEN
      RAISE EXCEPTION 'event % occurred_at must be after the preceding event', NEW.event_id USING ERRCODE = 'P0001';
    END IF;
    IF NOT clearledger.status_transition_ok(prev.payload->'data'->>'status', d->>'status') THEN
      RAISE EXCEPTION 'event % illegal status transition % -> %', NEW.event_id, prev.payload->'data'->>'status', d->>'status'
        USING ERRCODE = 'P0001';
    END IF;
  END IF;

  RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.trg_outbox_before_insert()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  e     clearledger.events%ROWTYPE;
  max_v integer;
BEGIN
  SELECT * INTO e FROM clearledger.events WHERE event_id = NEW.event_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'outbox row references unknown event %', NEW.event_id USING ERRCODE = '23503';
  END IF;
  IF e.settlement_id IS DISTINCT FROM NEW.settlement_id
     OR e.aggregate_version IS DISTINCT FROM NEW.aggregate_version
     OR e.correlation_id IS DISTINCT FROM NEW.correlation_id
     OR e.payload IS DISTINCT FROM NEW.payload THEN
    RAISE EXCEPTION 'outbox row for event % must mirror clearledger.events', NEW.event_id USING ERRCODE = 'P0001';
  END IF;
  SELECT max(aggregate_version) INTO max_v FROM clearledger.outbox WHERE settlement_id = NEW.settlement_id;
  IF NEW.aggregate_version IS DISTINCT FROM COALESCE(max_v, 0) + 1 THEN
    RAISE EXCEPTION 'outbox row for event % is not contiguous', NEW.event_id USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.trg_outbox_before_update()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.seq IS DISTINCT FROM OLD.seq
     OR NEW.event_id IS DISTINCT FROM OLD.event_id
     OR NEW.settlement_id IS DISTINCT FROM OLD.settlement_id
     OR NEW.aggregate_version IS DISTINCT FROM OLD.aggregate_version
     OR NEW.correlation_id IS DISTINCT FROM OLD.correlation_id
     OR NEW.payload IS DISTINCT FROM OLD.payload
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'outbox row % envelope columns are immutable', OLD.seq USING ERRCODE = 'P0001';
  END IF;
  IF NEW.attempts < OLD.attempts THEN
    RAISE EXCEPTION 'outbox row % attempts cannot decrease', OLD.seq USING ERRCODE = 'P0001';
  END IF;

  IF OLD.published_at IS NULL AND NEW.published_at IS NOT NULL THEN
    IF NOT (NEW.attempts > OLD.attempts) THEN
      RAISE EXCEPTION 'outbox row % publish must increment attempts', OLD.seq USING ERRCODE = 'P0001';
    END IF;
    IF NEW.archived_at IS NOT NULL THEN
      RAISE EXCEPTION 'outbox row % cannot be archived while being published', OLD.seq USING ERRCODE = 'P0001';
    END IF;
  ELSIF OLD.published_at IS NOT NULL AND NEW.published_at IS NOT NULL THEN
    IF NEW.published_at IS DISTINCT FROM OLD.published_at
       OR NEW.attempts IS DISTINCT FROM OLD.attempts
       OR NEW.last_error IS DISTINCT FROM OLD.last_error THEN
      RAISE EXCEPTION 'outbox row % delivery columns are immutable once published', OLD.seq USING ERRCODE = 'P0001';
    END IF;
    IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NOT NULL
       AND NEW.archived_at IS DISTINCT FROM OLD.archived_at THEN
      RAISE EXCEPTION 'outbox row % archived_at cannot be rewritten without reset', OLD.seq USING ERRCODE = 'P0001';
    END IF;
  ELSIF OLD.published_at IS NOT NULL AND NEW.published_at IS NULL THEN
    IF NEW.archived_at IS NOT NULL THEN
      RAISE EXCEPTION 'outbox row % replay reset requires archived_at = NULL', OLD.seq USING ERRCODE = 'P0001';
    END IF;
  ELSE
    IF NEW.archived_at IS NOT NULL THEN
      RAISE EXCEPTION 'outbox row % cannot be archived before publishing', OLD.seq USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.trg_idempotency_before_insert()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  r_event   uuid;
  r_settle  uuid;
  r_version integer;
BEGIN
  IF NOT clearledger.is_valid_write_response(NEW.scope, NEW.status_code, NEW.response_body) THEN
    RAISE EXCEPTION 'idempotency key % has an invalid response_body', NEW.idempotency_key USING ERRCODE = '23514';
  END IF;
  r_event   := (NEW.response_body->>'eventId')::uuid;
  r_settle  := (NEW.response_body->>'settlementId')::uuid;
  r_version := (NEW.response_body->>'version')::integer;

  IF NOT EXISTS (
    SELECT 1 FROM clearledger.events e
    WHERE e.event_id = r_event AND e.settlement_id = r_settle
      AND e.aggregate_version = r_version AND e.idempotency_key = NEW.idempotency_key) THEN
    RAISE EXCEPTION 'idempotency key % does not reference a committed event', NEW.idempotency_key USING ERRCODE = '23503';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM clearledger.outbox o
    WHERE o.event_id = r_event AND o.settlement_id = r_settle AND o.aggregate_version = r_version) THEN
    RAISE EXCEPTION 'idempotency key % does not reference an outbox row', NEW.idempotency_key USING ERRCODE = '23503';
  END IF;
  IF EXISTS (
    SELECT 1 FROM clearledger.idempotency_keys k
    WHERE (k.response_body->>'eventId')::uuid = r_event
       OR ((k.response_body->>'settlementId')::uuid = r_settle AND (k.response_body->>'version')::integer = r_version)) THEN
    RAISE EXCEPTION 'idempotency response for event % already recorded', r_event USING ERRCODE = '23505';
  END IF;
  RETURN NEW;
END
$$;

-- ---------------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE TRIGGER settlements_before_update
  BEFORE UPDATE ON clearledger.settlements
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_settlements_before_update();
CREATE OR REPLACE TRIGGER settlements_before_delete
  BEFORE DELETE ON clearledger.settlements
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_reject_mutation();

CREATE OR REPLACE TRIGGER events_before_insert
  BEFORE INSERT ON clearledger.events
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_events_before_insert();
CREATE OR REPLACE TRIGGER events_before_update
  BEFORE UPDATE ON clearledger.events
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_reject_mutation();
CREATE OR REPLACE TRIGGER events_before_delete
  BEFORE DELETE ON clearledger.events
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_reject_mutation();

CREATE OR REPLACE TRIGGER outbox_before_insert
  BEFORE INSERT ON clearledger.outbox
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_outbox_before_insert();
CREATE OR REPLACE TRIGGER outbox_before_update
  BEFORE UPDATE ON clearledger.outbox
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_outbox_before_update();
CREATE OR REPLACE TRIGGER outbox_before_delete
  BEFORE DELETE ON clearledger.outbox
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_reject_mutation();

CREATE OR REPLACE TRIGGER idempotency_keys_before_insert
  BEFORE INSERT ON clearledger.idempotency_keys
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_idempotency_before_insert();
CREATE OR REPLACE TRIGGER idempotency_keys_before_update
  BEFORE UPDATE ON clearledger.idempotency_keys
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_reject_mutation();
CREATE OR REPLACE TRIGGER idempotency_keys_before_delete
  BEFORE DELETE ON clearledger.idempotency_keys
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_reject_mutation();

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['settlements', 'events', 'outbox', 'idempotency_keys'] LOOP
    BEGIN
      EXECUTE format('ALTER TABLE clearledger.%I ENABLE TRIGGER ALL', t);
    EXCEPTION WHEN insufficient_privilege THEN
      EXECUTE format('ALTER TABLE clearledger.%I ENABLE TRIGGER USER', t);
    END;
  END LOOP;
END
$$;

-- ---------------------------------------------------------------------------
-- Required indexes
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT c.relname
    FROM pg_index i
    JOIN pg_class c ON c.oid = i.indexrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'clearledger'
      AND c.relname IN ('idx_clearledger_outbox_unpublished', 'idx_clearledger_outbox_unarchived',
                        'idx_clearledger_events_settlement_version', 'idx_clearledger_idempotency_event',
                        'idx_clearledger_idempotency_version', 'idx_clearledger_entry_id')
      AND NOT (i.indisvalid AND i.indisready)
  LOOP
    EXECUTE format('DROP INDEX clearledger.%I', r.relname);
  END LOOP;
END
$$;

CREATE INDEX IF NOT EXISTS idx_clearledger_outbox_unpublished
  ON clearledger.outbox (seq) WHERE published_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_clearledger_outbox_unarchived
  ON clearledger.outbox (seq) WHERE published_at IS NOT NULL AND archived_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_clearledger_events_settlement_version
  ON clearledger.events (settlement_id, aggregate_version);
CREATE UNIQUE INDEX IF NOT EXISTS idx_clearledger_idempotency_event
  ON clearledger.idempotency_keys (((response_body->>'eventId')::uuid));
CREATE UNIQUE INDEX IF NOT EXISTS idx_clearledger_idempotency_version
  ON clearledger.idempotency_keys (((response_body->>'settlementId')::uuid), ((response_body->>'version')::integer));
CREATE UNIQUE INDEX IF NOT EXISTS idx_clearledger_entry_id
  ON clearledger.events (settlement_id, ((payload->'data'->>'entryId')::uuid))
  WHERE event_type = 'LedgerEntryRecorded';
CLEARLEDGER_SQL

cat > "${WORK}/ops.py" <<'CLEARLEDGER_PY'
#!/usr/bin/env python3
"""ClearLedger operational helpers: pre-apply control-plane repair and
post-apply data-plane convergence (PostgreSQL is the system of record)."""
import hashlib
import json
import os
import re
import sys
import time
import base64
import urllib.request
import urllib.error
from datetime import timezone

import boto3
from botocore.config import Config

CFG = json.load(open(os.environ.get("CL_CONFIG", "/workspace/config/config.json")))
PREFIX = CFG["resource_prefix"]
REGION = CFG["region"]
ENDPOINT = CFG["aws_endpoint_url"]
STATE_PATH = os.environ.get("CL_STATE", "/workspace/submission/infra/terraform.tfstate")
KMS_USAGES = ["database", "messaging", "projection", "audit"]
ROLE_KEYS = {
    "ecs_execution": f"{PREFIX}-ecs-execution",
    "ecs_task": f"{PREFIX}-ecs-task",
    "projector": f"{PREFIX}-projector",
    "relay": f"{PREFIX}-outbox-relay",
    "archiver": f"{PREFIX}-audit-archiver",
    "scheduler": f"{PREFIX}-scheduler",
}

_BOTO_CFG = Config(retries={"max_attempts": 8, "mode": "standard"}, connect_timeout=10, read_timeout=60)


def log(msg):
    print(f"[clearledger-ops] {msg}", flush=True)


def client(name):
    return boto3.client(
        name,
        region_name=REGION,
        endpoint_url=ENDPOINT,
        aws_access_key_id="test",
        aws_secret_access_key="test",
        config=_BOTO_CFG,
    )


# ---------------------------------------------------------------------------
# Pre-apply control-plane repair
# ---------------------------------------------------------------------------

def state_kms_keys():
    """Return {usage: key_id} for KMS keys tracked in terraform state."""
    keys = {}
    try:
        st = json.load(open(STATE_PATH))
    except Exception:
        return keys
    for res in st.get("resources", []):
        if res.get("type") == "aws_kms_key" and res.get("mode") == "managed":
            for inst in res.get("instances", []):
                attrs = inst.get("attributes", {}) or {}
                usage = inst.get("index_key") or (attrs.get("tags") or {}).get("ClearLedgerKeyUsage")
                if attrs.get("key_id") and usage:
                    keys[usage] = attrs["key_id"]
    return keys


def repair_kms():
    kms = client("kms")
    keys = state_kms_keys()
    # Also discover keys through their canonical aliases.
    try:
        for page in kms.get_paginator("list_aliases").paginate():
            for a in page.get("Aliases", []):
                for usage in KMS_USAGES:
                    if a.get("AliasName") == f"alias/{PREFIX}-{usage}" and a.get("TargetKeyId"):
                        keys.setdefault(usage, a["TargetKeyId"])
    except Exception as e:  # pragma: no cover
        log(f"list_aliases failed: {e}")
    for usage, key_id in keys.items():
        try:
            meta = kms.describe_key(KeyId=key_id)["KeyMetadata"]
        except Exception as e:
            log(f"kms {usage} ({key_id}) not describable: {e}")
            continue
        state = meta.get("KeyState")
        if state == "PendingDeletion" or meta.get("DeletionDate"):
            log(f"kms {usage}: cancelling pending deletion")
            kms.cancel_key_deletion(KeyId=key_id)
            meta = kms.describe_key(KeyId=key_id)["KeyMetadata"]
        if meta.get("KeyState") != "Enabled" or not meta.get("Enabled", True):
            log(f"kms {usage}: enabling key (state={meta.get('KeyState')})")
            kms.enable_key(KeyId=key_id)
        try:
            rot = kms.get_key_rotation_status(KeyId=key_id).get("KeyRotationEnabled")
        except Exception:
            rot = False
        if not rot:
            log(f"kms {usage}: enabling key rotation")
            kms.enable_key_rotation(KeyId=key_id)
        want = {"ClearLedgerDeployment": PREFIX, "ClearLedgerKeyUsage": usage, "Name": f"{PREFIX}-{usage}"}
        try:
            have = {t["TagKey"]: t["TagValue"] for t in kms.list_resource_tags(KeyId=key_id).get("Tags", [])}
        except Exception:
            have = {}
        if any(have.get(k) != v for k, v in want.items()):
            log(f"kms {usage}: restoring canonical tags")
            kms.tag_resource(KeyId=key_id, Tags=[{"TagKey": k, "TagValue": v} for k, v in want.items()])


def repair_iam():
    iam = client("iam")
    for key, role in ROLE_KEYS.items():
        canonical = f"{role}-policy"
        try:
            names = []
            for page in iam.get_paginator("list_role_policies").paginate(RoleName=role):
                names.extend(page.get("PolicyNames", []))
        except iam.exceptions.NoSuchEntityException:
            continue
        except Exception as e:
            log(f"iam list_role_policies {role}: {e}")
            continue
        for n in names:
            if n != canonical:
                log(f"iam {role}: deleting out-of-band inline policy {n}")
                iam.delete_role_policy(RoleName=role, PolicyName=n)
        try:
            attached = []
            for page in iam.get_paginator("list_attached_role_policies").paginate(RoleName=role):
                attached.extend(page.get("AttachedPolicies", []))
        except Exception as e:
            log(f"iam list_attached_role_policies {role}: {e}")
            attached = []
        for p in attached:
            log(f"iam {role}: detaching out-of-band managed policy {p['PolicyArn']}")
            iam.detach_role_policy(RoleName=role, PolicyArn=p["PolicyArn"])
    # Delete unattached prefix-scoped customer-managed policies.
    try:
        for page in iam.get_paginator("list_policies").paginate(Scope="Local"):
            for p in page.get("Policies", []):
                if not p["PolicyName"].startswith(PREFIX):
                    continue
                if p.get("AttachmentCount", 0) > 0:
                    # Detach from any entity first; only ClearLedger roles should hold them.
                    ents = iam.list_entities_for_policy(PolicyArn=p["Arn"])
                    for r in ents.get("PolicyRoles", []):
                        iam.detach_role_policy(RoleName=r["RoleName"], PolicyArn=p["Arn"])
                    for u in ents.get("PolicyUsers", []):
                        iam.detach_user_policy(UserName=u["UserName"], PolicyArn=p["Arn"])
                    for g in ents.get("PolicyGroups", []):
                        iam.detach_group_policy(GroupName=g["GroupName"], PolicyArn=p["Arn"])
                delete_managed_policy(iam, p["Arn"])
    except Exception as e:
        log(f"iam local policy cleanup: {e}")


def delete_managed_policy(iam, arn):
    try:
        for v in iam.list_policy_versions(PolicyArn=arn).get("Versions", []):
            if not v.get("IsDefaultVersion"):
                iam.delete_policy_version(PolicyArn=arn, VersionId=v["VersionId"])
    except Exception as e:
        log(f"iam list_policy_versions {arn}: {e}")
    log(f"iam: deleting managed policy {arn}")
    iam.delete_policy(PolicyArn=arn)


def cmd_pre():
    for fn in (repair_kms, repair_iam):
        try:
            fn()
        except Exception as e:
            log(f"{fn.__name__} failed (continuing): {e}")


# ---------------------------------------------------------------------------
# Canonical serialisation helpers
# ---------------------------------------------------------------------------

ENV_ORDER = ["schemaVersion", "eventId", "eventType", "aggregateType", "aggregateId",
             "aggregateVersion", "occurredAt", "correlationId", "idempotencyKey", "data"]
DATA_ORDER = ["kind", "accountId", "reference", "debitParty", "creditParty",
              "entryId", "status", "clearingStage", "memo"]


def _ordered(obj, order):
    out = {}
    for k in order:
        if k in obj:
            out[k] = obj[k]
    for k in obj:
        if k not in out:
            out[k] = obj[k]
    return out


def canonical_envelope(payload):
    env = _ordered(payload, ENV_ORDER)
    if isinstance(env.get("data"), dict):
        env["data"] = _ordered(env["data"], DATA_ORDER)
    return json.dumps(env, separators=(",", ":"), ensure_ascii=False)


def rfc3339(dt):
    """chrono::DateTime<Utc>::to_rfc3339() (SecondsFormat::AutoSi)."""
    dt = dt.astimezone(timezone.utc)
    base = dt.strftime("%Y-%m-%dT%H:%M:%S")
    us = dt.microsecond
    if us == 0:
        frac = ""
    elif us % 1000 == 0:
        frac = ".%03d" % (us // 1000)
    else:
        frac = ".%06d" % us
    return base + frac + "+00:00"


# ---------------------------------------------------------------------------
# Data-plane convergence
# ---------------------------------------------------------------------------

def pg_connect(m):
    import psycopg
    db = m["database"]
    return psycopg.connect(
        host=db["endpoint"], port=db["port"], dbname=db["db_name"], user=db["username"],
        password=CFG["db_password"], connect_timeout=15, autocommit=False,
    )


def drain_outbox(m, conn):
    sqs = client("sqs")
    url = m["messaging"]["queue_url"]
    total = 0
    while True:
        with conn.transaction():
            rows = conn.execute(
                "SELECT seq, payload FROM clearledger.outbox WHERE published_at IS NULL "
                "ORDER BY seq LIMIT 50 FOR UPDATE SKIP LOCKED").fetchall()
            if not rows:
                break
            for seq, payload in rows:
                sqs.send_message(QueueUrl=url, MessageBody=canonical_envelope(payload))
                conn.execute(
                    "UPDATE clearledger.outbox SET published_at = GREATEST(NOW(), created_at), "
                    "attempts = attempts + 1, last_error = NULL WHERE seq = %s", (seq,))
                total += 1
    left = conn.execute("SELECT count(*) FROM clearledger.outbox WHERE published_at IS NULL").fetchone()[0]
    conn.commit()
    log(f"outbox: published {total} pending rows ({left} still unpublished)")


def wait_queue_drained(m, timeout=120):
    sqs = client("sqs")
    url = m["messaging"]["queue_url"]
    deadline = time.time() + timeout
    stable = 0
    while time.time() < deadline:
        a = sqs.get_queue_attributes(QueueUrl=url, AttributeNames=[
            "ApproximateNumberOfMessages", "ApproximateNumberOfMessagesNotVisible",
            "ApproximateNumberOfMessagesDelayed"])["Attributes"]
        n = sum(int(a.get(k, 0)) for k in a)
        if n == 0:
            stable += 1
            if stable >= 3:
                log("sqs: main queue drained")
                return True
        else:
            stable = 0
        time.sleep(2)
    log("sqs: main queue not fully drained before timeout (continuing)")
    return False


def load_pg(conn):
    settlements = {}
    for r in conn.execute(
            "SELECT settlement_id::text, account_id, reference, debit_party, credit_party, current_status, "
            "current_stage, last_entry_id::text, last_memo, version, entry_count, updated_at "
            "FROM clearledger.settlements").fetchall():
        settlements[r[0]] = dict(zip(
            ["settlement_id", "account_id", "reference", "debit_party", "credit_party", "status",
             "clearing_stage", "last_entry_id", "last_memo", "version", "entry_count", "updated_at"], r))
    events = {}
    for r in conn.execute(
            "SELECT settlement_id::text, aggregate_version, event_id::text, event_type, correlation_id, "
            "occurred_at, payload FROM clearledger.events ORDER BY settlement_id, aggregate_version").fetchall():
        events.setdefault(r[0], []).append(dict(zip(
            ["settlement_id", "version", "event_id", "event_type", "correlation_id", "occurred_at", "payload"], r)))
    conn.commit()
    return settlements, events


def desired_items(settlements, events):
    items = {}
    for sid, s in settlements.items():
        pk = f"SETTLEMENT#{sid}"
        st = {
            "PK": pk, "SK": "STATE",
            "GSI1PK": f"ACCOUNT#{s['account_id']}", "GSI1SK": pk,
            "settlement_id": sid, "account_id": s["account_id"], "reference": s["reference"],
            "debit_party": s["debit_party"], "credit_party": s["credit_party"],
            "status": s["status"], "clearing_stage": s["clearing_stage"],
            "version": s["version"], "entry_count": s["entry_count"],
            "updated_at": rfc3339(s["updated_at"]),
        }
        if s["last_entry_id"] is not None:
            st["last_entry_id"] = s["last_entry_id"]
        if s["last_memo"] is not None:
            st["last_memo"] = s["last_memo"]
        items[(pk, "STATE")] = st
        for e in events.get(sid, []):
            d = e["payload"].get("data") or {}
            sk = "EVENT#%08d" % e["version"]
            it = {
                "PK": pk, "SK": sk, "settlement_id": sid, "event_id": e["event_id"],
                "version": e["version"], "event_type": e["event_type"],
                "status": d.get("status"), "clearing_stage": d.get("clearingStage"),
                "occurred_at": rfc3339(e["occurred_at"]), "correlation_id": e["correlation_id"],
                "envelope": canonical_envelope(e["payload"]),
            }
            if d.get("entryId") is not None:
                it["entry_id"] = d["entryId"]
            if d.get("memo") is not None:
                it["memo"] = d["memo"]
            items[(pk, sk)] = it
    return items


def to_ddb(item):
    out = {}
    for k, v in item.items():
        if isinstance(v, bool):
            out[k] = {"BOOL": v}
        elif isinstance(v, int):
            out[k] = {"N": str(v)}
        else:
            out[k] = {"S": str(v)}
    return out


def norm_ddb(av):
    out = {}
    for k, v in av.items():
        if "N" in v:
            n = v["N"]
            out[k] = int(n) if re.fullmatch(r"-?\d+", n) else n
        elif "S" in v:
            out[k] = v["S"]
        else:
            out[k] = json.dumps(v, sort_keys=True)
    return out


def scan_table(table):
    ddb = client("dynamodb")
    items = {}
    kwargs = {"TableName": table, "ConsistentRead": True}
    while True:
        resp = ddb.scan(**kwargs)
        for av in resp.get("Items", []):
            n = norm_ddb(av)
            items[(n.get("PK"), n.get("SK"))] = n
        if "LastEvaluatedKey" not in resp:
            break
        kwargs["ExclusiveStartKey"] = resp["LastEvaluatedKey"]
    return items


def reconcile_dynamodb(m, conn):
    ddb = client("dynamodb")
    table = m["projections"]["table_name"]
    for attempt in range(3):
        current = scan_table(table)          # scan first, then read PG (PG is append-only)
        settlements, events = load_pg(conn)
        want = desired_items(settlements, events)
        deleted = put = 0
        for key in current:
            if key not in want:
                ddb.delete_item(TableName=table, Key={"PK": {"S": key[0]}, "SK": {"S": key[1]}})
                deleted += 1
        for key, item in want.items():
            if current.get(key) != item:
                ddb.put_item(TableName=table, Item=to_ddb(item))
                put += 1
        log(f"dynamodb: pass {attempt + 1}: {len(want)} canonical items, {put} written, {deleted} deleted")
        if put == 0 and deleted == 0:
            break
    return settlements


def api_token(m, kind):
    c = m["auth"]["clients"][kind]
    data = f"grant_type=client_credentials&scope={c['scope']}".encode()
    basic = base64.b64encode(f"{c['client_id']}:{c['client_secret']}".encode()).decode()
    req = urllib.request.Request(m["auth"]["token_endpoint"], data=data, headers={
        "Content-Type": "application/x-www-form-urlencoded", "Authorization": "Basic " + basic})
    return json.load(urllib.request.urlopen(req, timeout=15))["access_token"]


def api_get(m, path, token):
    req = urllib.request.Request(m["service_url"] + path, headers={
        "Authorization": "Bearer " + token, "X-Correlation-Id": "deploy-reconcile"})
    try:
        r = urllib.request.urlopen(req, timeout=15)
        return r.status, dict(r.headers), r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read().decode()
    except Exception as e:
        return 0, {}, str(e)


def projection_json(s):
    updated = s["updated_at"].astimezone(timezone.utc)
    us = updated.microsecond
    frac = "" if us == 0 else (".%03d" % (us // 1000) if us % 1000 == 0 else ".%06d" % us)
    return json.dumps({
        "settlementId": s["settlement_id"], "accountId": s["account_id"], "reference": s["reference"],
        "debitParty": s["debit_party"], "creditParty": s["credit_party"], "status": s["status"],
        "clearingStage": s["clearing_stage"], "lastEntryId": s["last_entry_id"], "lastMemo": s["last_memo"],
        "version": s["version"], "entryCount": s["entry_count"],
        "updatedAt": updated.strftime("%Y-%m-%dT%H:%M:%S") + frac + "Z",
    }, separators=(",", ":"))


def reconcile_valkey(m, settlements):
    import redis
    r = redis.Redis(host=m["cache"]["endpoint"], port=int(m["cache"]["port"]), socket_timeout=10)
    want = {f"clearledger:settlement:{sid}" for sid in settlements}
    removed = 0
    for k in r.scan_iter(count=500):
        ks = k.decode(errors="replace")
        if ks not in want:
            r.delete(k)
            removed += 1
    # Refresh every canonical key through the API so the payload is byte-identical
    # to what the service itself caches from the DynamoDB projection.
    try:
        token = api_token(m, "read")
    except Exception as e:
        token = None
        log(f"valkey: could not obtain read token ({e}); writing cache directly")
    filled_api = filled_direct = 0
    for sid, s in settlements.items():
        key = f"clearledger:settlement:{sid}"
        r.delete(key)
        ok = False
        if token:
            for _ in range(3):
                status, _, body = api_get(m, f"/v1/settlements/{sid}", token)
                if status == 200:
                    try:
                        got = json.loads(body)
                    except Exception:
                        got = {}
                    ttl = r.ttl(key)
                    if got.get("version") == s["version"] and r.exists(key) and 0 < ttl <= 90:
                        ok = True
                        break
                time.sleep(0.5)
        if ok:
            filled_api += 1
        else:
            r.set(key, projection_json(s), ex=90)
            filled_direct += 1
    log(f"valkey: removed {removed} stray keys, populated {filled_api} via API, {filled_direct} directly")


BATCH_RE = re.compile(r"^ledger-audit/batch-(\d{8})-(\d{8})-([0-9a-f]{16})\.ndjson$")


def list_versions(s3, bucket):
    versions, markers = [], []
    kwargs = {"Bucket": bucket}
    while True:
        resp = s3.list_object_versions(**kwargs)
        versions.extend(resp.get("Versions", []))
        markers.extend(resp.get("DeleteMarkers", []))
        if not resp.get("IsTruncated"):
            break
        kwargs["KeyMarker"] = resp.get("NextKeyMarker")
        kwargs["VersionIdMarker"] = resp.get("NextVersionIdMarker")
    return versions, markers


def delete_versions(s3, bucket, objs):
    objs = [o for o in objs]
    for i in range(0, len(objs), 500):
        chunk = objs[i:i + 500]
        s3.delete_objects(Bucket=bucket, Delete={"Objects": chunk, "Quiet": True})


def abort_multipart(s3, bucket):
    try:
        resp = s3.list_multipart_uploads(Bucket=bucket)
        for u in resp.get("Uploads", []):
            s3.abort_multipart_upload(Bucket=bucket, Key=u["Key"], UploadId=u["UploadId"])
    except Exception as e:
        log(f"s3: multipart cleanup: {e}")


def reconcile_s3_once(m, conn):
    s3 = client("s3")
    bucket = m["audit"]["bucket_name"]
    abort_multipart(s3, bucket)
    with conn.transaction():
        rows = conn.execute(
            "SELECT seq, payload, published_at IS NOT NULL, archived_at IS NOT NULL FROM clearledger.outbox "
            "ORDER BY seq FOR UPDATE").fetchall()
        by_seq = {r[0]: r for r in rows}
        seqs = [r[0] for r in rows]

        versions, markers = list_versions(s3, bucket)
        purge = [{"Key": d["Key"], "VersionId": d["VersionId"]} for d in markers]
        latest = {}
        for v in versions:
            if v.get("IsLatest"):
                latest[v["Key"]] = v
            else:
                purge.append({"Key": v["Key"], "VersionId": v["VersionId"]})
        # Keys whose latest is a delete marker are treated as absent.
        marker_latest = {d["Key"] for d in markers if d.get("IsLatest")}
        for k in list(latest):
            if k in marker_latest:
                purge.append({"Key": k, "VersionId": latest.pop(k)["VersionId"]})

        candidates = []
        for key, v in latest.items():
            mt = BATCH_RE.match(key)
            valid = False
            if mt:
                first, last, digest = int(mt.group(1)), int(mt.group(2)), mt.group(3)
                try:
                    body = s3.get_object(Bucket=bucket, Key=key, VersionId=v["VersionId"])["Body"].read()
                except Exception:
                    body = None
                if body is not None and first <= last and hashlib.sha256(body).hexdigest()[:16] == digest:
                    expect = [s for s in seqs if first <= s <= last]
                    if expect and expect[0] == first and expect[-1] == last and all(by_seq[s][2] for s in expect):
                        try:
                            text = body.decode("utf-8")
                            lines = text.split("\n")
                            if lines and lines[-1] == "":
                                lines = lines[:-1]
                            parsed = [json.loads(l) for l in lines]
                            valid = len(parsed) == len(expect) and all(
                                parsed[i] == by_seq[s][1] for i, s in enumerate(expect))
                        except Exception:
                            valid = False
            if valid:
                candidates.append((first, last, key, v["VersionId"]))
            else:
                purge.append({"Key": key, "VersionId": v["VersionId"]})

        # Keep non-overlapping batches (earliest first).
        candidates.sort()
        covered = set()
        kept = []
        last_end = -1
        for first, last, key, vid in candidates:
            if first <= last_end:
                purge.append({"Key": key, "VersionId": vid})
                continue
            kept.append((first, last, key))
            last_end = last
            covered.update(s for s in seqs if first <= s <= last)

        if purge:
            delete_versions(s3, bucket, purge)

        # Build new batches for uncovered published rows (contiguous runs, <=100 rows).
        runs, cur = [], []
        for s in seqs:
            published = by_seq[s][2]
            if s in covered or not published:
                if cur:
                    runs.append(cur)
                    cur = []
                continue
            cur.append(s)
            if len(cur) >= 100:
                runs.append(cur)
                cur = []
        if cur:
            runs.append(cur)
        written = 0
        for run in runs:
            body = "".join(canonical_envelope(by_seq[s][1]) + "\n" for s in run).encode("utf-8")
            key = "ledger-audit/batch-%08d-%08d-%s.ndjson" % (run[0], run[-1], hashlib.sha256(body).hexdigest()[:16])
            s3.put_object(Bucket=bucket, Key=key, Body=body, ContentType="application/x-ndjson")
            covered.update(run)
            written += 1

        if covered:
            conn.execute(
                "UPDATE clearledger.outbox SET archived_at = GREATEST(NOW(), published_at) "
                "WHERE archived_at IS NULL AND published_at IS NOT NULL AND seq = ANY(%s)", (sorted(covered),))
    log(f"s3: kept {len(kept)} batches, purged {len(purge)} versions/markers, wrote {written} new batches")
    return len(purge) == 0 and written == 0


def purge_noncurrent(m):
    s3 = client("s3")
    bucket = m["audit"]["bucket_name"]
    versions, markers = list_versions(s3, bucket)
    purge = [{"Key": d["Key"], "VersionId": d["VersionId"]} for d in markers]
    purge += [{"Key": v["Key"], "VersionId": v["VersionId"]} for v in versions if not v.get("IsLatest")]
    if purge:
        delete_versions(s3, bucket, purge)


def wait_health(m, timeout=300):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            r = urllib.request.urlopen(m["service_url"] + "/health/ready", timeout=5)
            if r.status == 200:
                return True
        except Exception:
            pass
        time.sleep(3)
    return False


def cmd_data(manifest_path):
    m = json.load(open(manifest_path))
    conn = pg_connect(m)
    drain_outbox(m, conn)
    wait_queue_drained(m)
    for i in range(3):
        if reconcile_s3_once(m, conn):
            break
    purge_noncurrent(m)
    settlements = reconcile_dynamodb(m, conn)
    wait_queue_drained(m, timeout=30)
    settlements = reconcile_dynamodb(m, conn)
    if not wait_health(m, 120):
        log("health: service not ready before cache population")
    reconcile_valkey(m, settlements)
    conn.close()


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: ops.py pre|data <manifest>")
    if sys.argv[1] == "pre":
        cmd_pre()
    elif sys.argv[1] == "data":
        cmd_data(sys.argv[2])
    else:
        sys.exit("unknown command")
CLEARLEDGER_PY

# ---------------------------------------------------------------------------
# 1. Pre-apply control-plane repair (KMS state/rotation/tags, IAM drift)
# ---------------------------------------------------------------------------
log "repairing out-of-band KMS / IAM drift"
python3 "${WORK}/ops.py" pre || log "pre-apply repair reported errors (continuing)"

# ---------------------------------------------------------------------------
# 2. Terraform apply (local state in infra/terraform.tfstate)
# ---------------------------------------------------------------------------
cd "${INFRA_DIR}"
log "terraform init"
"${TF}" init -input=false -no-color -upgrade=false >"${WORK}/init.log" 2>&1 || { cat "${WORK}/init.log"; die "terraform init failed"; }

apply_ok=0
for attempt in 1 2 3; do
  log "terraform apply (attempt ${attempt})"
  if "${TF}" apply -input=false -auto-approve -no-color -refresh=true \
       -var "config_path=${CONFIG_PATH}" >"${WORK}/apply.log" 2>&1; then
    apply_ok=1
    grep -E '^(Apply complete|Plan:)' "${WORK}/apply.log" || true
    break
  fi
  tail -n 40 "${WORK}/apply.log"
  log "apply failed; re-running drift repair before retry"
  python3 "${WORK}/ops.py" pre || true
  sleep 5
done
[[ "${apply_ok}" == 1 ]] || die "terraform apply failed"

# ---------------------------------------------------------------------------
# 3. Manifest
# ---------------------------------------------------------------------------
"${TF}" output -no-color -json manifest > "${WORK}/manifest.json"
jq -e '.service_url and .database.endpoint' "${WORK}/manifest.json" >/dev/null || die "manifest output incomplete"
cp "${WORK}/manifest.json" "${MANIFEST_PATH}"
chmod 600 "${MANIFEST_PATH}" || true
log "manifest written to ${MANIFEST_PATH}"

DB_HOST="$(jq -r '.database.endpoint' "${MANIFEST_PATH}")"
DB_PORT="$(jq -r '.database.port' "${MANIFEST_PATH}")"
DB_NAME="$(jq -r '.database.db_name' "${MANIFEST_PATH}")"
DB_USER="$(jq -r '.database.username' "${MANIFEST_PATH}")"
SERVICE_URL="$(jq -r '.service_url' "${MANIFEST_PATH}")"

# ---------------------------------------------------------------------------
# 4. PostgreSQL schema, constraints, triggers and indexes
# ---------------------------------------------------------------------------
export PGPASSWORD="${DB_PASSWORD}"
export PGCONNECT_TIMEOUT=10
log "waiting for PostgreSQL at ${DB_HOST}:${DB_PORT}"
for i in $(seq 1 90); do
  if psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -Atqc 'SELECT 1' >/dev/null 2>&1; then break; fi
  [[ "$i" == 90 ]] && die "PostgreSQL not reachable"
  sleep 2
done

schema_ok=0
for attempt in 1 2 3 4 5; do
  if psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" \
       -v ON_ERROR_STOP=1 -X -q -1 -o /dev/null -f "${WORK}/schema.sql" >"${WORK}/schema.log" 2>&1; then
    schema_ok=1
    break
  fi
  tail -n 20 "${WORK}/schema.log"
  log "schema migration attempt ${attempt} failed; retrying"
  sleep 3
done
[[ "${schema_ok}" == 1 ]] || die "schema migration failed"
log "schema converged: $(psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -Atqc \
  "SELECT count(*) || ' indexes, ' || (SELECT count(*) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='clearledger' AND NOT t.tgisinternal AND t.tgenabled='O') || ' enabled triggers' FROM pg_indexes WHERE schemaname='clearledger' AND indexname LIKE 'idx_clearledger_%'")"

# ---------------------------------------------------------------------------
# 5. Wait for the API to report ready through the ALB
# ---------------------------------------------------------------------------
wait_ready() {
  local deadline=$(( $(date +%s) + $1 ))
  while (( $(date +%s) < deadline )); do
    code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "${SERVICE_URL}/health/ready" || true)"
    [[ "${code}" == "200" ]] && return 0
    sleep 3
  done
  return 1
}
log "waiting for ${SERVICE_URL}/health/ready"
wait_ready 360 || die "service did not become ready"
log "service ready"

# ---------------------------------------------------------------------------
# 6. Data-plane convergence (outbox -> SQS, DynamoDB, S3 archive, Valkey)
# ---------------------------------------------------------------------------
dp_ok=0
for attempt in 1 2 3; do
  if python3 "${WORK}/ops.py" data "${MANIFEST_PATH}"; then dp_ok=1; break; fi
  log "data-plane convergence attempt ${attempt} failed; retrying"
  sleep 5
done
[[ "${dp_ok}" == 1 ]] || die "data-plane convergence failed"

wait_ready 120 || die "service not ready after convergence"
log "ClearLedger ${PREFIX} deployed: ${SERVICE_URL}"
exit 0
