#!/usr/bin/env bash
# ClearLedger deployment: Terraform/OpenTofu apply, PostgreSQL schema, manifest, and data-plane convergence.
# Safe to re-run at any time (repairs control-plane drift, preserves RDS / DynamoDB / S3 data).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA="$HERE/infra"
CONFIG_FILE="${CONFIG_FILE:-/workspace/config/config.json}"
MANIFEST="$HERE/manifest.json"
SCHEMA="$HERE/.schema.sql"
HELPER="$HERE/.converge.py"
export CONFIG_FILE MANIFEST_FILE="$MANIFEST"

START=$(date +%s)
log() { echo "[deploy $(date +%H:%M:%S) +$(( $(date +%s) - START ))s] $*"; }

# ------------------------------------------------------------------ inputs
for bin in jq psql python3; do command -v "$bin" >/dev/null || { echo "missing $bin" >&2; exit 1; }; done
TF="$(command -v terraform || command -v tofu || true)"
[ -n "$TF" ] || { echo "neither terraform nor tofu found" >&2; exit 1; }

PREFIX="$(jq -r .resource_prefix "$CONFIG_FILE")"
REGION="$(jq -r .region "$CONFIG_FILE")"
ENDPOINT="$(jq -r .aws_endpoint_url "$CONFIG_FILE")"
DB_NAME="$(jq -r .db_name "$CONFIG_FILE")"
DB_USER="$(jq -r .db_username "$CONFIG_FILE")"
DB_PASS="$(jq -r .db_password "$CONFIG_FILE")"
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION" AWS_ENDPOINT_URL="$ENDPOINT"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_PAGER="" TF_IN_AUTOMATION=1 TF_INPUT=0
export TF_VAR_config_file="$CONFIG_FILE"
log "prefix=$PREFIX region=$REGION endpoint=$ENDPOINT engine=$(basename "$TF")"

# ------------------------------------------------------------------ embedded helpers
cat > "$SCHEMA" <<'CLEARLEDGER_SCHEMA_EOF'
-- ClearLedger PostgreSQL schema: idempotent (safe to re-run under live traffic).
\set ON_ERROR_STOP on
\o /dev/null
SET lock_timeout = '15s';
SET client_min_messages = warning;
BEGIN;

CREATE SCHEMA IF NOT EXISTS clearledger;

-- ---------------------------------------------------------------- helpers
CREATE OR REPLACE FUNCTION clearledger.is_canonical(t text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $f$
  SELECT COALESCE(t IS NOT NULL AND t = btrim(t) AND t !~ '^\s' AND t !~ '\s$', false)
$f$;

CREATE OR REPLACE FUNCTION clearledger.is_uuid(t text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $f$
  SELECT COALESCE(t ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', false)
$f$;

CREATE OR REPLACE FUNCTION clearledger.str_ok(t text, minlen int, maxlen int) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $f$
  SELECT COALESCE(clearledger.is_canonical(t) AND char_length(t) BETWEEN minlen AND maxlen, false)
$f$;

CREATE OR REPLACE FUNCTION clearledger.is_status(t text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $f$
  SELECT COALESCE(t IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED'), false)
$f$;

CREATE OR REPLACE FUNCTION clearledger.status_rank(s text) RETURNS integer
LANGUAGE sql IMMUTABLE AS $f$
  SELECT CASE s WHEN 'INITIATED' THEN 0 WHEN 'VALIDATED' THEN 1 WHEN 'RESERVED' THEN 2
                WHEN 'CLEARED' THEN 3 WHEN 'SETTLED' THEN 4 WHEN 'RECONCILED' THEN 5 END
$f$;

CREATE OR REPLACE FUNCTION clearledger.status_transition_ok(old_s text, new_s text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $f$
  SELECT COALESCE(CASE
    WHEN old_s = 'RECONCILED' THEN false
    WHEN old_s = 'DISPUTED' THEN new_s IN ('DISPUTED', 'RECONCILED')
    WHEN clearledger.status_rank(old_s) IS NULL THEN false
    WHEN new_s = 'DISPUTED' THEN true
    WHEN clearledger.status_rank(new_s) IS NULL THEN false
    ELSE clearledger.status_rank(new_s) >= clearledger.status_rank(old_s)
  END, false)
$f$;

CREATE OR REPLACE FUNCTION clearledger.safe_ts(t text) RETURNS timestamptz
LANGUAGE plpgsql STABLE AS $f$
BEGIN
  IF t IS NULL OR t !~ '^\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}:\d{2}(\.\d+)?([Zz]|[+-]\d{2}:\d{2})$' THEN
    RETURN NULL;
  END IF;
  RETURN t::timestamptz;
EXCEPTION WHEN others THEN
  RETURN NULL;
END
$f$;

CREATE OR REPLACE FUNCTION clearledger.safe_uuid(t text) RETURNS uuid
LANGUAGE sql IMMUTABLE AS $f$
  SELECT CASE WHEN clearledger.is_uuid(t) THEN t::uuid END
$f$;

-- Strict structural validation of ClearLedgerDomainEventEnvelope (events.schema.json).
CREATE OR REPLACE FUNCTION clearledger.envelope_ok(p jsonb) RETURNS boolean
LANGUAGE plpgsql STABLE AS $f$
DECLARE
  k text; d jsonb; v integer; et text; kind text; st text; stage text; debit text;
BEGIN
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN RETURN false; END IF;
  FOR k IN SELECT jsonb_object_keys(p) LOOP
    IF k <> ALL (ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId',
                       'aggregateVersion','occurredAt','correlationId','idempotencyKey','data']) THEN
      RETURN false;
    END IF;
  END LOOP;
  IF NOT (p ?& ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId',
                     'aggregateVersion','occurredAt','correlationId','idempotencyKey','data']) THEN
    RETURN false;
  END IF;
  IF jsonb_typeof(p->'schemaVersion') <> 'string' OR p->>'schemaVersion' <> '1.0' THEN RETURN false; END IF;
  IF jsonb_typeof(p->'eventId') <> 'string' OR NOT clearledger.is_uuid(p->>'eventId') THEN RETURN false; END IF;
  IF jsonb_typeof(p->'aggregateId') <> 'string' OR NOT clearledger.is_uuid(p->>'aggregateId') THEN RETURN false; END IF;
  IF jsonb_typeof(p->'eventType') <> 'string' OR p->>'eventType' NOT IN ('SettlementInitiated','LedgerEntryRecorded') THEN RETURN false; END IF;
  IF jsonb_typeof(p->'aggregateType') <> 'string' OR p->>'aggregateType' <> 'settlement' THEN RETURN false; END IF;
  IF jsonb_typeof(p->'aggregateVersion') <> 'number' OR (p->>'aggregateVersion') !~ '^[1-9][0-9]{0,8}$' THEN RETURN false; END IF;
  IF jsonb_typeof(p->'occurredAt') <> 'string' OR clearledger.safe_ts(p->>'occurredAt') IS NULL THEN RETURN false; END IF;
  IF jsonb_typeof(p->'correlationId') <> 'string' OR NOT clearledger.str_ok(p->>'correlationId', 4, 128) THEN RETURN false; END IF;
  IF jsonb_typeof(p->'idempotencyKey') <> 'string' OR NOT clearledger.str_ok(p->>'idempotencyKey', 8, 128) THEN RETURN false; END IF;

  v := (p->>'aggregateVersion')::integer;
  et := p->>'eventType';
  d := p->'data';
  IF jsonb_typeof(d) <> 'object' THEN RETURN false; END IF;
  FOR k IN SELECT jsonb_object_keys(d) LOOP
    IF k <> ALL (ARRAY['kind','accountId','reference','debitParty','creditParty','entryId','status','clearingStage','memo']) THEN
      RETURN false;
    END IF;
  END LOOP;
  IF NOT (d ?& ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage']) THEN RETURN false; END IF;
  FOR k IN SELECT unnest(ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage']) LOOP
    IF jsonb_typeof(d->k) <> 'string' THEN RETURN false; END IF;
  END LOOP;
  kind := d->>'kind'; st := d->>'status'; stage := d->>'clearingStage'; debit := d->>'debitParty';
  IF kind NOT IN ('settlementInitiated','ledgerEntryRecorded') THEN RETURN false; END IF;
  IF NOT clearledger.str_ok(d->>'accountId', 3, 64) THEN RETURN false; END IF;
  IF NOT clearledger.str_ok(d->>'reference', 3, 64) THEN RETURN false; END IF;
  IF NOT clearledger.str_ok(debit, 2, 64) THEN RETURN false; END IF;
  IF NOT clearledger.str_ok(d->>'creditParty', 2, 64) THEN RETURN false; END IF;
  IF debit = d->>'creditParty' THEN RETURN false; END IF;
  IF NOT clearledger.is_status(st) THEN RETURN false; END IF;
  IF d ? 'memo' AND jsonb_typeof(d->'memo') <> 'null' THEN
    IF jsonb_typeof(d->'memo') <> 'string' OR NOT clearledger.str_ok(d->>'memo', 1, 256) THEN RETURN false; END IF;
  END IF;
  IF d ? 'entryId' AND jsonb_typeof(d->'entryId') <> 'null' THEN
    IF jsonb_typeof(d->'entryId') <> 'string' OR NOT clearledger.is_uuid(d->>'entryId') THEN RETURN false; END IF;
  END IF;

  IF v = 1 THEN
    IF et <> 'SettlementInitiated' OR kind <> 'settlementInitiated' OR st <> 'INITIATED' THEN RETURN false; END IF;
    IF d->>'entryId' IS NOT NULL THEN RETURN false; END IF;
    IF stage <> 'INITIATED@' || debit THEN RETURN false; END IF;
    IF d->>'memo' IS DISTINCT FROM 'Settlement initiated' THEN RETURN false; END IF;
  ELSE
    IF et <> 'LedgerEntryRecorded' OR kind <> 'ledgerEntryRecorded' OR st = 'INITIATED' THEN RETURN false; END IF;
    IF d->>'entryId' IS NULL THEN RETURN false; END IF;
    IF NOT clearledger.str_ok(stage, 2, 64) THEN RETURN false; END IF;
  END IF;
  RETURN true;
END
$f$;

-- Column <-> envelope equality (shared by events and outbox).
CREATE OR REPLACE FUNCTION clearledger.envelope_matches(
  p jsonb, c_event_id uuid, c_settlement_id uuid, c_version integer, c_correlation text) RETURNS boolean
LANGUAGE sql STABLE AS $f$
  SELECT COALESCE(
    clearledger.safe_uuid(p->>'eventId') = c_event_id
    AND clearledger.safe_uuid(p->>'aggregateId') = c_settlement_id
    AND CASE WHEN (p->>'aggregateVersion') ~ '^[0-9]{1,9}$' THEN (p->>'aggregateVersion')::integer END = c_version
    AND p->>'correlationId' = c_correlation, false)
$f$;

CREATE OR REPLACE FUNCTION clearledger.event_matches(
  p jsonb, c_event_id uuid, c_settlement_id uuid, c_version integer, c_type text,
  c_correlation text, c_idem text, c_occurred timestamptz) RETURNS boolean
LANGUAGE sql STABLE AS $f$
  SELECT COALESCE(
    clearledger.envelope_matches(p, c_event_id, c_settlement_id, c_version, c_correlation)
    AND p->>'eventType' = c_type
    AND p->>'idempotencyKey' = c_idem
    AND clearledger.safe_ts(p->>'occurredAt') = c_occurred, false)
$f$;

CREATE OR REPLACE FUNCTION clearledger.write_response_ok(b jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $f$
DECLARE k text;
BEGIN
  IF b IS NULL OR jsonb_typeof(b) <> 'object' THEN RETURN false; END IF;
  FOR k IN SELECT jsonb_object_keys(b) LOOP
    IF k <> ALL (ARRAY['settlementId','eventId','version','accepted','idempotentReplay']) THEN RETURN false; END IF;
  END LOOP;
  IF NOT (b ?& ARRAY['settlementId','eventId','version','accepted','idempotentReplay']) THEN RETURN false; END IF;
  RETURN COALESCE(
    jsonb_typeof(b->'settlementId') = 'string' AND clearledger.is_uuid(b->>'settlementId')
    AND jsonb_typeof(b->'eventId') = 'string' AND clearledger.is_uuid(b->>'eventId')
    AND jsonb_typeof(b->'version') = 'number' AND (b->>'version') ~ '^[1-9][0-9]{0,8}$'
    AND b->'accepted' = 'true'::jsonb
    AND b->'idempotentReplay' = 'false'::jsonb, false);
END
$f$;

CREATE OR REPLACE FUNCTION clearledger.idem_row_ok(scope text, code integer, b jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $f$
DECLARE ver integer;
BEGIN
  IF scope IS NULL OR code IS NULL OR NOT clearledger.write_response_ok(b) THEN RETURN false; END IF;
  ver := (b->>'version')::integer;
  IF scope ~* '^create:[0-9a-f-]{36}$' THEN
    RETURN lower(substr(scope, 8)) = lower(b->>'settlementId') AND code = 201 AND ver = 1;
  ELSIF scope ~* '^entry:[0-9a-f-]{36}$' THEN
    RETURN lower(substr(scope, 7)) = lower(b->>'settlementId') AND code = 202 AND ver >= 2;
  END IF;
  RETURN false;
END
$f$;

-- ---------------------------------------------------------------- tables
CREATE TABLE IF NOT EXISTS clearledger.settlements (
  settlement_id UUID NOT NULL PRIMARY KEY,
  account_id    TEXT NOT NULL,
  reference     TEXT NOT NULL,
  debit_party   TEXT NOT NULL,
  credit_party  TEXT NOT NULL,
  current_status TEXT NOT NULL,
  current_stage  TEXT NOT NULL,
  last_entry_id UUID NULL,
  last_memo     TEXT NULL,
  version       INTEGER NOT NULL,
  entry_count   INTEGER NOT NULL DEFAULT 0,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS clearledger.events (
  seq            BIGSERIAL NOT NULL PRIMARY KEY,
  event_id       UUID NOT NULL,
  settlement_id  UUID NOT NULL,
  aggregate_version INTEGER NOT NULL,
  event_type     TEXT NOT NULL,
  correlation_id TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  occurred_at    TIMESTAMPTZ NOT NULL,
  payload        JSONB NOT NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS clearledger.outbox (
  seq            BIGSERIAL NOT NULL PRIMARY KEY,
  event_id       UUID NOT NULL,
  settlement_id  UUID NOT NULL,
  aggregate_version INTEGER NOT NULL,
  correlation_id TEXT NOT NULL,
  payload        JSONB NOT NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  published_at   TIMESTAMPTZ NULL,
  archived_at    TIMESTAMPTZ NULL,
  attempts       INTEGER NOT NULL DEFAULT 0,
  last_error     TEXT NULL
);

CREATE TABLE IF NOT EXISTS clearledger.idempotency_keys (
  scope           TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  request_hash    TEXT NOT NULL,
  status_code     INTEGER NOT NULL,
  response_body   JSONB NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (scope, idempotency_key)
);

-- ---------------------------------------------------------------- constraints (added only when missing)
CREATE FUNCTION pg_temp.add_con(tbl regclass, cname text, def text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = tbl AND conname = cname) THEN
    EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I %s', tbl, cname, def);
  END IF;
END
$f$;

-- settlements
SELECT pg_temp.add_con('clearledger.settlements', 'ck_settlements_canonical', $d$CHECK (
  clearledger.str_ok(account_id, 3, 64) AND clearledger.str_ok(reference, 3, 64)
  AND clearledger.str_ok(debit_party, 2, 64) AND clearledger.str_ok(credit_party, 2, 64)
  AND clearledger.is_canonical(current_stage)
  AND (last_memo IS NULL OR clearledger.str_ok(last_memo, 1, 256))
  AND debit_party <> credit_party)$d$);
SELECT pg_temp.add_con('clearledger.settlements', 'ck_settlements_status', $d$CHECK (clearledger.is_status(current_status))$d$);
SELECT pg_temp.add_con('clearledger.settlements', 'ck_settlements_version', $d$CHECK (version >= 1 AND entry_count >= 0 AND entry_count = version - 1)$d$);
SELECT pg_temp.add_con('clearledger.settlements', 'ck_settlements_lifecycle', $d$CHECK (
  CASE WHEN version = 1 THEN
         entry_count = 0 AND current_status = 'INITIATED'
         AND current_stage = 'INITIATED@' || debit_party
         AND last_entry_id IS NULL AND last_memo = 'Settlement initiated'
         AND updated_at = created_at
       ELSE
         entry_count = version - 1 AND current_status <> 'INITIATED'
         AND char_length(current_stage) BETWEEN 2 AND 64
         AND last_entry_id IS NOT NULL AND updated_at > created_at
  END)$d$);

-- events
SELECT pg_temp.add_con('clearledger.events', 'uq_events_event_id', 'UNIQUE (event_id)');
SELECT pg_temp.add_con('clearledger.events', 'uq_events_settlement_version', 'UNIQUE (settlement_id, aggregate_version)');
SELECT pg_temp.add_con('clearledger.events', 'uq_events_settlement_idempotency', 'UNIQUE (settlement_id, idempotency_key)');
SELECT pg_temp.add_con('clearledger.events', 'fk_events_settlement',
  'FOREIGN KEY (settlement_id) REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE');
SELECT pg_temp.add_con('clearledger.events', 'ck_events_columns', $d$CHECK (
  aggregate_version >= 1 AND event_type IN ('SettlementInitiated', 'LedgerEntryRecorded')
  AND clearledger.str_ok(correlation_id, 4, 128) AND clearledger.str_ok(idempotency_key, 8, 128))$d$);
SELECT pg_temp.add_con('clearledger.events', 'ck_events_envelope', $d$CHECK (clearledger.envelope_ok(payload))$d$);
SELECT pg_temp.add_con('clearledger.events', 'ck_events_envelope_columns', $d$CHECK (
  clearledger.event_matches(payload, event_id, settlement_id, aggregate_version, event_type,
                            correlation_id, idempotency_key, occurred_at))$d$);

-- outbox
SELECT pg_temp.add_con('clearledger.outbox', 'uq_outbox_event_id', 'UNIQUE (event_id)');
SELECT pg_temp.add_con('clearledger.outbox', 'uq_outbox_settlement_version', 'UNIQUE (settlement_id, aggregate_version)');
SELECT pg_temp.add_con('clearledger.outbox', 'fk_outbox_event',
  'FOREIGN KEY (event_id) REFERENCES clearledger.events(event_id) ON DELETE CASCADE');
SELECT pg_temp.add_con('clearledger.outbox', 'fk_outbox_settlement',
  'FOREIGN KEY (settlement_id) REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE');
SELECT pg_temp.add_con('clearledger.outbox', 'fk_outbox_event_version',
  'FOREIGN KEY (settlement_id, aggregate_version) REFERENCES clearledger.events(settlement_id, aggregate_version) ON DELETE CASCADE');
SELECT pg_temp.add_con('clearledger.outbox', 'ck_outbox_columns', $d$CHECK (
  aggregate_version >= 1 AND clearledger.str_ok(correlation_id, 4, 128))$d$);
SELECT pg_temp.add_con('clearledger.outbox', 'ck_outbox_envelope', $d$CHECK (
  clearledger.envelope_ok(payload)
  AND clearledger.envelope_matches(payload, event_id, settlement_id, aggregate_version, correlation_id))$d$);
SELECT pg_temp.add_con('clearledger.outbox', 'ck_outbox_attempts', $d$CHECK (
  attempts >= 0 AND (attempts > 0 OR (published_at IS NULL AND last_error IS NULL)))$d$);
SELECT pg_temp.add_con('clearledger.outbox', 'ck_outbox_published', $d$CHECK (
  published_at IS NULL OR (attempts >= 1 AND last_error IS NULL AND published_at >= created_at))$d$);
SELECT pg_temp.add_con('clearledger.outbox', 'ck_outbox_last_error', $d$CHECK (
  last_error IS NULL OR (published_at IS NULL AND attempts >= 1
                         AND length(btrim(last_error)) > 0 AND last_error = btrim(last_error)))$d$);
SELECT pg_temp.add_con('clearledger.outbox', 'ck_outbox_archived', $d$CHECK (
  archived_at IS NULL OR (published_at IS NOT NULL AND archived_at >= published_at))$d$);

-- idempotency_keys
SELECT pg_temp.add_con('clearledger.idempotency_keys', 'ck_idem_scope', $d$CHECK (
  scope ~* '^(create|entry):[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')$d$);
SELECT pg_temp.add_con('clearledger.idempotency_keys', 'ck_idem_key', $d$CHECK (clearledger.str_ok(idempotency_key, 8, 128))$d$);
SELECT pg_temp.add_con('clearledger.idempotency_keys', 'ck_idem_hash', $d$CHECK (request_hash ~ '^[0-9a-f]{64}$')$d$);
SELECT pg_temp.add_con('clearledger.idempotency_keys', 'ck_idem_response', $d$CHECK (
  clearledger.idem_row_ok(scope, status_code, response_body))$d$);

-- ---------------------------------------------------------------- trigger functions
CREATE OR REPLACE FUNCTION clearledger.trg_settlements_guard() RETURNS trigger
LANGUAGE plpgsql AS $f$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'clearledger.settlements is append-only: DELETE rejected';
  ELSIF TG_OP = 'INSERT' THEN
    IF NEW.version <> 1 THEN
      RAISE EXCEPTION 'settlement % must be created at version 1 (got %)', NEW.settlement_id, NEW.version;
    END IF;
    RETURN NEW;
  END IF;
  -- UPDATE
  IF OLD.current_status = 'RECONCILED' THEN
    RAISE EXCEPTION 'settlement % is RECONCILED and terminal', OLD.settlement_id;
  END IF;
  IF NEW.settlement_id IS DISTINCT FROM OLD.settlement_id OR NEW.account_id IS DISTINCT FROM OLD.account_id
     OR NEW.reference IS DISTINCT FROM OLD.reference OR NEW.debit_party IS DISTINCT FROM OLD.debit_party
     OR NEW.credit_party IS DISTINCT FROM OLD.credit_party OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'settlement % header columns are immutable', OLD.settlement_id;
  END IF;
  IF NEW.version <> OLD.version + 1 OR NEW.entry_count <> OLD.entry_count + 1 THEN
    RAISE EXCEPTION 'settlement % must advance version and entry_count by exactly 1', OLD.settlement_id;
  END IF;
  IF NEW.last_entry_id IS NULL OR NEW.last_entry_id IS NOT DISTINCT FROM OLD.last_entry_id THEN
    RAISE EXCEPTION 'settlement % update requires a new last_entry_id', OLD.settlement_id;
  END IF;
  IF NEW.updated_at <= OLD.updated_at THEN
    RAISE EXCEPTION 'settlement % updated_at must strictly increase', OLD.settlement_id;
  END IF;
  IF NOT clearledger.status_transition_ok(OLD.current_status, NEW.current_status) THEN
    RAISE EXCEPTION 'settlement % illegal status transition % -> %', OLD.settlement_id, OLD.current_status, NEW.current_status;
  END IF;
  RETURN NEW;
END
$f$;

CREATE OR REPLACE FUNCTION clearledger.trg_events_insert_guard() RETURNS trigger
LANGUAGE plpgsql AS $f$
DECLARE
  s clearledger.settlements%ROWTYPE;
  d jsonb := NEW.payload->'data';
  cnt bigint; mx integer;
  prev_at timestamptz; prev_status text;
BEGIN
  SELECT * INTO s FROM clearledger.settlements WHERE settlement_id = NEW.settlement_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'event % references unknown settlement %', NEW.event_id, NEW.settlement_id;
  END IF;

  SELECT count(*), COALESCE(max(aggregate_version), 0) INTO cnt, mx
    FROM clearledger.events WHERE settlement_id = NEW.settlement_id;
  IF NEW.aggregate_version <> mx + 1 OR cnt <> mx THEN
    RAISE EXCEPTION 'event version % for settlement % is not contiguous (latest %)', NEW.aggregate_version, NEW.settlement_id, mx;
  END IF;

  IF d->>'entryId' IS NOT NULL AND EXISTS (
       SELECT 1 FROM clearledger.events e
        WHERE e.settlement_id = NEW.settlement_id AND e.event_type = 'LedgerEntryRecorded'
          AND e.payload->'data'->>'entryId' = d->>'entryId') THEN
    RAISE EXCEPTION 'entryId % already recorded for settlement %', d->>'entryId', NEW.settlement_id;
  END IF;

  IF s.account_id IS DISTINCT FROM d->>'accountId' OR s.reference IS DISTINCT FROM d->>'reference'
     OR s.debit_party IS DISTINCT FROM d->>'debitParty' OR s.credit_party IS DISTINCT FROM d->>'creditParty'
     OR s.current_status IS DISTINCT FROM d->>'status' OR s.current_stage IS DISTINCT FROM d->>'clearingStage'
     OR s.last_entry_id IS DISTINCT FROM clearledger.safe_uuid(d->>'entryId')
     OR s.last_memo IS DISTINCT FROM d->>'memo' OR s.version <> NEW.aggregate_version
     OR s.updated_at <> NEW.occurred_at THEN
    RAISE EXCEPTION 'event % does not match settlement % state', NEW.event_id, NEW.settlement_id;
  END IF;

  IF NEW.aggregate_version = 1 THEN
    IF s.created_at <> NEW.occurred_at THEN
      RAISE EXCEPTION 'initial event % must occur at settlement creation time', NEW.event_id;
    END IF;
  ELSE
    SELECT e.occurred_at, e.payload->'data'->>'status' INTO prev_at, prev_status
      FROM clearledger.events e
     WHERE e.settlement_id = NEW.settlement_id AND e.aggregate_version = NEW.aggregate_version - 1;
    IF prev_at IS NULL OR NEW.occurred_at <= prev_at THEN
      RAISE EXCEPTION 'event % occurred_at must be after the preceding event', NEW.event_id;
    END IF;
    IF NOT clearledger.status_transition_ok(prev_status, d->>'status') THEN
      RAISE EXCEPTION 'event % illegal status transition % -> %', NEW.event_id, prev_status, d->>'status';
    END IF;
  END IF;
  RETURN NEW;
END
$f$;

CREATE OR REPLACE FUNCTION clearledger.trg_append_only() RETURNS trigger
LANGUAGE plpgsql AS $f$
BEGIN
  RAISE EXCEPTION '%.% is append-only: % rejected', TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_OP;
END
$f$;

CREATE OR REPLACE FUNCTION clearledger.trg_outbox_insert_guard() RETURNS trigger
LANGUAGE plpgsql AS $f$
DECLARE
  e clearledger.events%ROWTYPE;
  cnt bigint; mx integer;
BEGIN
  SELECT * INTO e FROM clearledger.events WHERE event_id = NEW.event_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'outbox row references unknown event %', NEW.event_id;
  END IF;
  IF e.settlement_id <> NEW.settlement_id OR e.aggregate_version <> NEW.aggregate_version
     OR e.correlation_id <> NEW.correlation_id OR e.payload IS DISTINCT FROM NEW.payload THEN
    RAISE EXCEPTION 'outbox row for event % does not mirror the event', NEW.event_id;
  END IF;
  SELECT count(*), COALESCE(max(aggregate_version), 0) INTO cnt, mx
    FROM clearledger.outbox WHERE settlement_id = NEW.settlement_id;
  IF NEW.aggregate_version <> mx + 1 OR cnt <> mx THEN
    RAISE EXCEPTION 'outbox version % for settlement % is not contiguous (latest %)', NEW.aggregate_version, NEW.settlement_id, mx;
  END IF;
  RETURN NEW;
END
$f$;

CREATE OR REPLACE FUNCTION clearledger.trg_outbox_change_guard() RETURNS trigger
LANGUAGE plpgsql AS $f$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'clearledger.outbox rows cannot be deleted';
  END IF;
  IF NEW.seq <> OLD.seq OR NEW.event_id <> OLD.event_id OR NEW.settlement_id <> OLD.settlement_id
     OR NEW.aggregate_version <> OLD.aggregate_version OR NEW.correlation_id <> OLD.correlation_id
     OR NEW.payload IS DISTINCT FROM OLD.payload OR NEW.created_at <> OLD.created_at THEN
    RAISE EXCEPTION 'outbox envelope columns of event % are immutable', OLD.event_id;
  END IF;
  IF NEW.attempts < OLD.attempts THEN
    RAISE EXCEPTION 'outbox attempts of event % cannot decrease', OLD.event_id;
  END IF;
  IF OLD.published_at IS NULL THEN
    IF NEW.published_at IS NOT NULL AND (NEW.attempts <= OLD.attempts OR NEW.archived_at IS NOT NULL) THEN
      RAISE EXCEPTION 'publishing outbox event % requires attempts to increment and archived_at to be NULL', OLD.event_id;
    END IF;
  ELSIF NEW.published_at IS NULL THEN
    -- operational replay: reset published_at and archived_at together
    IF NEW.archived_at IS NOT NULL OR NEW.attempts <> OLD.attempts OR NEW.last_error IS DISTINCT FROM OLD.last_error THEN
      RAISE EXCEPTION 'outbox replay reset of event % may only clear published_at and archived_at', OLD.event_id;
    END IF;
  ELSE
    IF NEW.published_at <> OLD.published_at OR NEW.attempts <> OLD.attempts
       OR NEW.last_error IS DISTINCT FROM OLD.last_error THEN
      RAISE EXCEPTION 'published outbox event % cannot change published_at, attempts or last_error', OLD.event_id;
    END IF;
    IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NOT NULL AND NEW.archived_at <> OLD.archived_at THEN
      RAISE EXCEPTION 'archived_at of outbox event % cannot change without resetting it to NULL first', OLD.event_id;
    END IF;
  END IF;
  RETURN NEW;
END
$f$;

CREATE OR REPLACE FUNCTION clearledger.trg_idem_insert_guard() RETURNS trigger
LANGUAGE plpgsql AS $f$
DECLARE
  b jsonb := NEW.response_body;
  eid uuid := clearledger.safe_uuid(b->>'eventId');
  sid uuid := clearledger.safe_uuid(b->>'settlementId');
  ver integer := (b->>'version')::integer;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM clearledger.events e
                  WHERE e.event_id = eid AND e.settlement_id = sid AND e.aggregate_version = ver
                    AND e.idempotency_key = NEW.idempotency_key) THEN
    RAISE EXCEPTION 'idempotency record references no matching event %', eid;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM clearledger.outbox o
                  WHERE o.event_id = eid AND o.settlement_id = sid AND o.aggregate_version = ver) THEN
    RAISE EXCEPTION 'idempotency record references no matching outbox row for event %', eid;
  END IF;
  IF EXISTS (SELECT 1 FROM clearledger.idempotency_keys k
              WHERE k.response_body->>'eventId' = b->>'eventId'
                 OR (k.response_body->>'settlementId' = b->>'settlementId'
                     AND (k.response_body->>'version')::integer = ver)) THEN
    RAISE EXCEPTION 'event % is already bound to another idempotency record', eid;
  END IF;
  RETURN NEW;
END
$f$;

-- ---------------------------------------------------------------- triggers
CREATE FUNCTION pg_temp.add_trg(tbl regclass, tname text, def text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = tbl AND tgname = tname AND NOT tgisinternal) THEN
    EXECUTE format('CREATE TRIGGER %I %s', tname, def);
  END IF;
END
$f$;

SELECT pg_temp.add_trg('clearledger.settlements', 'trg_settlements_guard',
  'BEFORE INSERT OR UPDATE OR DELETE ON clearledger.settlements FOR EACH ROW EXECUTE FUNCTION clearledger.trg_settlements_guard()');
SELECT pg_temp.add_trg('clearledger.events', 'trg_events_insert_guard',
  'BEFORE INSERT ON clearledger.events FOR EACH ROW EXECUTE FUNCTION clearledger.trg_events_insert_guard()');
SELECT pg_temp.add_trg('clearledger.events', 'trg_events_append_only',
  'BEFORE UPDATE OR DELETE ON clearledger.events FOR EACH ROW EXECUTE FUNCTION clearledger.trg_append_only()');
SELECT pg_temp.add_trg('clearledger.outbox', 'trg_outbox_insert_guard',
  'BEFORE INSERT ON clearledger.outbox FOR EACH ROW EXECUTE FUNCTION clearledger.trg_outbox_insert_guard()');
SELECT pg_temp.add_trg('clearledger.outbox', 'trg_outbox_change_guard',
  'BEFORE UPDATE OR DELETE ON clearledger.outbox FOR EACH ROW EXECUTE FUNCTION clearledger.trg_outbox_change_guard()');
SELECT pg_temp.add_trg('clearledger.idempotency_keys', 'trg_idem_insert_guard',
  'BEFORE INSERT ON clearledger.idempotency_keys FOR EACH ROW EXECUTE FUNCTION clearledger.trg_idem_insert_guard()');
SELECT pg_temp.add_trg('clearledger.idempotency_keys', 'trg_idem_append_only',
  'BEFORE UPDATE OR DELETE ON clearledger.idempotency_keys FOR EACH ROW EXECUTE FUNCTION clearledger.trg_append_only()');

-- Re-enable anything disabled out-of-band (user triggers only; system FK triggers need superuser).
ALTER TABLE clearledger.settlements ENABLE TRIGGER USER;
ALTER TABLE clearledger.events ENABLE TRIGGER USER;
ALTER TABLE clearledger.outbox ENABLE TRIGGER USER;
ALTER TABLE clearledger.idempotency_keys ENABLE TRIGGER USER;

-- ---------------------------------------------------------------- indexes
CREATE INDEX IF NOT EXISTS idx_clearledger_outbox_unpublished
  ON clearledger.outbox (seq) WHERE published_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_clearledger_outbox_unarchived
  ON clearledger.outbox (seq) WHERE published_at IS NOT NULL AND archived_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_clearledger_events_settlement_version
  ON clearledger.events (settlement_id, aggregate_version);

COMMIT;
\o
CLEARLEDGER_SCHEMA_EOF
cat > "$HELPER" <<'CLEARLEDGER_HELPER_EOF'
#!/usr/bin/env python3
"""ClearLedger operational helper: control-plane repair, data-plane convergence and teardown sweeps.

Sub-commands (all idempotent):
  kms-restore            cancel pending deletion / re-enable the prefix-scoped KMS keys
  iam-clean              strip out-of-band inline/attached policies from the six roles, delete stray managed policies
  sg-clean               revoke out-of-band public ingress / rds+valkey egress
  esm-check <uuid>       verify the projector event source mapping (exit 3 = needs replace)
  data                   converge outbox, DynamoDB, S3 audit archive and Valkey against PostgreSQL
  sweep                  delete every leftover resource scoped to the prefix (teardown)
"""
import concurrent.futures
import datetime
import hashlib
import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.parse
import urllib.request

import boto3
from boto3.dynamodb.types import TypeDeserializer, TypeSerializer
from botocore.config import Config
from botocore.exceptions import ClientError

CONFIG_FILE = os.environ.get("CONFIG_FILE", "/workspace/config/config.json")
MANIFEST_FILE = os.environ.get("MANIFEST_FILE", "/workspace/submission/manifest.json")

CFG = json.load(open(CONFIG_FILE))
PREFIX = CFG["resource_prefix"]
REGION = CFG["region"]
ENDPOINT = CFG["aws_endpoint_url"]

ROLE_KEYS = ["ecs-execution", "ecs-task", "projector", "relay", "archiver", "scheduler"]


def log(msg):
    print(f"[converge {time.strftime('%H:%M:%S')}] {msg}", flush=True)


def client(name):
    return boto3.client(
        name,
        endpoint_url=ENDPOINT,
        region_name=REGION,
        aws_access_key_id="test",
        aws_secret_access_key="test",
        config=Config(retries={"max_attempts": 6, "mode": "standard"}, read_timeout=180, connect_timeout=15),
    )


def manifest():
    with open(MANIFEST_FILE) as f:
        return json.load(f)


def code_of(e):
    return e.response.get("Error", {}).get("Code", "")


def matches_prefix(name):
    """True when `name` is scoped to this deployment's resource prefix (and not a sibling like <prefix>x)."""
    if not name:
        return False
    return re.search(r"(^|[^A-Za-z0-9])" + re.escape(PREFIX) + r"($|[^A-Za-z0-9])", name) is not None


# --------------------------------------------------------------------------- PostgreSQL helpers
def db_url(m=None):
    m = m or manifest()
    d = m["database"]
    return "postgres://%s:%s@%s:%s/%s" % (CFG["db_username"], CFG["db_password"], d["endpoint"], d["port"], CFG["db_name"])


def psql(sql, url=None, retries=4):
    last = None
    for i in range(retries):
        p = subprocess.run(
            ["psql", url or db_url(), "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-c", sql],
            capture_output=True, text=True, env=dict(os.environ, PGCONNECT_TIMEOUT="10"),
        )
        if p.returncode == 0:
            return p.stdout.strip()
        last = p.stderr.strip()
        time.sleep(2 + i * 2)
    raise RuntimeError("psql failed: " + str(last))


def pg_json(select_sql):
    out = psql("SELECT COALESCE(json_agg(t), '[]'::json) FROM (%s) t" % select_sql)
    return json.loads(out or "[]")


TS = "to_char({c} AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"')"


def fetch_pg():
    settlements = pg_json(
        "SELECT settlement_id::text AS settlement_id, account_id, reference, debit_party, credit_party, "
        "current_status, current_stage, last_entry_id::text AS last_entry_id, last_memo, version, entry_count, "
        + TS.format(c="updated_at") + " AS updated_at FROM clearledger.settlements ORDER BY settlement_id")
    events = pg_json(
        "SELECT seq, event_id::text AS event_id, settlement_id::text AS settlement_id, aggregate_version, "
        "event_type, correlation_id, " + TS.format(c="occurred_at") + " AS occurred_at, payload "
        "FROM clearledger.events ORDER BY settlement_id, aggregate_version")
    return {"settlements": settlements, "events": events}


def fetch_outbox():
    return pg_json(
        "SELECT seq, event_id::text AS event_id, settlement_id::text AS settlement_id, aggregate_version, "
        "payload, published_at IS NOT NULL AS published, archived_at IS NOT NULL AS archived, attempts "
        "FROM clearledger.outbox ORDER BY seq")


# --------------------------------------------------------------------------- time helpers
def parse_ts(s):
    if s is None:
        return None
    s = s.strip()
    s = re.sub(r"[Zz]$", "+00:00", s)
    m = re.match(r"^(.*?)(\.\d+)?([+-]\d{2}:\d{2})$", s)
    if not m:
        raise ValueError(s)
    base, frac, tz = m.group(1), m.group(2) or "", m.group(3)
    frac = (frac + "000000")[:7] if frac else ""
    dt = datetime.datetime.fromisoformat(base + frac + tz)
    return dt.astimezone(datetime.timezone.utc)


def fmt_ts(s, z=False):
    """Format like chrono's to_rfc3339 (AutoSi): 0, 3 or 6 fractional digits."""
    dt = parse_ts(s)
    us = dt.microsecond
    if us == 0:
        frac = ""
    elif us % 1000 == 0:
        frac = ".%03d" % (us // 1000)
    else:
        frac = ".%06d" % us
    return dt.strftime("%Y-%m-%dT%H:%M:%S") + frac + ("Z" if z else "+00:00")


def same_ts(a, b):
    try:
        return parse_ts(a) == parse_ts(b)
    except Exception:
        return False


# --------------------------------------------------------------------------- RESP (Valkey) client
class Resp:
    def __init__(self, host, port, timeout=10):
        self.sock = socket.create_connection((host, int(port)), timeout=timeout)
        self.f = self.sock.makefile("rb")

    def cmd(self, *args):
        out = b"*%d\r\n" % len(args)
        for a in args:
            a = a if isinstance(a, bytes) else str(a).encode()
            out += b"$%d\r\n%s\r\n" % (len(a), a)
        self.sock.sendall(out)
        return self._read()

    def _read(self):
        line = self.f.readline().rstrip(b"\r\n")
        t, v = line[:1], line[1:]
        if t == b"+":
            return v.decode()
        if t == b"-":
            raise RuntimeError(v.decode())
        if t == b":":
            return int(v)
        if t == b"$":
            n = int(v)
            if n < 0:
                return None
            return self.f.read(n + 2)[:-2].decode()
        if t == b"*":
            n = int(v)
            return None if n < 0 else [self._read() for _ in range(n)]
        raise RuntimeError("bad RESP reply %r" % line)

    def scan_keys(self):
        keys, cur = [], "0"
        while True:
            cur, batch = self.cmd("SCAN", cur, "COUNT", 500)
            keys.extend(batch)
            if cur == "0":
                return keys

    def close(self):
        try:
            self.sock.close()
        except Exception:
            pass


# =========================================================================== kms-restore
def cmd_kms_restore():
    kms = client("kms")
    aliases = []
    pager = kms.get_paginator("list_aliases")
    for page in pager.paginate():
        aliases += [a for a in page["Aliases"] if a["AliasName"].startswith("alias/" + PREFIX + "-") and a.get("TargetKeyId")]
    for a in aliases:
        kid = a["TargetKeyId"]
        try:
            st = kms.describe_key(KeyId=kid)["KeyMetadata"]["KeyState"]
        except ClientError as e:
            log("kms %s: %s" % (a["AliasName"], code_of(e)))
            continue
        if st == "PendingDeletion":
            log("kms %s pending deletion -> cancelling" % a["AliasName"])
            kms.cancel_key_deletion(KeyId=kid)
            st = "Disabled"
        if st == "Disabled":
            log("kms %s disabled -> enabling" % a["AliasName"])
            kms.enable_key(KeyId=kid)
        try:
            if not kms.get_key_rotation_status(KeyId=kid).get("KeyRotationEnabled"):
                kms.enable_key_rotation(KeyId=kid)
        except ClientError:
            pass


# =========================================================================== iam-clean
def role_names():
    return ["%s-%s" % (PREFIX, k) for k in ROLE_KEYS]


def canonical_policy(role):
    return role + "-policy"


def delete_policy_fully(iam, arn):
    try:
        ents = iam.list_entities_for_policy(PolicyArn=arn)
        for r in ents.get("PolicyRoles", []):
            iam.detach_role_policy(RoleName=r["RoleName"], PolicyArn=arn)
        for u in ents.get("PolicyUsers", []):
            iam.detach_user_policy(UserName=u["UserName"], PolicyArn=arn)
        for g in ents.get("PolicyGroups", []):
            iam.detach_group_policy(GroupName=g["GroupName"], PolicyArn=arn)
    except ClientError as e:
        log("list_entities_for_policy %s: %s" % (arn, code_of(e)))
    try:
        for v in iam.list_policy_versions(PolicyArn=arn).get("Versions", []):
            if not v["IsDefaultVersion"]:
                iam.delete_policy_version(PolicyArn=arn, VersionId=v["VersionId"])
    except ClientError as e:
        log("list_policy_versions %s: %s" % (arn, code_of(e)))
    iam.delete_policy(PolicyArn=arn)
    log("deleted managed policy %s" % arn)


def cmd_iam_clean(strict_roles=True):
    iam = client("iam")
    for role in role_names():
        try:
            iam.get_role(RoleName=role)
        except ClientError as e:
            if code_of(e) == "NoSuchEntity":
                continue
            raise
        keep = canonical_policy(role) if strict_roles else None
        names = []
        for page in iam.get_paginator("list_role_policies").paginate(RoleName=role):
            names += page["PolicyNames"]
        for n in names:
            if n != keep:
                iam.delete_role_policy(RoleName=role, PolicyName=n)
                log("removed inline policy %s from %s" % (n, role))
        att = []
        for page in iam.get_paginator("list_attached_role_policies").paginate(RoleName=role):
            att += page["AttachedPolicies"]
        for a in att:
            iam.detach_role_policy(RoleName=role, PolicyArn=a["PolicyArn"])
            log("detached %s from %s" % (a["PolicyArn"], role))
    # customer-managed policies scoped to this deployment
    for page in iam.get_paginator("list_policies").paginate(Scope="Local"):
        for p in page["Policies"]:
            if p["PolicyName"].startswith(PREFIX):
                delete_policy_fully(iam, p["Arn"])


# =========================================================================== sg-clean
def cmd_sg_clean():
    m = manifest()
    ec2 = client("ec2")
    ids = m["network"]["security_group_ids"]
    for name, sg_id in ids.items():
        try:
            sg = ec2.describe_security_groups(GroupIds=[sg_id])["SecurityGroups"][0]
        except ClientError as e:
            log("sg %s: %s" % (name, code_of(e)))
            continue

        def public(p):
            return any(r.get("CidrIp") == "0.0.0.0/0" for r in p.get("IpRanges", [])) or any(
                r.get("CidrIpv6") == "::/0" for r in p.get("Ipv6Ranges", []))

        def only_public(p):
            q = {k: v for k, v in p.items() if k not in ("IpRanges", "Ipv6Ranges")}
            q["IpRanges"] = [r for r in p.get("IpRanges", []) if r.get("CidrIp") == "0.0.0.0/0"]
            q["Ipv6Ranges"] = [r for r in p.get("Ipv6Ranges", []) if r.get("CidrIpv6") == "::/0"]
            q["UserIdGroupPairs"] = []
            q["PrefixListIds"] = []
            return q

        if name in ("ecs", "rds", "valkey"):
            bad = [only_public(p) for p in sg.get("IpPermissions", []) if public(p)]
            if bad:
                log("revoking public ingress on %s" % name)
                ec2.revoke_security_group_ingress(GroupId=sg_id, IpPermissions=bad)
        if name in ("rds", "valkey"):
            eg = sg.get("IpPermissionsEgress", [])
            if eg:
                log("revoking egress on %s" % name)
                ec2.revoke_security_group_egress(GroupId=sg_id, IpPermissions=eg)
        if name == "alb":
            bad = [only_public(p) for p in sg.get("IpPermissionsEgress", []) if public(p)]
            if bad:
                log("revoking public egress on alb")
                ec2.revoke_security_group_egress(GroupId=sg_id, IpPermissions=bad)


# =========================================================================== esm-check
def cmd_esm_check(uuid):
    m = manifest()
    lam = client("lambda")
    fn = m["workers"]["projector"]["function_name"]
    qarn = m["messaging"]["queue_arn"]
    mappings = []
    for page in lam.get_paginator("list_event_source_mappings").paginate(FunctionName=fn):
        mappings += page["EventSourceMappings"]
    good = False
    for mp in mappings:
        ok = (
            mp["UUID"] == uuid and mp.get("EventSourceArn") == qarn and mp.get("BatchSize") == 5
            and mp.get("State") in ("Enabled", "Enabling")
            and "ReportBatchItemFailures" in (mp.get("FunctionResponseTypes") or [])
        )
        if ok:
            good = True
        elif mp["UUID"] != uuid:
            log("deleting foreign event source mapping %s (%s)" % (mp["UUID"], mp.get("EventSourceArn")))
            try:
                lam.delete_event_source_mapping(UUID=mp["UUID"])
            except ClientError as e:
                log("delete esm: %s" % code_of(e))
    if not good:
        log("projector event source mapping missing or misconfigured")
        sys.exit(3)
    log("projector event source mapping ok")


# =========================================================================== data-plane
def wait_ready(m, timeout=300):
    url = m["service_url"].rstrip("/") + "/health/ready"
    end = time.time() + timeout
    while time.time() < end:
        try:
            with urllib.request.urlopen(url, timeout=5) as r:
                if r.status == 200:
                    return True
        except Exception:
            pass
        time.sleep(3)
    return False


def lambda_invoke(name):
    lam = client("lambda")
    r = lam.invoke(FunctionName=name, InvocationType="RequestResponse", Payload=b"{}")
    body = r["Payload"].read().decode() or "{}"
    if r.get("FunctionError"):
        raise RuntimeError("lambda %s failed: %s" % (name, body))
    try:
        return json.loads(body)
    except Exception:
        return {}


def pending_unpublished():
    return int(psql("SELECT count(*) FROM clearledger.outbox WHERE published_at IS NULL") or 0)


def pending_unarchived():
    return int(psql("SELECT count(*) FROM clearledger.outbox WHERE published_at IS NOT NULL AND archived_at IS NULL") or 0)


def publish_fallback(m):
    """Publish unpublished rows ourselves (same semantics as the relay) if the relay Lambda is unusable."""
    sqs = client("sqs")
    rows = pg_json("SELECT seq, payload FROM clearledger.outbox WHERE published_at IS NULL ORDER BY seq LIMIT 50")
    for r in rows:
        sqs.send_message(QueueUrl=m["messaging"]["queue_url"], MessageBody=json.dumps(r["payload"], separators=(",", ":")))
        psql("UPDATE clearledger.outbox SET published_at = NOW(), attempts = attempts + 1, last_error = NULL "
             "WHERE seq = %d AND published_at IS NULL" % r["seq"])
    return len(rows)


def publish_all(m, max_rounds=60):
    relay = m["workers"]["outbox_relay"]["function_name"]
    stalls = 0
    for _ in range(max_rounds):
        left = pending_unpublished()
        if left == 0:
            return True
        log("outbox: %d unpublished rows, invoking relay" % left)
        try:
            lambda_invoke(relay)
        except Exception as e:
            log("relay invoke failed: %s" % e)
        now = pending_unpublished()
        if now >= left:
            stalls += 1
            if stalls >= 2:
                log("relay made no progress, publishing directly")
                try:
                    publish_fallback(m)
                except Exception as e:
                    log("direct publish failed: %s" % e)
            if stalls >= 6:
                return False
            time.sleep(2)
        else:
            stalls = 0
    return pending_unpublished() == 0


def wait_queue_drained(m, timeout=90):
    sqs = client("sqs")
    end = time.time() + timeout
    while time.time() < end:
        try:
            a = sqs.get_queue_attributes(QueueUrl=m["messaging"]["queue_url"], AttributeNames=["All"])["Attributes"]
        except ClientError as e:
            log("queue attributes: %s" % code_of(e))
            return
        n = int(a.get("ApproximateNumberOfMessages", 0)) + int(a.get("ApproximateNumberOfMessagesNotVisible", 0))
        if n == 0:
            return
        time.sleep(2)
    log("queue still has messages after %ds; continuing" % timeout)


# ---- DynamoDB ------------------------------------------------------------------------------------
DESER = TypeDeserializer()
SER = TypeSerializer()


def ddb_scan(ddb, table):
    items = []
    for page in ddb.get_paginator("scan").paginate(TableName=table, ConsistentRead=True):
        for it in page["Items"]:
            items.append({k: DESER.deserialize(v) for k, v in it.items()})
    return items


def compact(payload):
    return json.dumps(payload, separators=(",", ":"), ensure_ascii=False)


def expected_ddb(pg):
    exp = {}
    for s in pg["settlements"]:
        pk = "SETTLEMENT#" + s["settlement_id"]
        st = {
            "PK": pk, "SK": "STATE",
            "GSI1PK": "ACCOUNT#" + s["account_id"], "GSI1SK": "SETTLEMENT#" + s["settlement_id"],
            "settlement_id": s["settlement_id"], "account_id": s["account_id"], "reference": s["reference"],
            "debit_party": s["debit_party"], "credit_party": s["credit_party"],
            "status": s["current_status"], "clearing_stage": s["current_stage"],
            "version": int(s["version"]), "entry_count": int(s["version"]) - 1,
            "updated_at": fmt_ts(s["updated_at"]),
        }
        if s.get("last_entry_id"):
            st["last_entry_id"] = s["last_entry_id"]
        if s.get("last_memo") is not None:
            st["last_memo"] = s["last_memo"]
        exp[(pk, "STATE")] = st
    for e in pg["events"]:
        pk = "SETTLEMENT#" + e["settlement_id"]
        sk = "EVENT#%08d" % int(e["aggregate_version"])
        d = e["payload"]["data"]
        it = {
            "PK": pk, "SK": sk, "settlement_id": e["settlement_id"], "event_id": e["event_id"],
            "version": int(e["aggregate_version"]), "event_type": e["event_type"], "status": d["status"],
            "clearing_stage": d["clearingStage"], "occurred_at": fmt_ts(e["occurred_at"]),
            "correlation_id": e["correlation_id"], "envelope": compact(e["payload"]),
        }
        if d.get("entryId"):
            it["entry_id"] = d["entryId"]
        if d.get("memo") is not None:
            it["memo"] = d["memo"]
        exp[(pk, sk)] = it
    return exp


def ddb_equal(actual, expected):
    if set(actual) != set(expected):
        return False
    for k, ev in expected.items():
        av = actual[k]
        if k in ("updated_at", "occurred_at"):
            if not same_ts(av, ev):
                return False
        elif k == "envelope":
            try:
                if json.loads(av) != json.loads(ev):
                    return False
            except Exception:
                return False
        elif k in ("version", "entry_count"):
            if int(av) != int(ev):
                return False
        elif av != ev:
            return False
    return True


def converge_dynamo(m):
    ddb = client("dynamodb")
    table = m["projections"]["table_name"]
    for attempt in range(4):
        # Scan BEFORE reading PostgreSQL: anything projected is already committed, so it cannot be a false orphan.
        actual_items = ddb_scan(ddb, table)
        pg = fetch_pg()
        exp = expected_ddb(pg)
        actual = {}
        for it in actual_items:
            actual[(it.get("PK"), it.get("SK"))] = it
        orphans = [k for k in actual if k not in exp]
        fixes = [k for k in exp if k not in actual or not ddb_equal(actual[k], exp[k])]
        log("dynamodb: %d expected, %d actual, %d orphans, %d to write" % (len(exp), len(actual), len(orphans), len(fixes)))
        if not orphans and not fixes:
            return True
        for k in orphans:
            key = {"PK": SER.serialize(k[0]), "SK": SER.serialize(k[1])} if k[0] is not None and k[1] is not None else None
            if key is None:
                continue
            ddb.delete_item(TableName=table, Key=key)
        for k in fixes:
            item = {a: SER.serialize(v) for a, v in exp[k].items()}
            kw = {}
            if k[1] == "STATE" and k in actual:
                cur = actual[k].get("version")
                if cur is not None and int(cur) > exp[k]["version"]:
                    pass  # corrupted (ahead of the system of record): overwrite unconditionally
                else:
                    kw = dict(ConditionExpression="attribute_not_exists(PK) OR #v <= :v",
                              ExpressionAttributeNames={"#v": "version"},
                              ExpressionAttributeValues={":v": {"N": str(exp[k]["version"])}})
            elif k[1] == "STATE":
                kw = dict(ConditionExpression="attribute_not_exists(PK) OR #v <= :v",
                          ExpressionAttributeNames={"#v": "version"},
                          ExpressionAttributeValues={":v": {"N": str(exp[k]["version"])}})
            try:
                ddb.put_item(TableName=table, Item=item, **kw)
            except ClientError as e:
                if code_of(e) != "ConditionalCheckFailedException":
                    raise
        time.sleep(1)
    return False


# ---- S3 audit archive -----------------------------------------------------------------------------
BATCH_RE = re.compile(r"^(ledger-audit/)batch-(\d{8})-(\d{8})-([0-9a-f]{16})\.ndjson$")


def s3_versions(s3, bucket):
    versions, markers = [], []
    for page in s3.get_paginator("list_object_versions").paginate(Bucket=bucket):
        versions += page.get("Versions", [])
        markers += page.get("DeleteMarkers", [])
    return versions, markers


def s3_delete_versions(s3, bucket, entries):
    entries = list(entries)
    for i in range(0, len(entries), 500):
        chunk = [{"Key": e["Key"], "VersionId": e["VersionId"]} for e in entries[i:i + 500]]
        if chunk:
            s3.delete_objects(Bucket=bucket, Delete={"Objects": chunk, "Quiet": True})


def s3_normalize(s3, bucket, prefix):
    """Undelete current delete markers, purge non-canonical keys, noncurrent versions and remaining markers."""
    for _ in range(5):
        versions, markers = s3_versions(s3, bucket)
        latest_markers = [d for d in markers if d.get("IsLatest")]
        if not latest_markers:
            break
        # a batch hidden behind a delete marker is restored when an older version exists
        by_key = {}
        for v in versions:
            by_key.setdefault(v["Key"], []).append(v)
        restorable = [d for d in latest_markers if by_key.get(d["Key"])]
        if not restorable:
            break
        log("s3: removing %d delete markers hiding archive batches" % len(restorable))
        s3_delete_versions(s3, bucket, restorable)
    versions, markers = s3_versions(s3, bucket)
    doomed = []
    for v in versions:
        if not v.get("IsLatest") or not BATCH_RE.match(v["Key"]) or not v["Key"].startswith(prefix):
            doomed.append(v)
    doomed += markers
    if doomed:
        log("s3: purging %d stray/noncurrent versions and delete markers" % len(doomed))
        s3_delete_versions(s3, bucket, doomed)
    versions, _ = s3_versions(s3, bucket)
    return [v for v in versions if v.get("IsLatest")]


def s3_validate(s3, bucket, current, rows):
    """Return a list of problems (empty = archive is a 1-to-1 mirror of the outbox)."""
    problems = []
    by_seq = {r["seq"]: r for r in rows}
    by_event = {r["event_id"]: r for r in rows}
    seen_rows = {}
    intervals = []
    for v in current:
        key = v["Key"]
        mt = BATCH_RE.match(key)
        if not mt:
            problems.append("non-canonical key " + key)
            continue
        first, last, digest = int(mt.group(2)), int(mt.group(3)), mt.group(4)
        body = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
        if hashlib.sha256(body).hexdigest()[:16] != digest:
            problems.append("digest mismatch " + key)
            continue
        seqs = []
        try:
            lines = [ln for ln in body.decode("utf-8").split("\n") if ln != ""]
            for ln in lines:
                obj = json.loads(ln)
                r = by_event.get(obj.get("eventId"))
                if r is None:
                    problems.append("%s has event %s unknown to PostgreSQL" % (key, obj.get("eventId")))
                    continue
                if obj != r["payload"]:
                    problems.append("%s payload differs for seq %d" % (key, r["seq"]))
                seqs.append(r["seq"])
                if r["seq"] in seen_rows:
                    problems.append("seq %d archived twice (%s, %s)" % (r["seq"], seen_rows[r["seq"]], key))
                seen_rows[r["seq"]] = key
        except Exception as e:
            problems.append("unparseable %s: %s" % (key, e))
            continue
        if not seqs or seqs != sorted(seqs) or len(set(seqs)) != len(seqs):
            problems.append("%s not in strictly ascending seq order" % key)
            continue
        if seqs[0] != first or seqs[-1] != last:
            problems.append("%s bounds do not match content" % key)
        expect = [s for s in by_seq if first <= s <= last]
        if sorted(expect) != seqs:
            problems.append("%s is not a gap-free slice of the outbox" % key)
        intervals.append((first, last, key))
    intervals.sort()
    for a, b in zip(intervals, intervals[1:]):
        if b[0] <= a[1]:
            problems.append("batches overlap: %s / %s" % (a[2], b[2]))
    for r in rows:
        covered = r["seq"] in seen_rows
        if r["archived"] and not covered:
            problems.append("seq %d archived in PostgreSQL but absent from S3" % r["seq"])
        if covered and not r["archived"]:
            problems.append("seq %d present in S3 but archived_at is NULL" % r["seq"])
    return problems


def converge_s3(m):
    s3 = client("s3")
    bucket = m["audit"]["bucket_name"]
    prefix = m["audit"]["prefix"]
    archiver = m["workers"]["audit_archiver"]["function_name"]

    def run_archiver(limit=200):
        stalls = 0
        for _ in range(limit):
            left = pending_unarchived()
            if left == 0:
                return True
            try:
                lambda_invoke(archiver)
            except Exception as e:
                log("archiver invoke failed: %s" % e)
                time.sleep(2)
            if pending_unarchived() >= left:
                stalls += 1
                if stalls >= 4:
                    return False
                time.sleep(2)
            else:
                stalls = 0
        return pending_unarchived() == 0

    for round_ in range(3):
        current = s3_normalize(s3, bucket, prefix)
        problems = s3_validate(s3, bucket, current, fetch_outbox())
        if problems:
            time.sleep(6)  # let an in-flight scheduled archiver run finish before judging
            current = s3_normalize(s3, bucket, prefix)
            problems = s3_validate(s3, bucket, current, fetch_outbox())
        if problems:
            log("s3: archive inconsistent (%d problems, e.g. %s); rebuilding" % (len(problems), problems[0]))
            versions, markers = s3_versions(s3, bucket)
            s3_delete_versions(s3, bucket, versions + markers)
            psql("UPDATE clearledger.outbox SET archived_at = NULL WHERE archived_at IS NOT NULL")
        else:
            log("s3: %d batch objects consistent" % len(current))
        if not run_archiver():
            log("s3: archiver could not drain the backlog")
        current = s3_normalize(s3, bucket, prefix)
        problems = s3_validate(s3, bucket, current, fetch_outbox())
        if not problems and pending_unarchived() == 0:
            return True
        log("s3: still inconsistent after round %d: %s" % (round_ + 1, problems[:3]))
    return False


# ---- Valkey ----------------------------------------------------------------------------------------
def expected_projection(s):
    p = {
        "settlementId": s["settlement_id"], "accountId": s["account_id"], "reference": s["reference"],
        "debitParty": s["debit_party"], "creditParty": s["credit_party"], "status": s["current_status"],
        "clearingStage": s["current_stage"],
    }
    if s.get("last_entry_id"):
        p["lastEntryId"] = s["last_entry_id"]
    if s.get("last_memo") is not None:
        p["lastMemo"] = s["last_memo"]
    p.update({"version": int(s["version"]), "entryCount": int(s["entry_count"]), "updatedAt": s["updated_at"]})
    return p


def proj_equal(raw, exp):
    try:
        got = json.loads(raw)
    except Exception:
        return False
    if not isinstance(got, dict):
        return False
    got = {k: v for k, v in got.items() if v is not None}
    if set(got) != set(exp):
        return False
    for k, v in exp.items():
        if k == "updatedAt":
            if not same_ts(got[k], v):
                return False
        elif got[k] != v:
            return False
    return True


def read_token(m):
    c = m["auth"]["clients"]["read"]
    data = urllib.parse.urlencode({"grant_type": "client_credentials", "scope": c["scope"]}).encode()
    req = urllib.request.Request(m["auth"]["token_endpoint"], data=data)
    import base64
    req.add_header("Authorization", "Basic " + base64.b64encode(("%s:%s" % (c["client_id"], c["client_secret"])).encode()).decode())
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read())["access_token"]


def api_get(m, token, sid):
    req = urllib.request.Request(m["service_url"].rstrip("/") + "/v1/settlements/" + sid)
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("X-Correlation-Id", "converge-" + sid[:8])
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception:
        return 0


def converge_valkey(m):
    host, port = m["cache"]["endpoint"], m["cache"]["port"]
    ns = "clearledger:settlement:"
    for attempt in range(3):
        pg = fetch_pg()
        settlements = {s["settlement_id"]: s for s in pg["settlements"]}
        exp = {ns + sid: expected_projection(s) for sid, s in settlements.items()}
        r = Resp(host, port)
        try:
            for k in r.scan_keys():
                if k not in exp:
                    r.cmd("DEL", k)
            missing = []
            for k, e in exp.items():
                raw = r.cmd("GET", k)
                ttl = r.cmd("TTL", k)
                if raw is not None and proj_equal(raw, e) and 0 < ttl <= 90:
                    continue
                if raw is not None:
                    r.cmd("DEL", k)
                missing.append(k[len(ns):])
            log("valkey: %d settlements, %d need (re)population" % (len(exp), len(missing)))
            if missing:
                token = None
                try:
                    token = read_token(m)
                except Exception as e:
                    log("read token unavailable: %s" % e)
                if token:
                    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
                        list(ex.map(lambda sid: api_get(m, token, sid), missing))
                # verify, falling back to a direct write of the canonical projection
                for sid in missing:
                    k = ns + sid
                    raw = r.cmd("GET", k)
                    ttl = r.cmd("TTL", k)
                    if raw is not None and proj_equal(raw, exp[k]) and 0 < ttl <= 90:
                        continue
                    log("valkey: writing %s directly" % k)
                    r.cmd("SET", k, json.dumps(exp[k], separators=(",", ":")), "EX", 90)
            # final verification
            bad = 0
            keys = set(r.scan_keys())
            if keys != set(exp):
                bad += 1
            for k, e in exp.items():
                raw = r.cmd("GET", k)
                ttl = r.cmd("TTL", k)
                if raw is None or not proj_equal(raw, e) or not (0 < ttl <= 90):
                    bad += 1
            if bad == 0:
                return True
        finally:
            r.close()
        time.sleep(2)
    return False


def cmd_data():
    m = manifest()
    ok = True
    if not wait_ready(m, 300):
        log("WARNING: API not ready before data convergence")
    if not publish_all(m):
        log("ERROR: outbox could not be fully published")
        ok = False
    wait_queue_drained(m)
    if not converge_dynamo(m):
        log("ERROR: DynamoDB did not converge")
        ok = False
    if not converge_s3(m):
        log("ERROR: S3 audit archive did not converge")
        ok = False
    # DynamoDB can be touched by in-flight projector deliveries: verify once more, then cache last (90s TTL).
    if not converge_dynamo(m):
        log("ERROR: DynamoDB did not converge (second pass)")
        ok = False
    if not converge_valkey(m):
        log("ERROR: Valkey did not converge")
        ok = False
    sys.exit(0 if ok else 1)


# =========================================================================== sweep (teardown)
def safe(label, fn, *a, **kw):
    try:
        return fn(*a, **kw)
    except ClientError as e:
        log("sweep %s: %s" % (label, code_of(e)))
    except Exception as e:  # keep sweeping
        log("sweep %s: %s" % (label, e))


def empty_bucket(s3, bucket):
    versions, markers = s3_versions(s3, bucket)
    s3_delete_versions(s3, bucket, versions + markers)
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket):
        objs = [{"Key": o["Key"]} for o in page.get("Contents", [])]
        if objs:
            s3.delete_objects(Bucket=bucket, Delete={"Objects": objs, "Quiet": True})


def sweep_tagged_kms(kms):
    for page in kms.get_paginator("list_keys").paginate():
        for k in page["Keys"]:
            try:
                md = kms.describe_key(KeyId=k["KeyId"])["KeyMetadata"]
                if md.get("KeyManager") != "CUSTOMER" or md.get("KeyState") in ("PendingDeletion", "PendingReplicaDeletion"):
                    continue
                tags = kms.list_resource_tags(KeyId=k["KeyId"]).get("Tags", [])
                if any(t["TagKey"] == "ClearLedgerDeployment" and t["TagValue"] == PREFIX for t in tags):
                    kms.schedule_key_deletion(KeyId=k["KeyId"], PendingWindowInDays=7)
                    log("scheduled deletion of key %s" % k["KeyId"])
            except ClientError:
                continue


def cmd_sweep():
    """Remove anything scoped to the prefix that Terraform no longer (or never) tracked."""
    # compute / traffic
    ecs = client("ecs")
    def sweep_ecs():
        for arn in ecs.list_clusters().get("clusterArns", []):
            name = arn.split("/")[-1]
            if not matches_prefix(name):
                continue
            for sv in ecs.list_services(cluster=arn).get("serviceArns", []):
                safe("ecs service", ecs.update_service, cluster=arn, service=sv, desiredCount=0)
                safe("ecs service", ecs.delete_service, cluster=arn, service=sv, force=True)
            for t in ecs.list_tasks(cluster=arn).get("taskArns", []):
                safe("ecs task", ecs.stop_task, cluster=arn, task=t)
            ecs.delete_cluster(cluster=arn)
            log("deleted ecs cluster %s" % name)
        for fam in ecs.list_task_definition_families(status="ACTIVE").get("families", []):
            if matches_prefix(fam):
                for td in ecs.list_task_definitions(familyPrefix=fam).get("taskDefinitionArns", []):
                    safe("ecs taskdef", ecs.deregister_task_definition, taskDefinition=td)
    safe("ecs", sweep_ecs)

    elb = client("elbv2")
    def sweep_elb():
        for lb in elb.describe_load_balancers().get("LoadBalancers", []):
            if matches_prefix(lb["LoadBalancerName"]):
                for ls in elb.describe_listeners(LoadBalancerArn=lb["LoadBalancerArn"]).get("Listeners", []):
                    safe("listener", elb.delete_listener, ListenerArn=ls["ListenerArn"])
                elb.delete_load_balancer(LoadBalancerArn=lb["LoadBalancerArn"])
                log("deleted load balancer %s" % lb["LoadBalancerName"])
        for tg in elb.describe_target_groups().get("TargetGroups", []):
            if matches_prefix(tg["TargetGroupName"]):
                safe("target group", elb.delete_target_group, TargetGroupArn=tg["TargetGroupArn"])
    safe("elbv2", sweep_elb)

    # schedulers, event sources, functions
    sch = client("scheduler")
    def sweep_sched():
        for page in sch.get_paginator("list_schedules").paginate():
            for s in page["Schedules"]:
                if matches_prefix(s["Name"]):
                    sch.delete_schedule(Name=s["Name"], GroupName=s.get("GroupName", "default"))
                    log("deleted schedule %s" % s["Name"])
    safe("scheduler", sweep_sched)

    lam = client("lambda")
    def sweep_lambda():
        for page in lam.get_paginator("list_functions").paginate():
            for f in page["Functions"]:
                if matches_prefix(f["FunctionName"]):
                    for mp in lam.list_event_source_mappings(FunctionName=f["FunctionName"]).get("EventSourceMappings", []):
                        safe("esm", lam.delete_event_source_mapping, UUID=mp["UUID"])
                    lam.delete_function(FunctionName=f["FunctionName"])
                    log("deleted function %s" % f["FunctionName"])
    safe("lambda", sweep_lambda)

    # data stores
    rds = client("rds")
    def sweep_rds():
        for d in rds.describe_db_instances().get("DBInstances", []):
            if matches_prefix(d["DBInstanceIdentifier"]):
                rds.delete_db_instance(DBInstanceIdentifier=d["DBInstanceIdentifier"], SkipFinalSnapshot=True,
                                       DeleteAutomatedBackups=True)
                log("deleted db instance %s" % d["DBInstanceIdentifier"])
        for g in rds.describe_db_subnet_groups().get("DBSubnetGroups", []):
            if matches_prefix(g["DBSubnetGroupName"]):
                safe("db subnet group", rds.delete_db_subnet_group, DBSubnetGroupName=g["DBSubnetGroupName"])
    safe("rds", sweep_rds)

    ec = client("elasticache")
    def sweep_cache():
        for g in ec.describe_replication_groups().get("ReplicationGroups", []):
            if matches_prefix(g["ReplicationGroupId"]):
                ec.delete_replication_group(ReplicationGroupId=g["ReplicationGroupId"], RetainPrimaryCluster=False)
                log("deleted replication group %s" % g["ReplicationGroupId"])
        for c in ec.describe_cache_clusters().get("CacheClusters", []):
            if matches_prefix(c["CacheClusterId"]):
                safe("cache cluster", ec.delete_cache_cluster, CacheClusterId=c["CacheClusterId"])
        for g in ec.describe_cache_subnet_groups().get("CacheSubnetGroups", []):
            if matches_prefix(g["CacheSubnetGroupName"]):
                safe("cache subnet group", ec.delete_cache_subnet_group, CacheSubnetGroupName=g["CacheSubnetGroupName"])
    safe("elasticache", sweep_cache)

    ddb = client("dynamodb")
    def sweep_ddb():
        for page in ddb.get_paginator("list_tables").paginate():
            for t in page["TableNames"]:
                if matches_prefix(t):
                    ddb.delete_table(TableName=t)
                    log("deleted table %s" % t)
    safe("dynamodb", sweep_ddb)

    sqs = client("sqs")
    def sweep_sqs():
        for u in sqs.list_queues().get("QueueUrls", []) or []:
            if matches_prefix(u.rsplit("/", 1)[-1]):
                sqs.delete_queue(QueueUrl=u)
                log("deleted queue %s" % u)
    safe("sqs", sweep_sqs)

    s3 = client("s3")
    def sweep_s3():
        for b in s3.list_buckets().get("Buckets", []):
            if matches_prefix(b["Name"]):
                safe("empty bucket", empty_bucket, s3, b["Name"])
                s3.delete_bucket(Bucket=b["Name"])
                log("deleted bucket %s" % b["Name"])
    safe("s3", sweep_s3)

    cog = client("cognito-idp")
    def sweep_cognito():
        for page in cog.get_paginator("list_user_pools").paginate(MaxResults=60):
            for p in page["UserPools"]:
                if matches_prefix(p["Name"]):
                    try:
                        dom = cog.describe_user_pool(UserPoolId=p["Id"])["UserPool"].get("Domain")
                        if dom:
                            cog.delete_user_pool_domain(Domain=dom, UserPoolId=p["Id"])
                    except ClientError:
                        pass
                    cog.delete_user_pool(UserPoolId=p["Id"])
                    log("deleted user pool %s" % p["Name"])
    safe("cognito", sweep_cognito)

    # IAM
    iam = client("iam")
    def sweep_iam():
        for page in iam.get_paginator("list_policies").paginate(Scope="Local"):
            for p in page["Policies"]:
                if p["PolicyName"].startswith(PREFIX):
                    safe("policy", delete_policy_fully, iam, p["Arn"])
        for page in iam.get_paginator("list_roles").paginate():
            for r in page["Roles"]:
                if r["RoleName"].startswith(PREFIX):
                    n = r["RoleName"]
                    for pn in iam.list_role_policies(RoleName=n).get("PolicyNames", []):
                        iam.delete_role_policy(RoleName=n, PolicyName=pn)
                    for a in iam.list_attached_role_policies(RoleName=n).get("AttachedPolicies", []):
                        iam.detach_role_policy(RoleName=n, PolicyArn=a["PolicyArn"])
                    for ip in iam.list_instance_profiles_for_role(RoleName=n).get("InstanceProfiles", []):
                        safe("instance profile", iam.remove_role_from_instance_profile, InstanceProfileName=ip["InstanceProfileName"], RoleName=n)
                    iam.delete_role(RoleName=n)
                    log("deleted role %s" % n)
    safe("iam", sweep_iam)

    # KMS
    kms = client("kms")
    def sweep_kms():
        for page in kms.get_paginator("list_aliases").paginate():
            for a in page["Aliases"]:
                if a["AliasName"].startswith("alias/" + PREFIX + "-") or a["AliasName"] == "alias/" + PREFIX:
                    safe("alias", kms.delete_alias, AliasName=a["AliasName"])
        sweep_tagged_kms(kms)
    safe("kms", sweep_kms)

    # Network
    ec2 = client("ec2")
    def sweep_net():
        vpcs = []
        for v in ec2.describe_vpcs().get("Vpcs", []):
            tags = {t["Key"]: t["Value"] for t in v.get("Tags", [])}
            if tags.get("ClearLedgerDeployment") == PREFIX or matches_prefix(tags.get("Name", "")):
                vpcs.append(v["VpcId"])
        for vid in vpcs:
            flt = [{"Name": "vpc-id", "Values": [vid]}]
            for ni in ec2.describe_network_interfaces(Filters=flt).get("NetworkInterfaces", []):
                safe("eni", ec2.delete_network_interface, NetworkInterfaceId=ni["NetworkInterfaceId"])
            for sg in ec2.describe_security_groups(Filters=flt).get("SecurityGroups", []):
                if sg["GroupName"] != "default":
                    if sg.get("IpPermissions"):
                        safe("sg ingress", ec2.revoke_security_group_ingress, GroupId=sg["GroupId"], IpPermissions=sg["IpPermissions"])
                    if sg.get("IpPermissionsEgress"):
                        safe("sg egress", ec2.revoke_security_group_egress, GroupId=sg["GroupId"], IpPermissions=sg["IpPermissionsEgress"])
            for sg in ec2.describe_security_groups(Filters=flt).get("SecurityGroups", []):
                if sg["GroupName"] != "default":
                    safe("sg", ec2.delete_security_group, GroupId=sg["GroupId"])
            for rt in ec2.describe_route_tables(Filters=flt).get("RouteTables", []):
                if any(a.get("Main") for a in rt.get("Associations", [])):
                    continue
                for a in rt.get("Associations", []):
                    safe("rt assoc", ec2.disassociate_route_table, AssociationId=a["RouteTableAssociationId"])
                safe("route table", ec2.delete_route_table, RouteTableId=rt["RouteTableId"])
            for sn in ec2.describe_subnets(Filters=flt).get("Subnets", []):
                safe("subnet", ec2.delete_subnet, SubnetId=sn["SubnetId"])
            for ig in ec2.describe_internet_gateways(Filters=[{"Name": "attachment.vpc-id", "Values": [vid]}]).get("InternetGateways", []):
                safe("igw detach", ec2.detach_internet_gateway, InternetGatewayId=ig["InternetGatewayId"], VpcId=vid)
                safe("igw", ec2.delete_internet_gateway, InternetGatewayId=ig["InternetGatewayId"])
            safe("vpc", ec2.delete_vpc, VpcId=vid)
            log("deleted vpc %s" % vid)
    safe("ec2", sweep_net)

    # Logs: our four groups plus the groups the control plane auto-creates for prefixed resources
    logs = client("logs")
    def sweep_logs():
        for page in logs.get_paginator("describe_log_groups").paginate():
            for g in page["logGroups"]:
                if matches_prefix(g["logGroupName"]):
                    logs.delete_log_group(logGroupName=g["logGroupName"])
                    log("deleted log group %s" % g["logGroupName"])
    safe("logs", sweep_logs)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    c = sys.argv[1]
    if c == "kms-restore":
        cmd_kms_restore()
    elif c == "iam-clean":
        cmd_iam_clean()
    elif c == "iam-clean-all":
        cmd_iam_clean(strict_roles=False)
    elif c == "sg-clean":
        cmd_sg_clean()
    elif c == "esm-check":
        cmd_esm_check(sys.argv[2])
    elif c == "data":
        cmd_data()
    elif c == "sweep":
        cmd_sweep()
    elif c == "empty-bucket":
        s3 = client("s3")
        try:
            empty_bucket(s3, sys.argv[2])
        except ClientError as e:
            log("empty-bucket: %s" % code_of(e))
    else:
        print("unknown command", c)
        sys.exit(2)


if __name__ == "__main__":
    main()
CLEARLEDGER_HELPER_EOF
trap 'rm -f "$SCHEMA" "$HELPER"' EXIT
helper() { python3 "$HELPER" "$@"; }

tf() { "$TF" -chdir="$INFRA" "$@"; }

write_manifest() {
  local tmp="$MANIFEST.tmp"
  tf output -json manifest > "$tmp"
  python3 - "$tmp" <<'PY'
import json, sys
import jsonschema
m = json.load(open(sys.argv[1]))
schema = json.load(open("/workspace/contracts/schemas/manifest.schema.json"))
jsonschema.validate(m, schema)
json.dump(m, open(sys.argv[1], "w"), indent=2)
PY
  mv "$tmp" "$MANIFEST"
}

# ------------------------------------------------------------------ control plane reachable?
for i in $(seq 1 30); do
  if curl -fsS -m 5 -o /dev/null "$ENDPOINT/_localstack/health" 2>/dev/null || curl -sS -m 5 -o /dev/null "$ENDPOINT" 2>/dev/null; then break; fi
  sleep 2
done

# ------------------------------------------------------------------ terraform
log "terraform init"
tf init -input=false -no-color >/dev/null
helper kms-restore || log "kms-restore skipped"

apply_ok=0
for attempt in 1 2 3; do
  log "terraform apply (attempt $attempt)"
  if tf apply -auto-approve -input=false -no-color -lock-timeout=120s; then apply_ok=1; break; fi
  log "apply failed; repairing and retrying"
  helper kms-restore || true
  sleep 10
done
[ "$apply_ok" = 1 ] || { log "terraform apply failed"; exit 1; }

write_manifest

# The projector event source mapping must exist, be enabled and point at the live queue.
ESM_UUID="$(jq -r .messaging.event_source_mapping_uuid "$MANIFEST")"
if ! helper esm-check "$ESM_UUID"; then
  log "re-binding projector event source mapping"
  tf apply -auto-approve -input=false -no-color -lock-timeout=120s \
     -replace=aws_lambda_event_source_mapping.projector
  write_manifest
fi

# ------------------------------------------------------------------ out-of-band control-plane drift Terraform cannot see
log "reconciling IAM policies and security groups"
helper iam-clean
helper sg-clean

# ------------------------------------------------------------------ PostgreSQL schema
DB_HOST="$(jq -r .database.endpoint "$MANIFEST")"
DB_PORT="$(jq -r .database.port "$MANIFEST")"
DB_URL="postgres://${DB_USER}:${DB_PASS}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
export PGCONNECT_TIMEOUT=10
log "waiting for PostgreSQL at ${DB_HOST}:${DB_PORT}"
for i in $(seq 1 60); do
  if psql "$DB_URL" -X -q -At -c 'select 1' >/dev/null 2>&1; then break; fi
  sleep 3
done
schema_ok=0
for attempt in 1 2 3 4 5; do
  log "applying clearledger schema (attempt $attempt)"
  if psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 -f "$SCHEMA"; then schema_ok=1; break; fi
  sleep 5
done
[ "$schema_ok" = 1 ] || { log "schema application failed"; exit 1; }

# ------------------------------------------------------------------ readiness
SERVICE_URL="$(jq -r .service_url "$MANIFEST")"
wait_ready() {
  local limit="$1" code
  for i in $(seq 1 "$limit"); do
    code="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$SERVICE_URL/health/ready" || true)"
    [ "$code" = "200" ] && return 0
    sleep 3
  done
  return 1
}
log "waiting for $SERVICE_URL/health/ready"
wait_ready 80 || { log "API did not become ready"; exit 1; }

# ------------------------------------------------------------------ data-plane convergence (PostgreSQL is authoritative)
log "converging outbox, DynamoDB, S3 audit archive and Valkey"
conv_ok=0
for attempt in 1 2 3; do
  if helper data; then conv_ok=1; break; fi
  log "data convergence incomplete (attempt $attempt)"
  sleep 5
done
[ "$conv_ok" = 1 ] || { log "data convergence failed"; exit 1; }

write_manifest
wait_ready 20 || { log "API not ready at exit"; exit 1; }
log "deployment complete: $SERVICE_URL"
