#!/usr/bin/env bash
# ClearLedger deployment: infrastructure (Terraform/OpenTofu), PostgreSQL schema,
# manifest export, and data-plane convergence against PostgreSQL.
# Safe to re-run: it repairs drift and never replaces RDS / DynamoDB / S3 data.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${SCRIPT_DIR}/infra"
STATE_FILE="${INFRA_DIR}/terraform.tfstate"
MANIFEST_FILE="${SCRIPT_DIR}/manifest.json"
CONFIG_FILE="${CLEARLEDGER_CONFIG:-/workspace/config/config.json}"
SCHEMA_FILE="${SCRIPT_DIR}/.deploy-schema.sql"

log() { printf '[deploy %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

[ -f "$CONFIG_FILE" ] || die "config file not found: $CONFIG_FILE"
for tool in jq curl psql; do command -v "$tool" >/dev/null || die "$tool is required"; done

# Python interpreter that has boto3, psycopg2 and redis available.
PYTHON=""
for cand in python3 /opt/venv/bin/python3; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" -c 'import boto3, psycopg2, redis' >/dev/null 2>&1; then
    PYTHON="$cand"; break
  fi
done
[ -n "$PYTHON" ] || die "no python3 with boto3, psycopg2 and redis available"

if command -v terraform >/dev/null 2>&1; then TF=terraform
elif command -v tofu >/dev/null 2>&1; then TF=tofu
else die "neither terraform nor tofu found"; fi

REGION="$(jq -r .region "$CONFIG_FILE")"
PREFIX="$(jq -r .resource_prefix "$CONFIG_FILE")"
ENDPOINT="$(jq -r .aws_endpoint_url "$CONFIG_FILE")"
DB_USER="$(jq -r .db_username "$CONFIG_FILE")"
DB_PASS="$(jq -r .db_password "$CONFIG_FILE")"
DB_NAME="$(jq -r .db_name "$CONFIG_FILE")"

export AWS_ENDPOINT_URL="$ENDPOINT" AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_PAGER="" TF_IN_AUTOMATION=1 TF_INPUT=0 TF_VAR_config_file="$CONFIG_FILE"
export NO_PROXY="${NO_PROXY:-},aws" no_proxy="${no_proxy:-},aws"

# one deployment at a time
exec 9>"/tmp/clearledger-deploy-${PREFIX}.lock"
flock -w 600 9 || die "another deploy/destroy is running"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" "$SCHEMA_FILE"' EXIT

# ---------------------------------------------------------------------------
# 1. Infrastructure
# ---------------------------------------------------------------------------
tf() { "$TF" -chdir="$INFRA_DIR" "$@"; }

log "initialising $TF in $INFRA_DIR"
tf init -input=false -no-color >"$WORK/init.log" 2>&1 || { cat "$WORK/init.log"; die "init failed"; }

applied=0
for attempt in 1 2 3; do
  log "applying infrastructure (attempt $attempt)"
  if tf apply -auto-approve -input=false -no-color -lock-timeout=120s -state="$STATE_FILE" >"$WORK/apply.log" 2>&1; then
    applied=1; tail -n 4 "$WORK/apply.log"; break
  fi
  tail -n 40 "$WORK/apply.log"
  sleep 10
done
[ "$applied" = 1 ] || die "terraform apply failed"

tf output -json -no-color manifest >"$WORK/manifest.raw.json" 2>/dev/null || die "cannot read manifest output"
jq -S . "$WORK/manifest.raw.json" >"$WORK/manifest.json"

write_manifest() {
  jq . "$WORK/manifest.json" >"${MANIFEST_FILE}.tmp" && mv "${MANIFEST_FILE}.tmp" "$MANIFEST_FILE"
  chmod 644 "$MANIFEST_FILE" 2>/dev/null || true
}
write_manifest

DB_HOST="$(jq -r .database.endpoint "$MANIFEST_FILE")"
DB_PORT="$(jq -r .database.port "$MANIFEST_FILE")"
SERVICE_URL="$(jq -r .service_url "$MANIFEST_FILE")"

# ---------------------------------------------------------------------------
# 2. PostgreSQL schema (idempotent)
# ---------------------------------------------------------------------------
cat >"$SCHEMA_FILE" <<'CLSQL'
-- ClearLedger schema. Idempotent: safe to run on every deploy, preserves data.
SELECT pg_advisory_xact_lock(727274001);
SET LOCAL lock_timeout = '30s';
SET LOCAL client_min_messages = warning;

CREATE SCHEMA IF NOT EXISTS clearledger;

-- ---------------------------------------------------------------------------
-- Tables (columns + primary keys only; constraints are added idempotently below)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS clearledger.settlements (
  settlement_id  UUID        NOT NULL PRIMARY KEY,
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
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS clearledger.events (
  seq             BIGSERIAL   NOT NULL PRIMARY KEY,
  event_id        UUID        NOT NULL,
  settlement_id   UUID        NOT NULL,
  aggregate_version INTEGER   NOT NULL,
  event_type      TEXT        NOT NULL,
  correlation_id  TEXT        NOT NULL,
  idempotency_key TEXT        NOT NULL,
  occurred_at     TIMESTAMPTZ NOT NULL,
  payload         JSONB       NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS clearledger.outbox (
  seq             BIGSERIAL   NOT NULL PRIMARY KEY,
  event_id        UUID        NOT NULL,
  settlement_id   UUID        NOT NULL,
  aggregate_version INTEGER   NOT NULL,
  correlation_id  TEXT        NOT NULL,
  payload         JSONB       NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  published_at    TIMESTAMPTZ NULL,
  archived_at     TIMESTAMPTZ NULL,
  attempts        INTEGER     NOT NULL DEFAULT 0,
  last_error      TEXT        NULL
);

CREATE TABLE IF NOT EXISTS clearledger.idempotency_keys (
  scope           TEXT        NOT NULL,
  idempotency_key TEXT        NOT NULL,
  request_hash    TEXT        NOT NULL,
  status_code     INTEGER     NOT NULL,
  response_body   JSONB       NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (scope, idempotency_key)
);

-- ---------------------------------------------------------------------------
-- Helper functions
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION clearledger.trimlen(t TEXT) RETURNS INTEGER
LANGUAGE sql IMMUTABLE AS $$
  SELECT char_length(btrim(t, ' ' || chr(9) || chr(10) || chr(11) || chr(12) || chr(13)))
$$;

CREATE OR REPLACE FUNCTION clearledger.status_rank(s TEXT) RETURNS INTEGER
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE s
    WHEN 'INITIATED' THEN 0 WHEN 'VALIDATED' THEN 1 WHEN 'RESERVED' THEN 2
    WHEN 'CLEARED' THEN 3 WHEN 'SETTLED' THEN 4 WHEN 'RECONCILED' THEN 5
    ELSE NULL END
$$;

CREATE OR REPLACE FUNCTION clearledger.status_transition_ok(old_s TEXT, new_s TEXT) RETURNS BOOLEAN
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN old_s IS NULL OR new_s IS NULL THEN FALSE
    WHEN old_s = 'RECONCILED' THEN FALSE
    WHEN old_s = 'DISPUTED' THEN new_s IN ('DISPUTED', 'RECONCILED')
    WHEN clearledger.status_rank(old_s) IS NULL THEN FALSE
    WHEN new_s = 'DISPUTED' THEN TRUE
    WHEN clearledger.status_rank(new_s) IS NULL THEN FALSE
    ELSE clearledger.status_rank(new_s) >= clearledger.status_rank(old_s)
  END
$$;

CREATE OR REPLACE FUNCTION clearledger.is_uuid_text(t TEXT) RETURNS BOOLEAN
LANGUAGE sql IMMUTABLE AS $$
  SELECT t ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
$$;

-- Validates a domain event envelope against schemas/events.schema.json plus the
-- stricter bounds/coupling rules from the ClearLedger contract.
CREATE OR REPLACE FUNCTION clearledger.envelope_valid(p JSONB) RETURNS BOOLEAN
LANGUAGE plpgsql STABLE AS $$
DECLARE
  d JSONB;
  v INTEGER;
  et TEXT;
  kind TEXT;
  st TEXT;
BEGIN
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN RETURN FALSE; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_object_keys(p) AS k(key) WHERE k.key NOT IN
      ('schemaVersion','eventId','eventType','aggregateType','aggregateId','aggregateVersion',
       'occurredAt','correlationId','idempotencyKey','data')) THEN RETURN FALSE; END IF;
  IF NOT (p ?& ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId',
                     'aggregateVersion','occurredAt','correlationId','idempotencyKey','data']) THEN
    RETURN FALSE;
  END IF;
  IF jsonb_typeof(p->'schemaVersion') <> 'string' OR p->>'schemaVersion' <> '1.0' THEN RETURN FALSE; END IF;
  IF jsonb_typeof(p->'eventId') <> 'string' OR NOT clearledger.is_uuid_text(p->>'eventId') THEN RETURN FALSE; END IF;
  IF jsonb_typeof(p->'aggregateType') <> 'string' OR p->>'aggregateType' <> 'settlement' THEN RETURN FALSE; END IF;
  IF jsonb_typeof(p->'aggregateId') <> 'string' OR NOT clearledger.is_uuid_text(p->>'aggregateId') THEN RETURN FALSE; END IF;
  IF jsonb_typeof(p->'aggregateVersion') <> 'number' OR (p->>'aggregateVersion') !~ '^[0-9]+$' THEN RETURN FALSE; END IF;
  v := (p->>'aggregateVersion')::INTEGER;
  IF v < 1 THEN RETURN FALSE; END IF;
  IF jsonb_typeof(p->'eventType') <> 'string' OR p->>'eventType' NOT IN ('SettlementInitiated','LedgerEntryRecorded') THEN RETURN FALSE; END IF;
  et := p->>'eventType';
  IF jsonb_typeof(p->'occurredAt') <> 'string'
     OR (p->>'occurredAt') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?([Zz]|[+-][0-9]{2}:[0-9]{2})$' THEN
    RETURN FALSE;
  END IF;
  PERFORM (p->>'occurredAt')::TIMESTAMPTZ;
  IF jsonb_typeof(p->'correlationId') <> 'string' OR clearledger.trimlen(p->>'correlationId') NOT BETWEEN 4 AND 128 THEN RETURN FALSE; END IF;
  IF jsonb_typeof(p->'idempotencyKey') <> 'string' OR clearledger.trimlen(p->>'idempotencyKey') NOT BETWEEN 8 AND 128 THEN RETURN FALSE; END IF;

  d := p->'data';
  IF jsonb_typeof(d) <> 'object' THEN RETURN FALSE; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_object_keys(d) AS k(key) WHERE k.key NOT IN
      ('kind','accountId','reference','debitParty','creditParty','entryId','status','clearingStage','memo')) THEN
    RETURN FALSE;
  END IF;
  IF NOT (d ?& ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage']) THEN RETURN FALSE; END IF;
  IF jsonb_typeof(d->'kind') <> 'string' OR d->>'kind' NOT IN ('settlementInitiated','ledgerEntryRecorded') THEN RETURN FALSE; END IF;
  IF jsonb_typeof(d->'accountId') <> 'string' OR clearledger.trimlen(d->>'accountId') NOT BETWEEN 3 AND 64 THEN RETURN FALSE; END IF;
  IF jsonb_typeof(d->'reference') <> 'string' OR clearledger.trimlen(d->>'reference') NOT BETWEEN 3 AND 64 THEN RETURN FALSE; END IF;
  IF jsonb_typeof(d->'debitParty') <> 'string' OR clearledger.trimlen(d->>'debitParty') NOT BETWEEN 2 AND 64 THEN RETURN FALSE; END IF;
  IF jsonb_typeof(d->'creditParty') <> 'string' OR clearledger.trimlen(d->>'creditParty') NOT BETWEEN 2 AND 64 THEN RETURN FALSE; END IF;
  IF jsonb_typeof(d->'status') <> 'string' OR clearledger.status_rank(d->>'status') IS NULL AND d->>'status' <> 'DISPUTED' THEN RETURN FALSE; END IF;
  IF jsonb_typeof(d->'clearingStage') <> 'string' OR clearledger.trimlen(d->>'clearingStage') NOT BETWEEN 2 AND 64 THEN RETURN FALSE; END IF;
  IF d ? 'memo' AND jsonb_typeof(d->'memo') <> 'null' THEN
    IF jsonb_typeof(d->'memo') <> 'string' OR clearledger.trimlen(d->>'memo') NOT BETWEEN 1 AND 256 THEN RETURN FALSE; END IF;
  END IF;
  IF d ? 'entryId' AND jsonb_typeof(d->'entryId') NOT IN ('null','string') THEN RETURN FALSE; END IF;
  IF d ? 'entryId' AND jsonb_typeof(d->'entryId') = 'string' AND NOT clearledger.is_uuid_text(d->>'entryId') THEN RETURN FALSE; END IF;

  kind := d->>'kind';
  st := d->>'status';
  IF v = 1 THEN
    IF et <> 'SettlementInitiated' OR kind <> 'settlementInitiated' OR st <> 'INITIATED' THEN RETURN FALSE; END IF;
    IF d ? 'entryId' AND jsonb_typeof(d->'entryId') <> 'null' THEN RETURN FALSE; END IF;
  ELSE
    IF et <> 'LedgerEntryRecorded' OR kind <> 'ledgerEntryRecorded' OR st = 'INITIATED' THEN RETURN FALSE; END IF;
    IF NOT (d ? 'entryId') OR jsonb_typeof(d->'entryId') <> 'string' THEN RETURN FALSE; END IF;
  END IF;
  RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
  RETURN FALSE;
END
$$;

-- Column-to-envelope equality (events table carries more columns than outbox).
CREATE OR REPLACE FUNCTION clearledger.envelope_matches(
  p JSONB, c_event_id UUID, c_settlement_id UUID, c_version INTEGER, c_correlation_id TEXT,
  c_event_type TEXT, c_idempotency_key TEXT, c_occurred_at TIMESTAMPTZ) RETURNS BOOLEAN
LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN clearledger.envelope_valid(p)
    AND (p->>'eventId')::UUID = c_event_id
    AND (p->>'aggregateId')::UUID = c_settlement_id
    AND (p->>'aggregateVersion')::INTEGER = c_version
    AND p->>'correlationId' = c_correlation_id
    AND (c_event_type IS NULL OR p->>'eventType' = c_event_type)
    AND (c_idempotency_key IS NULL OR p->>'idempotencyKey' = c_idempotency_key)
    AND (c_occurred_at IS NULL OR (p->>'occurredAt')::TIMESTAMPTZ = c_occurred_at);
EXCEPTION WHEN OTHERS THEN
  RETURN FALSE;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.idempotency_body_valid(b JSONB) RETURNS BOOLEAN
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF b IS NULL OR jsonb_typeof(b) <> 'object' THEN RETURN FALSE; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_object_keys(b) AS k(key) WHERE k.key NOT IN
      ('settlementId','eventId','version','accepted','idempotentReplay')) THEN RETURN FALSE; END IF;
  IF NOT (b ?& ARRAY['settlementId','eventId','version','accepted','idempotentReplay']) THEN RETURN FALSE; END IF;
  RETURN jsonb_typeof(b->'settlementId') = 'string' AND clearledger.is_uuid_text(b->>'settlementId')
     AND jsonb_typeof(b->'eventId') = 'string' AND clearledger.is_uuid_text(b->>'eventId')
     AND jsonb_typeof(b->'version') = 'number' AND (b->>'version') ~ '^[0-9]+$' AND (b->>'version')::INTEGER >= 1
     AND b->'accepted' = 'true'::jsonb
     AND b->'idempotentReplay' = 'false'::jsonb;
EXCEPTION WHEN OTHERS THEN
  RETURN FALSE;
END
$$;

-- ---------------------------------------------------------------------------
-- Constraints (added only when missing)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.add_constraint(tbl REGCLASS, cname TEXT, ddl TEXT) RETURNS VOID
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = tbl AND conname = cname) THEN
    EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I %s', tbl, cname, ddl);
  END IF;
END
$$;

-- settlements
SELECT pg_temp.add_constraint('clearledger.settlements', 'settlements_account_id_len',
  'CHECK (clearledger.trimlen(account_id) BETWEEN 3 AND 64)');
SELECT pg_temp.add_constraint('clearledger.settlements', 'settlements_reference_len',
  'CHECK (clearledger.trimlen(reference) BETWEEN 3 AND 64)');
SELECT pg_temp.add_constraint('clearledger.settlements', 'settlements_debit_party_len',
  'CHECK (clearledger.trimlen(debit_party) BETWEEN 2 AND 64)');
SELECT pg_temp.add_constraint('clearledger.settlements', 'settlements_credit_party_len',
  'CHECK (clearledger.trimlen(credit_party) BETWEEN 2 AND 64)');
SELECT pg_temp.add_constraint('clearledger.settlements', 'settlements_parties_differ',
  'CHECK (btrim(debit_party) <> btrim(credit_party))');
SELECT pg_temp.add_constraint('clearledger.settlements', 'settlements_status_allowed',
  $c$CHECK (current_status IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED'))$c$);
SELECT pg_temp.add_constraint('clearledger.settlements', 'settlements_stage_len',
  'CHECK (clearledger.trimlen(current_stage) BETWEEN 2 AND 64)');
SELECT pg_temp.add_constraint('clearledger.settlements', 'settlements_memo_len',
  'CHECK (last_memo IS NULL OR clearledger.trimlen(last_memo) BETWEEN 1 AND 256)');
SELECT pg_temp.add_constraint('clearledger.settlements', 'settlements_version_positive',
  'CHECK (version >= 1)');
SELECT pg_temp.add_constraint('clearledger.settlements', 'settlements_entry_count_nonneg',
  'CHECK (entry_count >= 0)');
SELECT pg_temp.add_constraint('clearledger.settlements', 'settlements_timestamps_monotonic',
  'CHECK (updated_at >= created_at)');
SELECT pg_temp.add_constraint('clearledger.settlements', 'settlements_version_shape',
  $c$CHECK (
    (version = 1 AND entry_count = 0 AND current_status = 'INITIATED'
       AND last_entry_id IS NULL AND updated_at = created_at)
    OR
    (version > 1 AND entry_count = version - 1 AND current_status <> 'INITIATED'
       AND last_entry_id IS NOT NULL)
  )$c$);

-- events
SELECT pg_temp.add_constraint('clearledger.events', 'events_event_id_key', 'UNIQUE (event_id)');
SELECT pg_temp.add_constraint('clearledger.events', 'events_settlement_fk',
  'FOREIGN KEY (settlement_id) REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE');
SELECT pg_temp.add_constraint('clearledger.events', 'events_settlement_version_key',
  'UNIQUE (settlement_id, aggregate_version)');
SELECT pg_temp.add_constraint('clearledger.events', 'events_settlement_idempotency_key',
  'UNIQUE (settlement_id, idempotency_key)');
SELECT pg_temp.add_constraint('clearledger.events', 'events_version_positive',
  'CHECK (aggregate_version >= 1)');
SELECT pg_temp.add_constraint('clearledger.events', 'events_type_allowed',
  $c$CHECK (event_type IN ('SettlementInitiated','LedgerEntryRecorded'))$c$);
SELECT pg_temp.add_constraint('clearledger.events', 'events_correlation_id_len',
  'CHECK (clearledger.trimlen(correlation_id) BETWEEN 4 AND 128)');
SELECT pg_temp.add_constraint('clearledger.events', 'events_idempotency_key_len',
  'CHECK (clearledger.trimlen(idempotency_key) BETWEEN 8 AND 128)');
SELECT pg_temp.add_constraint('clearledger.events', 'events_payload_envelope',
  'CHECK (clearledger.envelope_valid(payload))');
SELECT pg_temp.add_constraint('clearledger.events', 'events_payload_matches_columns',
  'CHECK (clearledger.envelope_matches(payload, event_id, settlement_id, aggregate_version, correlation_id, event_type, idempotency_key, occurred_at))');

-- outbox
SELECT pg_temp.add_constraint('clearledger.outbox', 'outbox_event_id_key', 'UNIQUE (event_id)');
SELECT pg_temp.add_constraint('clearledger.outbox', 'outbox_event_id_fk',
  'FOREIGN KEY (event_id) REFERENCES clearledger.events(event_id) ON DELETE CASCADE');
SELECT pg_temp.add_constraint('clearledger.outbox', 'outbox_settlement_fk',
  'FOREIGN KEY (settlement_id) REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE');
SELECT pg_temp.add_constraint('clearledger.outbox', 'outbox_settlement_version_key',
  'UNIQUE (settlement_id, aggregate_version)');
SELECT pg_temp.add_constraint('clearledger.outbox', 'outbox_event_version_fk',
  'FOREIGN KEY (settlement_id, aggregate_version) REFERENCES clearledger.events(settlement_id, aggregate_version) ON DELETE CASCADE');
SELECT pg_temp.add_constraint('clearledger.outbox', 'outbox_version_positive',
  'CHECK (aggregate_version >= 1)');
SELECT pg_temp.add_constraint('clearledger.outbox', 'outbox_correlation_id_len',
  'CHECK (clearledger.trimlen(correlation_id) BETWEEN 4 AND 128)');
SELECT pg_temp.add_constraint('clearledger.outbox', 'outbox_payload_envelope',
  'CHECK (clearledger.envelope_valid(payload))');
SELECT pg_temp.add_constraint('clearledger.outbox', 'outbox_payload_matches_columns',
  'CHECK (clearledger.envelope_matches(payload, event_id, settlement_id, aggregate_version, correlation_id, NULL, NULL, NULL))');
SELECT pg_temp.add_constraint('clearledger.outbox', 'outbox_attempts_nonneg',
  'CHECK (attempts >= 0)');
SELECT pg_temp.add_constraint('clearledger.outbox', 'outbox_published_lifecycle',
  'CHECK (published_at IS NULL OR (attempts >= 1 AND last_error IS NULL AND published_at >= created_at))');
SELECT pg_temp.add_constraint('clearledger.outbox', 'outbox_archived_lifecycle',
  'CHECK (archived_at IS NULL OR (published_at IS NOT NULL AND archived_at >= published_at))');

-- idempotency_keys
SELECT pg_temp.add_constraint('clearledger.idempotency_keys', 'idempotency_scope_format',
  $c$CHECK (scope ~* '^(create|entry):[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')$c$);
SELECT pg_temp.add_constraint('clearledger.idempotency_keys', 'idempotency_key_len',
  'CHECK (clearledger.trimlen(idempotency_key) BETWEEN 8 AND 128)');
SELECT pg_temp.add_constraint('clearledger.idempotency_keys', 'idempotency_request_hash_format',
  $c$CHECK (request_hash ~ '^[0-9a-f]{64}$')$c$);
SELECT pg_temp.add_constraint('clearledger.idempotency_keys', 'idempotency_response_body_valid',
  'CHECK (clearledger.idempotency_body_valid(response_body))');
SELECT pg_temp.add_constraint('clearledger.idempotency_keys', 'idempotency_status_scope_coupling',
  $c$CHECK (
    (scope LIKE 'create:%' AND status_code = 201 AND (response_body->>'version')::INTEGER = 1)
    OR
    (scope LIKE 'entry:%' AND status_code = 202 AND (response_body->>'version')::INTEGER >= 2)
  )$c$);

-- ---------------------------------------------------------------------------
-- Trigger functions
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION clearledger.trg_settlements_before_update() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.settlement_id IS DISTINCT FROM OLD.settlement_id
     OR NEW.account_id IS DISTINCT FROM OLD.account_id
     OR NEW.reference IS DISTINCT FROM OLD.reference
     OR NEW.debit_party IS DISTINCT FROM OLD.debit_party
     OR NEW.credit_party IS DISTINCT FROM OLD.credit_party
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'settlement header columns are immutable' USING ERRCODE = 'P0001';
  END IF;
  IF OLD.current_status = 'RECONCILED' THEN
    RAISE EXCEPTION 'settlement % is RECONCILED and terminal', OLD.settlement_id USING ERRCODE = 'P0001';
  END IF;
  IF NEW.version <> OLD.version + 1 THEN
    RAISE EXCEPTION 'settlement version must advance by exactly 1 (% -> %)', OLD.version, NEW.version USING ERRCODE = 'P0001';
  END IF;
  IF NEW.entry_count <> OLD.entry_count + 1 THEN
    RAISE EXCEPTION 'settlement entry_count must advance by exactly 1' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.last_entry_id IS NOT DISTINCT FROM OLD.last_entry_id THEN
    RAISE EXCEPTION 'settlement update requires a new last_entry_id' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.updated_at < OLD.updated_at THEN
    RAISE EXCEPTION 'settlement updated_at must be monotonic' USING ERRCODE = 'P0001';
  END IF;
  IF NOT clearledger.status_transition_ok(OLD.current_status, NEW.current_status) THEN
    RAISE EXCEPTION 'illegal settlement status transition % -> %', OLD.current_status, NEW.current_status USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.trg_events_before_insert() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
  s clearledger.settlements%ROWTYPE;
  d JSONB := NEW.payload->'data';
  prev clearledger.events%ROWTYPE;
  max_v INTEGER;
BEGIN
  SELECT COALESCE(MAX(aggregate_version), 0) INTO max_v FROM clearledger.events WHERE settlement_id = NEW.settlement_id;
  IF NEW.aggregate_version <> max_v + 1 THEN
    RAISE EXCEPTION 'event aggregate_version must be contiguous (expected %, got %)', max_v + 1, NEW.aggregate_version USING ERRCODE = 'P0001';
  END IF;

  IF NEW.aggregate_version >= 2 AND EXISTS (
       SELECT 1 FROM clearledger.events e
        WHERE e.settlement_id = NEW.settlement_id
          AND e.event_type = 'LedgerEntryRecorded'
          AND e.payload->'data'->>'entryId' = d->>'entryId') THEN
    RAISE EXCEPTION 'entryId % already recorded for settlement %', d->>'entryId', NEW.settlement_id USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO s FROM clearledger.settlements WHERE settlement_id = NEW.settlement_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'settlement % not found for event', NEW.settlement_id USING ERRCODE = 'P0001';
  END IF;
  IF d->>'accountId' IS DISTINCT FROM s.account_id
     OR d->>'reference' IS DISTINCT FROM s.reference
     OR d->>'debitParty' IS DISTINCT FROM s.debit_party
     OR d->>'creditParty' IS DISTINCT FROM s.credit_party
     OR d->>'status' IS DISTINCT FROM s.current_status
     OR d->>'clearingStage' IS DISTINCT FROM s.current_stage
     OR (d->>'entryId') IS DISTINCT FROM (s.last_entry_id::TEXT)
     OR (d->>'memo') IS DISTINCT FROM s.last_memo
     OR NEW.aggregate_version <> s.version
     OR NEW.occurred_at <> s.updated_at THEN
    RAISE EXCEPTION 'event does not match settlement row %', NEW.settlement_id USING ERRCODE = 'P0001';
  END IF;
  IF NEW.aggregate_version = 1 AND NEW.occurred_at <> s.created_at THEN
    RAISE EXCEPTION 'initial event occurred_at must equal settlement created_at' USING ERRCODE = 'P0001';
  END IF;

  IF NEW.aggregate_version >= 2 THEN
    SELECT * INTO prev FROM clearledger.events
     WHERE settlement_id = NEW.settlement_id AND aggregate_version = NEW.aggregate_version - 1;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'previous event missing for settlement %', NEW.settlement_id USING ERRCODE = 'P0001';
    END IF;
    IF NEW.occurred_at < prev.occurred_at THEN
      RAISE EXCEPTION 'event occurred_at must not precede previous event' USING ERRCODE = 'P0001';
    END IF;
    IF NOT clearledger.status_transition_ok(prev.payload->'data'->>'status', d->>'status') THEN
      RAISE EXCEPTION 'illegal event status transition % -> %', prev.payload->'data'->>'status', d->>'status' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.trg_reject_mutation() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '% on %.% is not permitted (append-only)', TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME USING ERRCODE = 'P0001';
END
$$;

CREATE OR REPLACE FUNCTION clearledger.trg_outbox_before_insert() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
  ev_payload JSONB;
  max_v INTEGER;
BEGIN
  SELECT payload INTO ev_payload FROM clearledger.events
   WHERE event_id = NEW.event_id AND settlement_id = NEW.settlement_id AND aggregate_version = NEW.aggregate_version;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'outbox row has no matching event' USING ERRCODE = 'P0001';
  END IF;
  IF ev_payload IS DISTINCT FROM NEW.payload THEN
    RAISE EXCEPTION 'outbox payload must mirror the event payload' USING ERRCODE = 'P0001';
  END IF;
  SELECT COALESCE(MAX(aggregate_version), 0) INTO max_v FROM clearledger.outbox WHERE settlement_id = NEW.settlement_id;
  IF NEW.aggregate_version <> max_v + 1 THEN
    RAISE EXCEPTION 'outbox aggregate_version must be contiguous (expected %, got %)', max_v + 1, NEW.aggregate_version USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.trg_outbox_before_update() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.seq IS DISTINCT FROM OLD.seq
     OR NEW.event_id IS DISTINCT FROM OLD.event_id
     OR NEW.settlement_id IS DISTINCT FROM OLD.settlement_id
     OR NEW.aggregate_version IS DISTINCT FROM OLD.aggregate_version
     OR NEW.correlation_id IS DISTINCT FROM OLD.correlation_id
     OR NEW.payload IS DISTINCT FROM OLD.payload
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'outbox envelope columns are immutable' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.attempts < OLD.attempts THEN
    RAISE EXCEPTION 'outbox attempts cannot decrease' USING ERRCODE = 'P0001';
  END IF;
  IF OLD.published_at IS NULL AND NEW.published_at IS NOT NULL THEN
    IF NEW.attempts <= OLD.attempts OR NEW.archived_at IS NOT NULL THEN
      RAISE EXCEPTION 'publishing requires attempts increment and no archived_at' USING ERRCODE = 'P0001';
    END IF;
  ELSIF OLD.published_at IS NOT NULL AND NEW.published_at IS NOT NULL THEN
    IF NEW.published_at IS DISTINCT FROM OLD.published_at
       OR NEW.attempts IS DISTINCT FROM OLD.attempts
       OR NEW.last_error IS DISTINCT FROM OLD.last_error THEN
      RAISE EXCEPTION 'published outbox rows cannot change published_at/attempts/last_error' USING ERRCODE = 'P0001';
    END IF;
    IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NOT NULL
       AND NEW.archived_at IS DISTINCT FROM OLD.archived_at THEN
      RAISE EXCEPTION 'archived_at cannot change without being reset first' USING ERRCODE = 'P0001';
    END IF;
  ELSIF OLD.published_at IS NOT NULL AND NEW.published_at IS NULL THEN
    IF NEW.archived_at IS NOT NULL THEN
      RAISE EXCEPTION 'resetting published_at requires archived_at = NULL' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.trg_idempotency_before_insert() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
  b JSONB := NEW.response_body;
BEGIN
  IF split_part(NEW.scope, ':', 2) <> lower(b->>'settlementId') THEN
    RAISE EXCEPTION 'idempotency scope does not match response settlementId' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM clearledger.events e
                  WHERE e.event_id = (b->>'eventId')::UUID
                    AND e.settlement_id = (b->>'settlementId')::UUID
                    AND e.aggregate_version = (b->>'version')::INTEGER
                    AND e.idempotency_key = NEW.idempotency_key) THEN
    RAISE EXCEPTION 'idempotency key references a missing event' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM clearledger.outbox o
                  WHERE o.event_id = (b->>'eventId')::UUID
                    AND o.settlement_id = (b->>'settlementId')::UUID
                    AND o.aggregate_version = (b->>'version')::INTEGER) THEN
    RAISE EXCEPTION 'idempotency key references a missing outbox row' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END
$$;

-- ---------------------------------------------------------------------------
-- Triggers (created when missing; re-enabled when disabled out-of-band)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.ensure_trigger(tbl REGCLASS, tname TEXT, ddl TEXT) RETURNS VOID
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = tbl AND tgname = tname AND NOT tgisinternal) THEN
    EXECUTE format('CREATE TRIGGER %I %s', tname, ddl);
  END IF;
  IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = tbl AND tgname = tname AND tgenabled <> 'O') THEN
    EXECUTE format('ALTER TABLE %s ENABLE TRIGGER %I', tbl, tname);
  END IF;
END
$$;

SELECT pg_temp.ensure_trigger('clearledger.settlements', 'trg_settlements_before_update',
  'BEFORE UPDATE ON clearledger.settlements FOR EACH ROW EXECUTE FUNCTION clearledger.trg_settlements_before_update()');
SELECT pg_temp.ensure_trigger('clearledger.events', 'trg_events_before_insert',
  'BEFORE INSERT ON clearledger.events FOR EACH ROW EXECUTE FUNCTION clearledger.trg_events_before_insert()');
SELECT pg_temp.ensure_trigger('clearledger.events', 'trg_events_append_only',
  'BEFORE UPDATE OR DELETE ON clearledger.events FOR EACH ROW EXECUTE FUNCTION clearledger.trg_reject_mutation()');
SELECT pg_temp.ensure_trigger('clearledger.outbox', 'trg_outbox_before_insert',
  'BEFORE INSERT ON clearledger.outbox FOR EACH ROW EXECUTE FUNCTION clearledger.trg_outbox_before_insert()');
SELECT pg_temp.ensure_trigger('clearledger.outbox', 'trg_outbox_before_update',
  'BEFORE UPDATE ON clearledger.outbox FOR EACH ROW EXECUTE FUNCTION clearledger.trg_outbox_before_update()');
SELECT pg_temp.ensure_trigger('clearledger.outbox', 'trg_outbox_no_delete',
  'BEFORE DELETE ON clearledger.outbox FOR EACH ROW EXECUTE FUNCTION clearledger.trg_reject_mutation()');
SELECT pg_temp.ensure_trigger('clearledger.idempotency_keys', 'trg_idempotency_before_insert',
  'BEFORE INSERT ON clearledger.idempotency_keys FOR EACH ROW EXECUTE FUNCTION clearledger.trg_idempotency_before_insert()');
SELECT pg_temp.ensure_trigger('clearledger.idempotency_keys', 'trg_idempotency_immutable',
  'BEFORE UPDATE OR DELETE ON clearledger.idempotency_keys FOR EACH ROW EXECUTE FUNCTION clearledger.trg_reject_mutation()');

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_clearledger_outbox_unpublished
  ON clearledger.outbox (seq) WHERE published_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_clearledger_outbox_unarchived
  ON clearledger.outbox (seq) WHERE published_at IS NOT NULL AND archived_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_clearledger_events_settlement_version
  ON clearledger.events (settlement_id, aggregate_version);
CLSQL

export PGPASSWORD="$DB_PASS" PGCONNECT_TIMEOUT=10 PGOPTIONS="-c client_min_messages=warning"
log "waiting for PostgreSQL at ${DB_HOST}:${DB_PORT}"
ready=0
for _ in $(seq 1 60); do
  if psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -qAt -c 'select 1' >/dev/null 2>&1; then ready=1; break; fi
  sleep 3
done
[ "$ready" = 1 ] || die "PostgreSQL did not become reachable"

log "applying clearledger schema"
applied=0
for attempt in 1 2 3 4 5; do
  if psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -1 -q -o /dev/null -f "$SCHEMA_FILE"; then
    applied=1; break
  fi
  log "schema attempt $attempt failed; retrying"; sleep 5
done
[ "$applied" = 1 ] || die "schema migration failed"

# ---------------------------------------------------------------------------
# 3. Manifest validation
# ---------------------------------------------------------------------------
"$PYTHON" - "$MANIFEST_FILE" /workspace/contracts/schemas/manifest.schema.json <<'PYEOF' || die "manifest does not match schema"
import json, sys
try:
    import jsonschema
except ImportError:
    print("jsonschema not installed; skipping manifest validation"); sys.exit(0)
m, s = json.load(open(sys.argv[1])), None
try:
    s = json.load(open(sys.argv[2]))
except FileNotFoundError:
    print("manifest schema not found; skipping validation"); sys.exit(0)
jsonschema.validate(m, s)
print("manifest.json valid")
PYEOF

# ---------------------------------------------------------------------------
# 4. Wait for the API
# ---------------------------------------------------------------------------
wait_ready() {
  local timeout="$1" deadline code
  deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    code="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "${SERVICE_URL}/health/ready" || true)"
    [ "$code" = "200" ] && return 0
    sleep 3
  done
  return 1
}

log "waiting for ${SERVICE_URL}/health/ready"
wait_ready 300 || die "API did not become ready"

# ---------------------------------------------------------------------------
# 5. Control-plane drift not visible to Terraform
# ---------------------------------------------------------------------------
cat >"$WORK/drift.py" <<'PYEOF'
#!/usr/bin/env python3
"""Remove out-of-band IAM policy attachments and security-group rules."""
import json
import sys
import time

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

CONFIG_FILE, MANIFEST_FILE = sys.argv[1], sys.argv[2]
cfg = json.load(open(CONFIG_FILE))
man = json.load(open(MANIFEST_FILE))
PREFIX = cfg["resource_prefix"]
BCFG = Config(retries={"max_attempts": 8, "mode": "standard"})


def client(name):
    return boto3.client(name, endpoint_url=cfg["aws_endpoint_url"], region_name=cfg["region"],
                        aws_access_key_id="test", aws_secret_access_key="test", config=BCFG)


iam, ec2 = client("iam"), client("ec2")


def log(msg):
    print("[drift %s] %s" % (time.strftime("%H:%M:%S"), msg), flush=True)


def ignore_missing(fn, *a, **kw):
    try:
        return fn(*a, **kw)
    except ClientError as exc:
        if exc.response["Error"]["Code"] in ("NoSuchEntity", "NoSuchEntityException", "NotFound"):
            return None
        raise


def delete_policy_fully(arn):
    ents = iam.list_entities_for_policy(PolicyArn=arn)
    for r in ents.get("PolicyRoles", []):
        ignore_missing(iam.detach_role_policy, RoleName=r["RoleName"], PolicyArn=arn)
    for u in ents.get("PolicyUsers", []):
        ignore_missing(iam.detach_user_policy, UserName=u["UserName"], PolicyArn=arn)
    for g in ents.get("PolicyGroups", []):
        ignore_missing(iam.detach_group_policy, GroupName=g["GroupName"], PolicyArn=arn)
    for v in iam.list_policy_versions(PolicyArn=arn).get("Versions", []):
        if not v["IsDefaultVersion"]:
            ignore_missing(iam.delete_policy_version, PolicyArn=arn, VersionId=v["VersionId"])
    ignore_missing(iam.delete_policy, PolicyArn=arn)


def sweep_roles():
    role_arns = man["iam"]
    for key, arn in role_arns.items():
        role = arn.split("/")[-1]
        canonical = role  # inline policy is named after the role
        names = ignore_missing(iam.list_role_policies, RoleName=role)
        if names is None:
            log("role %s missing (terraform recreates it)" % role)
            continue
        for name in names.get("PolicyNames", []):
            if name != canonical:
                log("deleting out-of-band inline policy %s on %s" % (name, role))
                ignore_missing(iam.delete_role_policy, RoleName=role, PolicyName=name)
        for pol in iam.list_attached_role_policies(RoleName=role).get("AttachedPolicies", []):
            log("detaching out-of-band policy %s from %s" % (pol["PolicyArn"], role))
            ignore_missing(iam.detach_role_policy, RoleName=role, PolicyArn=pol["PolicyArn"])
    # detached (or now-detached) customer-managed policies carrying the prefix
    paginator = iam.get_paginator("list_policies")
    for page in paginator.paginate(Scope="Local"):
        for pol in page["Policies"]:
            if pol["PolicyName"].startswith(PREFIX):
                log("deleting customer-managed policy %s" % pol["PolicyName"])
                delete_policy_fully(pol["Arn"])


def unrestricted(perm):
    if perm.get("IpProtocol") == "-1":
        return True
    return any(r.get("CidrIp") == "0.0.0.0/0" for r in perm.get("IpRanges", [])) or \
        any(r.get("CidrIpv6") == "::/0" for r in perm.get("Ipv6Ranges", []))


def sweep_security_groups():
    ids = man["network"]["security_group_ids"]
    groups = {g["GroupId"]: g for g in ec2.describe_security_groups(GroupIds=list(ids.values()))["SecurityGroups"]}
    for name in ("rds", "valkey"):
        g = groups.get(ids[name])
        if g and g.get("IpPermissionsEgress"):
            log("revoking %d egress rules on %s security group" % (len(g["IpPermissionsEgress"]), name))
            ec2.revoke_security_group_egress(GroupId=g["GroupId"], IpPermissions=g["IpPermissionsEgress"])
    g = groups.get(ids["alb"])
    if g:
        bad = [p for p in g.get("IpPermissionsEgress", []) if unrestricted(p)]
        if bad:
            log("revoking %d unrestricted egress rules on alb security group" % len(bad))
            ec2.revoke_security_group_egress(GroupId=g["GroupId"], IpPermissions=bad)


sweep_roles()
sweep_security_groups()
log("iam and security group drift sweep complete")
PYEOF
"$PYTHON" "$WORK/drift.py" "$CONFIG_FILE" "$MANIFEST_FILE" || die "drift sweep failed"

# ---------------------------------------------------------------------------
# 6. Data-plane convergence (PostgreSQL is authoritative)
# ---------------------------------------------------------------------------
cat >"$WORK/reconcile.py" <<'PYEOF'
#!/usr/bin/env python3
"""ClearLedger data-plane convergence.

PostgreSQL is the system of record. This script drains the outbox through the
relay Lambda, waits for the projector to consume the queue, then converges
DynamoDB, the versioned S3 audit archive and Valkey 1-to-1 against PostgreSQL.
"""
import concurrent.futures as cf
import datetime as dt
import hashlib
import json
import re
import sys
import time

import boto3
import psycopg2
import redis
from botocore.config import Config
from botocore.exceptions import ClientError

CONFIG_FILE, MANIFEST_FILE = sys.argv[1], sys.argv[2]
cfg = json.load(open(CONFIG_FILE))
man = json.load(open(MANIFEST_FILE))

ENDPOINT = cfg["aws_endpoint_url"]
REGION = cfg["region"]
BCFG = Config(retries={"max_attempts": 8, "mode": "standard"}, max_pool_connections=32)


def client(name):
    return boto3.client(name, endpoint_url=ENDPOINT, region_name=REGION,
                        aws_access_key_id="test", aws_secret_access_key="test", config=BCFG)


lam, sqs, ddb, s3 = client("lambda"), client("sqs"), client("dynamodb"), client("s3")

TABLE = man["projections"]["table_name"]
BUCKET = man["audit"]["bucket_name"]
PREFIX = man["audit"]["prefix"]
QUEUE_URL = man["messaging"]["queue_url"]
RELAY_FN = man["workers"]["outbox_relay"]["function_name"]
ARCHIVER_FN = man["workers"]["audit_archiver"]["function_name"]
VALKEY_HOST, VALKEY_PORT = man["cache"]["endpoint"], man["cache"]["port"]
CACHE_TTL = 90


def log(msg):
    print("[reconcile %s] %s" % (time.strftime("%H:%M:%S"), msg), flush=True)


def pg_connect(retries=30):
    last = None
    for _ in range(retries):
        try:
            c = psycopg2.connect(host=man["database"]["endpoint"], port=man["database"]["port"],
                                 user=cfg["db_username"], password=cfg["db_password"],
                                 dbname=cfg["db_name"], connect_timeout=10,
                                 options="-c timezone=UTC")
            c.autocommit = True
            return c
        except Exception as exc:  # noqa: BLE001
            last = exc
            time.sleep(2)
    raise RuntimeError("cannot connect to PostgreSQL: %s" % last)


def q(sql, args=None):
    c = pg_connect()
    try:
        with c.cursor() as cur:
            cur.execute(sql, args)
            return cur.fetchall() if cur.description else cur.rowcount
    finally:
        c.close()


# --------------------------------------------------------------------------
# formatting helpers (mirror the formats written by the workers)
# --------------------------------------------------------------------------
def py_iso(ts):
    """Projector format: Python datetime.isoformat() in UTC."""
    return ts.astimezone(dt.timezone.utc).isoformat()


def api_iso(ts):
    """API/cache format: RFC3339 'Z' with 0/3/6 fractional digits."""
    u = ts.astimezone(dt.timezone.utc)
    base = u.strftime("%Y-%m-%dT%H:%M:%S")
    if u.microsecond == 0:
        return base + "Z"
    if u.microsecond % 1000 == 0:
        return "%s.%03dZ" % (base, u.microsecond // 1000)
    return "%s.%06dZ" % (base, u.microsecond)


ENV_ORDER = ["schemaVersion", "eventId", "eventType", "aggregateType", "aggregateId",
             "aggregateVersion", "occurredAt", "correlationId", "idempotencyKey", "data"]
DATA_ORDER = ["kind", "accountId", "reference", "debitParty", "creditParty", "entryId",
              "status", "clearingStage", "memo"]


def ordered(d, order):
    out = {k: d[k] for k in order if k in d}
    out.update({k: v for k, v in d.items() if k not in out})
    return out


def envelope_json(payload):
    p = ordered(payload, ENV_ORDER)
    if isinstance(p.get("data"), dict):
        p["data"] = ordered(p["data"], DATA_ORDER)
    return json.dumps(p, separators=(",", ":"), ensure_ascii=False)


def S(v):
    return {"S": v}


def N(v):
    return {"N": str(v)}


# --------------------------------------------------------------------------
# authoritative state
# --------------------------------------------------------------------------
def load_settlements(only=None):
    sql = ("SELECT settlement_id::text, account_id, reference, debit_party, credit_party, current_status,"
           " current_stage, last_entry_id::text, last_memo, version, entry_count, updated_at"
           " FROM clearledger.settlements")
    args = None
    if only:
        sql += " WHERE settlement_id = %s::uuid"
        args = (only,)
    return q(sql, args)


def load_events():
    return q("SELECT settlement_id::text, aggregate_version, event_id::text, event_type, correlation_id,"
             " occurred_at, payload FROM clearledger.events ORDER BY settlement_id, aggregate_version")


def expected_state_item(r):
    (sid, account, ref, debit, credit, status, stage, last_entry, last_memo, version, entry_count, updated) = r
    item = {
        "PK": S("SETTLEMENT#" + sid), "SK": S("STATE"),
        "GSI1PK": S("ACCOUNT#" + account), "GSI1SK": S("SETTLEMENT#" + sid),
        "settlement_id": S(sid), "account_id": S(account), "reference": S(ref),
        "debit_party": S(debit), "credit_party": S(credit),
        "status": S(status), "clearing_stage": S(stage),
        "version": N(version), "entry_count": N(entry_count), "updated_at": S(py_iso(updated)),
    }
    if last_entry is not None:
        item["last_entry_id"] = S(last_entry)
    if last_memo is not None:
        item["last_memo"] = S(last_memo)
    return item


def expected_event_item(r):
    (sid, version, event_id, event_type, corr, occurred, payload) = r
    data = payload.get("data", {})
    item = {
        "PK": S("SETTLEMENT#" + sid), "SK": S("EVENT#%08d" % version),
        "settlement_id": S(sid), "event_id": S(event_id), "version": N(version),
        "event_type": S(event_type), "status": S(data.get("status")),
        "clearing_stage": S(data.get("clearingStage")), "occurred_at": S(py_iso(occurred)),
        "correlation_id": S(corr), "envelope": S(envelope_json(payload)),
    }
    if data.get("entryId") is not None:
        item["entry_id"] = S(data["entryId"])
    if data.get("memo") is not None:
        item["memo"] = S(data["memo"])
    return item


def same_item(exp, act):
    if set(exp) != set(act):
        return False
    for k, v in exp.items():
        if k == "envelope":
            try:
                if json.loads(v["S"]) != json.loads(act[k]["S"]):
                    return False
            except Exception:  # noqa: BLE001
                return False
        elif v != act[k]:
            return False
    return True


# --------------------------------------------------------------------------
# step 1: relay drain
# --------------------------------------------------------------------------
def drain_outbox(timeout=180):
    deadline = time.time() + timeout
    while True:
        pending = q("SELECT count(*) FROM clearledger.outbox WHERE published_at IS NULL")[0][0]
        if pending == 0:
            log("outbox fully published")
            return
        if time.time() > deadline:
            raise RuntimeError("outbox still has %d unpublished rows after %ds" % (pending, timeout))
        log("relaying %d unpublished outbox rows" % pending)
        try:
            r = lam.invoke(FunctionName=RELAY_FN, Payload=b"{}")
            body = r["Payload"].read().decode("utf-8", "replace")
            if r.get("FunctionError"):
                log("relay function error: %s" % body[:300])
                time.sleep(3)
            else:
                try:
                    published = json.loads(body).get("published", 0)
                except Exception:  # noqa: BLE001
                    published = 0
                if not published:
                    time.sleep(2)
        except ClientError as exc:
            log("relay invoke failed: %s" % exc)
            time.sleep(3)


# --------------------------------------------------------------------------
# step 2: wait for the projector to consume the main queue
# --------------------------------------------------------------------------
def wait_queue_empty(timeout=90):
    deadline = time.time() + timeout
    quiet = 0
    while time.time() < deadline:
        try:
            a = sqs.get_queue_attributes(QueueUrl=QUEUE_URL, AttributeNames=[
                "ApproximateNumberOfMessages", "ApproximateNumberOfMessagesNotVisible",
                "ApproximateNumberOfMessagesDelayed"])["Attributes"]
            total = sum(int(v) for v in a.values())
        except ClientError as exc:
            log("queue attributes unavailable: %s" % exc)
            total = -1
        if total == 0:
            quiet += 1
            if quiet >= 3:
                log("main queue drained")
                return
        else:
            quiet = 0
        time.sleep(2)
    log("WARNING: main queue not empty after %ds; continuing with direct reconciliation" % timeout)


# --------------------------------------------------------------------------
# step 3: DynamoDB reconciliation
# --------------------------------------------------------------------------
def scan_table():
    items = []
    kwargs = {"TableName": TABLE, "ConsistentRead": True}
    while True:
        r = ddb.scan(**kwargs)
        items.extend(r.get("Items", []))
        if "LastEvaluatedKey" not in r:
            return items
        kwargs["ExclusiveStartKey"] = r["LastEvaluatedKey"]


def batch_write(requests):
    for i in range(0, len(requests), 25):
        chunk = requests[i:i + 25]
        for attempt in range(8):
            r = ddb.batch_write_item(RequestItems={TABLE: chunk})
            chunk = r.get("UnprocessedItems", {}).get(TABLE, [])
            if not chunk:
                break
            time.sleep(0.2 * (attempt + 1))
        else:
            raise RuntimeError("DynamoDB batch write kept returning unprocessed items")


def put_state(item, sid):
    cond = {"ConditionExpression": "attribute_not_exists(PK) OR #v <= :v",
            "ExpressionAttributeNames": {"#v": "version"},
            "ExpressionAttributeValues": {":v": item["version"]}}
    for attempt in range(3):
        try:
            ddb.put_item(TableName=TABLE, Item=item, **cond)
            return
        except ClientError as exc:
            if exc.response["Error"]["Code"] != "ConditionalCheckFailedException":
                raise
            # Stored version is ahead of what we read: either a newer event landed
            # concurrently, or the stored item is corrupt (ahead of PostgreSQL).
            rows = load_settlements(sid)
            if not rows:
                return
            fresh = expected_state_item(rows[0])
            stored = ddb.get_item(TableName=TABLE, Key={"PK": item["PK"], "SK": item["SK"]},
                                  ConsistentRead=True).get("Item")
            if stored and int(stored["version"]["N"]) > int(fresh["version"]["N"]):
                ddb.put_item(TableName=TABLE, Item=fresh)
                return
            item = fresh
            cond["ExpressionAttributeValues"] = {":v": item["version"]}
    log("WARNING: could not converge STATE for %s" % sid)


def reconcile_dynamodb():
    settlements = load_settlements()
    events = load_events()
    expected = {}
    for r in settlements:
        it = expected_state_item(r)
        expected[(it["PK"]["S"], it["SK"]["S"])] = it
    known = {r[0] for r in settlements}
    for r in events:
        if r[0] not in known:
            continue
        it = expected_event_item(r)
        expected[(it["PK"]["S"], it["SK"]["S"])] = it

    actual = {}
    for it in scan_table():
        actual[(it.get("PK", {}).get("S"), it.get("SK", {}).get("S"))] = it

    deletes, event_puts, state_puts = [], [], []
    for key, act in actual.items():
        if key not in expected:
            if None in key:
                continue
            deletes.append({"DeleteRequest": {"Key": {"PK": S(key[0]), "SK": S(key[1])}}})
    for key, exp in expected.items():
        act = actual.get(key)
        if act is not None and same_item(exp, act):
            continue
        if key[1] == "STATE":
            state_puts.append(exp)
        else:
            event_puts.append({"PutRequest": {"Item": exp}})

    log("dynamodb: %d expected items, %d stray deletes, %d event writes, %d state writes"
        % (len(expected), len(deletes), len(event_puts), len(state_puts)))
    batch_write(deletes)
    batch_write(event_puts)
    if state_puts:
        with cf.ThreadPoolExecutor(8) as ex:
            list(ex.map(lambda it: put_state(it, it["settlement_id"]["S"]), state_puts))

    # verification pass
    bad = 0
    expected_after = {}
    for r in load_settlements():
        it = expected_state_item(r)
        expected_after[(it["PK"]["S"], it["SK"]["S"])] = it
    actual_after = {(i["PK"]["S"], i["SK"]["S"]): i for i in scan_table()}
    for key, exp in expected_after.items():
        if key not in actual_after or not same_item(exp, actual_after[key]):
            bad += 1
    log("dynamodb verification: %d STATE items still differ (live writes may explain small numbers)" % bad)


# --------------------------------------------------------------------------
# step 4: S3 audit archive
# --------------------------------------------------------------------------
BATCH_RE = re.compile(r"^" + re.escape(PREFIX) + r"batch-(\d{8})-(\d{8})-([0-9a-f]{16})\.ndjson$")


def list_all_versions():
    versions, markers = [], []
    kwargs = {"Bucket": BUCKET}
    while True:
        r = s3.list_object_versions(**kwargs)
        versions.extend(r.get("Versions", []))
        markers.extend(r.get("DeleteMarkers", []))
        if not r.get("IsTruncated"):
            return versions, markers
        kwargs["KeyMarker"] = r.get("NextKeyMarker")
        kwargs["VersionIdMarker"] = r.get("NextVersionIdMarker")


def delete_versions(objs):
    objs = list(objs)
    for i in range(0, len(objs), 500):
        chunk = [{"Key": o["Key"], "VersionId": o["VersionId"]} for o in objs[i:i + 500]]
        r = s3.delete_objects(Bucket=BUCKET, Delete={"Objects": chunk, "Quiet": True})
        if r.get("Errors"):
            raise RuntimeError("S3 delete errors: %s" % r["Errors"][:3])


def s3_consistent():
    """True when S3 batches mirror exactly the archived outbox rows."""
    versions, markers = list_all_versions()
    latest_markers = [m for m in markers if m["IsLatest"]]
    if latest_markers:
        return False, "latest delete markers present"
    current = [v for v in versions if v["IsLatest"]]
    if any(not v["Key"].startswith(PREFIX) for v in versions + markers):
        return False, "objects outside %s" % PREFIX
    rows = q("SELECT seq, event_id::text, payload, published_at IS NOT NULL, archived_at IS NOT NULL"
             " FROM clearledger.outbox ORDER BY seq")
    by_event = {r[1]: r for r in rows}
    archived = {r[0] for r in rows if r[4]}
    covered, ranges = set(), []
    for v in current:
        m = BATCH_RE.match(v["Key"])
        if not m:
            return False, "non-canonical key %s" % v["Key"]
        first, last, digest = int(m.group(1)), int(m.group(2)), m.group(3)
        body = s3.get_object(Bucket=BUCKET, Key=v["Key"], VersionId=v["VersionId"])["Body"].read()
        if hashlib.sha256(body).hexdigest()[:16] != digest:
            return False, "digest mismatch for %s" % v["Key"]
        lines = body.decode("utf-8").split("\n")
        if lines and lines[-1] == "":
            lines.pop()
        seqs = []
        for line in lines:
            try:
                env = json.loads(line)
            except Exception:  # noqa: BLE001
                return False, "unparseable line in %s" % v["Key"]
            row = by_event.get(env.get("eventId"))
            if row is None or row[2] != env:
                return False, "line in %s does not match outbox" % v["Key"]
            seqs.append(row[0])
        if seqs != list(range(first, last + 1)):
            return False, "%s is not a contiguous ascending slice" % v["Key"]
        if covered & set(seqs):
            return False, "overlapping batches"
        covered |= set(seqs)
        ranges.append((first, last))
    if covered != archived:
        return False, "coverage mismatch (s3=%d archived=%d)" % (len(covered), len(archived))
    return True, "ok (%d batches, %d events)" % (len(current), len(covered))


def run_archiver(timeout=240):
    deadline = time.time() + timeout
    while True:
        left = q("SELECT count(*) FROM clearledger.outbox WHERE published_at IS NOT NULL AND archived_at IS NULL")[0][0]
        if left == 0:
            return
        if time.time() > deadline:
            raise RuntimeError("%d outbox rows still unarchived after %ds" % (left, timeout))
        try:
            r = lam.invoke(FunctionName=ARCHIVER_FN, Payload=b"{}")
            body = r["Payload"].read().decode("utf-8", "replace")
            if r.get("FunctionError"):
                log("archiver function error: %s" % body[:300])
                time.sleep(3)
                continue
            if not json.loads(body).get("archived"):
                time.sleep(2)
        except ClientError as exc:
            log("archiver invoke failed: %s" % exc)
            time.sleep(3)


def purge_noncurrent():
    versions, markers = list_all_versions()
    doomed = [v for v in versions if not v["IsLatest"]] + markers
    if doomed:
        log("s3: purging %d noncurrent versions/delete markers" % len(doomed))
        delete_versions(doomed)


def reconcile_s3():
    ok, why = s3_consistent()
    if ok:
        log("s3 archive consistent: %s" % why)
    else:
        log("s3 archive inconsistent (%s); rebuilding from PostgreSQL" % why)
        versions, markers = list_all_versions()
        delete_versions(versions + markers)
        n = q("UPDATE clearledger.outbox SET archived_at = NULL WHERE archived_at IS NOT NULL")
        log("s3: reset archived_at on %d rows" % n)
    run_archiver()
    purge_noncurrent()
    ok, why = s3_consistent()
    if not ok:
        # one more rebuild attempt before giving up
        log("s3 archive still inconsistent (%s); second rebuild" % why)
        versions, markers = list_all_versions()
        delete_versions(versions + markers)
        q("UPDATE clearledger.outbox SET archived_at = NULL WHERE archived_at IS NOT NULL")
        run_archiver()
        purge_noncurrent()
        ok, why = s3_consistent()
        if not ok:
            raise RuntimeError("S3 audit archive failed to converge: %s" % why)
    log("s3 archive verified: %s" % why)


# --------------------------------------------------------------------------
# step 5: Valkey
# --------------------------------------------------------------------------
def cache_payload(r):
    (sid, account, ref, debit, credit, status, stage, last_entry, last_memo, version, entry_count, updated) = r
    d = {"settlementId": sid, "accountId": account, "reference": ref, "debitParty": debit,
         "creditParty": credit, "status": status, "clearingStage": stage}
    if last_entry is not None:
        d["lastEntryId"] = last_entry
    if last_memo is not None:
        d["lastMemo"] = last_memo
    d.update({"version": version, "entryCount": entry_count, "updatedAt": api_iso(updated)})
    return json.dumps(d, separators=(",", ":"), ensure_ascii=False)


def reconcile_valkey():
    rows = load_settlements()
    expected = {"clearledger:settlement:" + r[0]: cache_payload(r) for r in rows}
    last = None
    for _ in range(30):
        try:
            r0 = redis.Redis(host=VALKEY_HOST, port=VALKEY_PORT, db=0, decode_responses=True,
                             socket_timeout=10, socket_connect_timeout=10)
            r0.ping()
            break
        except Exception as exc:  # noqa: BLE001
            last = exc
            time.sleep(2)
    else:
        raise RuntimeError("cannot reach Valkey: %s" % last)

    # purge other logical databases entirely
    for name, _info in r0.info("keyspace").items():
        idx = int(name[2:])
        if idx != 0:
            redis.Redis(host=VALKEY_HOST, port=VALKEY_PORT, db=idx).flushdb()
    stray = [k for k in r0.scan_iter(match="*", count=500) if k not in expected]
    for i in range(0, len(stray), 500):
        r0.delete(*stray[i:i + 500])
    pipe = r0.pipeline(transaction=False)
    for k, v in expected.items():
        pipe.set(k, v, ex=CACHE_TTL)
    pipe.execute()
    left = set(r0.scan_iter(match="*", count=500))
    log("valkey: %d settlement keys populated, %d stray keys purged, %d keys total"
        % (len(expected), len(stray), len(left)))


def main():
    steps = sys.argv[3:] or ["relay", "queue", "dynamodb", "s3", "valkey"]
    for s in steps:
        {"relay": drain_outbox, "queue": wait_queue_empty, "dynamodb": reconcile_dynamodb,
         "s3": reconcile_s3, "valkey": reconcile_valkey}[s]()
    log("data-plane convergence complete: %s" % ", ".join(steps))


main()
PYEOF
"$PYTHON" "$WORK/reconcile.py" "$CONFIG_FILE" "$MANIFEST_FILE" || die "data-plane convergence failed"

# ---------------------------------------------------------------------------
# 7. Final checks
# ---------------------------------------------------------------------------
write_manifest
wait_ready 120 || die "API not ready after convergence"
log "deployment complete: ${SERVICE_URL}"
exit 0
