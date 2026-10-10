#!/usr/bin/env bash
# ClearLedger deploy: provision/repair infrastructure, initialise the
# PostgreSQL schema, export manifest.json and converge every derived store
# against PostgreSQL. Safe to re-run at any time (idempotent).
set -Eeuo pipefail

SUBMISSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${SUBMISSION_DIR}/infra"
CONFIG_PATH="${CLEARLEDGER_CONFIG:-/workspace/config/config.json}"
MANIFEST_PATH="${SUBMISSION_DIR}/manifest.json"
START_TS=$(date +%s)
DEPLOY_BUDGET=${DEPLOY_BUDGET:-690}

log() { printf '[deploy %4ds] %s\n' "$(( $(date +%s) - START_TS ))" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
remaining() { echo $(( DEPLOY_BUDGET - ($(date +%s) - START_TS) )); }

[[ -f "${CONFIG_PATH}" ]] || die "config not found: ${CONFIG_PATH}"
for bin in jq curl psql python3; do command -v "$bin" >/dev/null 2>&1 || die "missing required tool: $bin"; done

if command -v terraform >/dev/null 2>&1; then TF=terraform; elif command -v tofu >/dev/null 2>&1; then TF=tofu; else die "terraform/tofu not found"; fi

cfg() { jq -er --arg k "$1" '.[$k]' "${CONFIG_PATH}"; }
PREFIX=$(cfg resource_prefix)
REGION=$(cfg region)
ENDPOINT=$(cfg aws_endpoint_url)
DB_NAME=$(cfg db_name)
DB_USER=$(cfg db_username)
DB_PASSWORD=$(cfg db_password)

export AWS_ENDPOINT_URL="${ENDPOINT}"
export AWS_REGION="${REGION}" AWS_DEFAULT_REGION="${REGION}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_PAGER="" AWS_EC2_METADATA_DISABLED=true
export TF_IN_AUTOMATION=1 TF_INPUT=0

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/clearledger-deploy.XXXXXX")
trap 'rm -rf "${WORK_DIR}"' EXIT

log "deploying ClearLedger prefix=${PREFIX} region=${REGION} endpoint=${ENDPOINT} (${TF})"
python3 -c 'import boto3, psycopg, redis, jsonschema' 2>/dev/null || die "python3 needs boto3, psycopg, redis, jsonschema"

# Embedded PostgreSQL schema (clearledger)
write_schema_sql() {
cat <<'CLEARLEDGER_SQL_EOF'
-- ClearLedger PostgreSQL schema (idempotent).
-- Applied by deploy.sh with: psql -v ON_ERROR_STOP=1 --single-transaction
\o /dev/null
SET client_min_messages = warning;
SELECT pg_advisory_xact_lock(724311);

CREATE SCHEMA IF NOT EXISTS clearledger;

-- ---------------------------------------------------------------------------
-- Pure helper functions (used by CHECK constraints and triggers)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION clearledger.tlen_between(v text, lo integer, hi integer)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT v IS NOT NULL AND char_length(btrim(v)) BETWEEN lo AND hi
$$;

CREATE OR REPLACE FUNCTION clearledger.is_uuid_text(v text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT v IS NOT NULL AND v ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
$$;

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

CREATE OR REPLACE FUNCTION clearledger.is_valid_status(s text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT s IS NOT NULL AND s IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED')
$$;

-- Clearing lifecycle transition rule (old -> new).
CREATE OR REPLACE FUNCTION clearledger.is_valid_transition(old_status text, new_status text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN NOT clearledger.is_valid_status(old_status) OR NOT clearledger.is_valid_status(new_status) THEN false
    WHEN old_status = 'RECONCILED' THEN false
    WHEN old_status = 'DISPUTED'   THEN new_status IN ('DISPUTED', 'RECONCILED')
    WHEN new_status = 'DISPUTED'   THEN true
    ELSE clearledger.status_rank(new_status) >= clearledger.status_rank(old_status)
  END
$$;

CREATE OR REPLACE FUNCTION clearledger.is_rfc3339(v text)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  ts timestamptz;
BEGIN
  IF v IS NULL OR v !~* '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$' THEN
    RETURN false;
  END IF;
  ts := v::timestamptz;
  RETURN ts IS NOT NULL;
EXCEPTION WHEN others THEN
  RETURN false;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.jsonb_is_int(v jsonb, lo numeric, hi numeric)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  n numeric;
BEGIN
  IF v IS NULL OR jsonb_typeof(v) <> 'number' THEN
    RETURN false;
  END IF;
  n := (v #>> '{}')::numeric;
  RETURN n = trunc(n) AND n BETWEEN lo AND hi;
EXCEPTION WHEN others THEN
  RETURN false;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.jsonb_is_str(v jsonb)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT v IS NOT NULL AND jsonb_typeof(v) = 'string'
$$;

-- Strict validation of ClearLedgerDomainEventEnvelope (events.schema.json)
-- including additionalProperties=false on the envelope and on data, trimmed
-- length bounds from openapi.yaml and version/kind/status/entryId coupling.
CREATE OR REPLACE FUNCTION clearledger.is_valid_envelope(p jsonb)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  d jsonb;
  k text;
  v integer;
  et text;
  st text;
BEGIN
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN RETURN false; END IF;

  FOR k IN SELECT jsonb_object_keys(p) LOOP
    IF k NOT IN ('schemaVersion','eventId','eventType','aggregateType','aggregateId',
                 'aggregateVersion','occurredAt','correlationId','idempotencyKey','data') THEN
      RETURN false;
    END IF;
  END LOOP;

  IF NOT (p ? 'schemaVersion' AND p ? 'eventId' AND p ? 'eventType' AND p ? 'aggregateType'
          AND p ? 'aggregateId' AND p ? 'aggregateVersion' AND p ? 'occurredAt'
          AND p ? 'correlationId' AND p ? 'idempotencyKey' AND p ? 'data') THEN
    RETURN false;
  END IF;

  IF NOT clearledger.jsonb_is_str(p->'schemaVersion') OR p->>'schemaVersion' <> '1.0' THEN RETURN false; END IF;
  IF NOT clearledger.jsonb_is_str(p->'eventId') OR NOT clearledger.is_uuid_text(p->>'eventId') THEN RETURN false; END IF;
  IF NOT clearledger.jsonb_is_str(p->'eventType')
     OR p->>'eventType' NOT IN ('SettlementInitiated','LedgerEntryRecorded') THEN RETURN false; END IF;
  IF NOT clearledger.jsonb_is_str(p->'aggregateType') OR p->>'aggregateType' <> 'settlement' THEN RETURN false; END IF;
  IF NOT clearledger.jsonb_is_str(p->'aggregateId') OR NOT clearledger.is_uuid_text(p->>'aggregateId') THEN RETURN false; END IF;
  IF NOT clearledger.jsonb_is_int(p->'aggregateVersion', 1, 2147483647) THEN RETURN false; END IF;
  IF NOT clearledger.jsonb_is_str(p->'occurredAt') OR NOT clearledger.is_rfc3339(p->>'occurredAt') THEN RETURN false; END IF;
  IF NOT clearledger.jsonb_is_str(p->'correlationId') OR NOT clearledger.tlen_between(p->>'correlationId', 4, 128) THEN RETURN false; END IF;
  IF NOT clearledger.jsonb_is_str(p->'idempotencyKey') OR NOT clearledger.tlen_between(p->>'idempotencyKey', 8, 128) THEN RETURN false; END IF;

  d := p->'data';
  IF jsonb_typeof(d) <> 'object' THEN RETURN false; END IF;
  FOR k IN SELECT jsonb_object_keys(d) LOOP
    IF k NOT IN ('kind','accountId','reference','debitParty','creditParty','entryId','status','clearingStage','memo') THEN
      RETURN false;
    END IF;
  END LOOP;

  IF NOT clearledger.jsonb_is_str(d->'kind') OR d->>'kind' NOT IN ('settlementInitiated','ledgerEntryRecorded') THEN RETURN false; END IF;
  IF NOT clearledger.jsonb_is_str(d->'accountId')     OR NOT clearledger.tlen_between(d->>'accountId', 3, 64)     THEN RETURN false; END IF;
  IF NOT clearledger.jsonb_is_str(d->'reference')     OR NOT clearledger.tlen_between(d->>'reference', 3, 64)     THEN RETURN false; END IF;
  IF NOT clearledger.jsonb_is_str(d->'debitParty')    OR NOT clearledger.tlen_between(d->>'debitParty', 2, 64)    THEN RETURN false; END IF;
  IF NOT clearledger.jsonb_is_str(d->'creditParty')   OR NOT clearledger.tlen_between(d->>'creditParty', 2, 64)   THEN RETURN false; END IF;
  IF btrim(d->>'debitParty') = btrim(d->>'creditParty') THEN RETURN false; END IF;
  IF NOT clearledger.jsonb_is_str(d->'status')        OR NOT clearledger.is_valid_status(d->>'status')            THEN RETURN false; END IF;
  IF NOT clearledger.jsonb_is_str(d->'clearingStage') OR NOT clearledger.tlen_between(d->>'clearingStage', 2, 64) THEN RETURN false; END IF;

  IF d ? 'entryId' AND jsonb_typeof(d->'entryId') <> 'null' THEN
    IF NOT clearledger.jsonb_is_str(d->'entryId') OR NOT clearledger.is_uuid_text(d->>'entryId') THEN RETURN false; END IF;
  END IF;
  IF d ? 'memo' AND jsonb_typeof(d->'memo') <> 'null' THEN
    IF NOT clearledger.jsonb_is_str(d->'memo') OR NOT clearledger.tlen_between(d->>'memo', 1, 256)
       OR char_length(d->>'memo') > 256 THEN RETURN false; END IF;
  END IF;

  v  := (p->>'aggregateVersion')::integer;
  et := p->>'eventType';
  st := d->>'status';

  IF et = 'SettlementInitiated' THEN
    IF v <> 1 OR d->>'kind' <> 'settlementInitiated' OR st <> 'INITIATED' THEN RETURN false; END IF;
    IF d ? 'entryId' AND jsonb_typeof(d->'entryId') <> 'null' THEN RETURN false; END IF;
  ELSE
    IF v < 2 OR d->>'kind' <> 'ledgerEntryRecorded' OR st = 'INITIATED' THEN RETURN false; END IF;
    IF NOT (d ? 'entryId') OR jsonb_typeof(d->'entryId') <> 'string' THEN RETURN false; END IF;
  END IF;

  RETURN true;
EXCEPTION WHEN others THEN
  RETURN false;
END
$$;

-- Column-to-envelope equality for clearledger.events.
CREATE OR REPLACE FUNCTION clearledger.event_columns_match(
  p jsonb, c_event_id uuid, c_settlement_id uuid, c_version integer, c_event_type text,
  c_correlation_id text, c_idempotency_key text, c_occurred_at timestamptz)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF NOT clearledger.is_valid_envelope(p) THEN RETURN false; END IF;
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

-- Column-to-envelope equality for clearledger.outbox.
CREATE OR REPLACE FUNCTION clearledger.outbox_columns_match(
  p jsonb, c_event_id uuid, c_settlement_id uuid, c_version integer, c_correlation_id text)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF NOT clearledger.is_valid_envelope(p) THEN RETURN false; END IF;
  RETURN (p->>'eventId')::uuid = c_event_id
     AND (p->>'aggregateId')::uuid = c_settlement_id
     AND (p->>'aggregateVersion')::integer = c_version
     AND p->>'correlationId' = c_correlation_id;
EXCEPTION WHEN others THEN
  RETURN false;
END
$$;

-- Closed-schema WriteAcceptedResponse validation for idempotency_keys.
CREATE OR REPLACE FUNCTION clearledger.is_valid_write_response(scope text, status_code integer, body jsonb)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  k text;
  kind text;
  sid text;
  v integer;
BEGIN
  IF scope IS NULL OR scope !~* '^(create|entry):[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    RETURN false;
  END IF;
  kind := split_part(scope, ':', 1);
  sid  := substr(scope, char_length(kind) + 2);

  IF body IS NULL OR jsonb_typeof(body) <> 'object' THEN RETURN false; END IF;
  FOR k IN SELECT jsonb_object_keys(body) LOOP
    IF k NOT IN ('settlementId','eventId','version','accepted','idempotentReplay') THEN RETURN false; END IF;
  END LOOP;
  IF NOT (body ? 'settlementId' AND body ? 'eventId' AND body ? 'version' AND body ? 'accepted' AND body ? 'idempotentReplay') THEN
    RETURN false;
  END IF;
  IF NOT clearledger.jsonb_is_str(body->'settlementId') OR NOT clearledger.is_uuid_text(body->>'settlementId') THEN RETURN false; END IF;
  IF (body->>'settlementId')::uuid <> sid::uuid THEN RETURN false; END IF;
  IF NOT clearledger.jsonb_is_str(body->'eventId') OR NOT clearledger.is_uuid_text(body->>'eventId') THEN RETURN false; END IF;
  IF NOT clearledger.jsonb_is_int(body->'version', 1, 2147483647) THEN RETURN false; END IF;
  IF jsonb_typeof(body->'accepted') <> 'boolean' OR (body->>'accepted')::boolean IS NOT TRUE THEN RETURN false; END IF;
  IF jsonb_typeof(body->'idempotentReplay') <> 'boolean' OR (body->>'idempotentReplay')::boolean IS NOT FALSE THEN RETURN false; END IF;

  v := (body->>'version')::integer;
  IF lower(kind) = 'create' THEN
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
  seq               BIGSERIAL   NOT NULL PRIMARY KEY,
  event_id          UUID        NOT NULL UNIQUE,
  settlement_id     UUID        NOT NULL REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE,
  aggregate_version INTEGER     NOT NULL,
  event_type        TEXT        NOT NULL,
  correlation_id    TEXT        NOT NULL,
  idempotency_key   TEXT        NOT NULL,
  occurred_at       TIMESTAMPTZ NOT NULL,
  payload           JSONB       NOT NULL,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS clearledger.outbox (
  seq               BIGSERIAL   NOT NULL PRIMARY KEY,
  event_id          UUID        NOT NULL UNIQUE REFERENCES clearledger.events(event_id) ON DELETE CASCADE,
  settlement_id     UUID        NOT NULL REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE,
  aggregate_version INTEGER     NOT NULL,
  correlation_id    TEXT        NOT NULL,
  payload           JSONB       NOT NULL,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  published_at      TIMESTAMPTZ NULL,
  archived_at       TIMESTAMPTZ NULL,
  attempts          INTEGER     NOT NULL DEFAULT 0,
  last_error        TEXT        NULL
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
-- Named constraints (added only when missing so re-deploys are cheap)
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

-- settlements
SELECT pg_temp.ensure_constraint('settlements', 'settlements_account_id_len_chk',   $c$CHECK (clearledger.tlen_between(account_id, 3, 64) AND char_length(account_id) <= 64)$c$);
SELECT pg_temp.ensure_constraint('settlements', 'settlements_reference_len_chk',    $c$CHECK (clearledger.tlen_between(reference, 3, 64) AND char_length(reference) <= 64)$c$);
SELECT pg_temp.ensure_constraint('settlements', 'settlements_debit_party_len_chk',  $c$CHECK (clearledger.tlen_between(debit_party, 2, 64) AND char_length(debit_party) <= 64)$c$);
SELECT pg_temp.ensure_constraint('settlements', 'settlements_credit_party_len_chk', $c$CHECK (clearledger.tlen_between(credit_party, 2, 64) AND char_length(credit_party) <= 64)$c$);
SELECT pg_temp.ensure_constraint('settlements', 'settlements_parties_distinct_chk', $c$CHECK (btrim(debit_party) <> btrim(credit_party))$c$);
SELECT pg_temp.ensure_constraint('settlements', 'settlements_status_chk',           $c$CHECK (current_status IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED'))$c$);
SELECT pg_temp.ensure_constraint('settlements', 'settlements_stage_len_chk',        $c$CHECK (clearledger.tlen_between(current_stage, 2, 64) AND char_length(current_stage) <= 64)$c$);
SELECT pg_temp.ensure_constraint('settlements', 'settlements_last_memo_len_chk',    $c$CHECK (last_memo IS NULL OR (clearledger.tlen_between(last_memo, 1, 256) AND char_length(last_memo) <= 256))$c$);
SELECT pg_temp.ensure_constraint('settlements', 'settlements_version_chk',          $c$CHECK (version >= 1)$c$);
SELECT pg_temp.ensure_constraint('settlements', 'settlements_entry_count_chk',      $c$CHECK (entry_count >= 0)$c$);
SELECT pg_temp.ensure_constraint('settlements', 'settlements_timestamps_chk',       $c$CHECK (updated_at >= created_at)$c$);
SELECT pg_temp.ensure_constraint('settlements', 'settlements_lifecycle_chk', $c$CHECK (
  (version = 1 AND entry_count = 0 AND current_status = 'INITIATED' AND last_entry_id IS NULL AND updated_at = created_at)
  OR
  (version > 1 AND entry_count = version - 1 AND current_status <> 'INITIATED' AND last_entry_id IS NOT NULL)
)$c$);

-- events
SELECT pg_temp.ensure_constraint('events', 'events_settlement_version_key',     $c$UNIQUE (settlement_id, aggregate_version)$c$);
SELECT pg_temp.ensure_constraint('events', 'events_settlement_idempotency_key', $c$UNIQUE (settlement_id, idempotency_key)$c$);
SELECT pg_temp.ensure_constraint('events', 'events_version_chk',                $c$CHECK (aggregate_version >= 1)$c$);
SELECT pg_temp.ensure_constraint('events', 'events_event_type_chk',             $c$CHECK (event_type IN ('SettlementInitiated','LedgerEntryRecorded'))$c$);
SELECT pg_temp.ensure_constraint('events', 'events_correlation_id_len_chk',     $c$CHECK (clearledger.tlen_between(correlation_id, 4, 128) AND char_length(correlation_id) <= 128)$c$);
SELECT pg_temp.ensure_constraint('events', 'events_idempotency_key_len_chk',    $c$CHECK (clearledger.tlen_between(idempotency_key, 8, 128) AND char_length(idempotency_key) <= 128)$c$);
SELECT pg_temp.ensure_constraint('events', 'events_type_version_chk', $c$CHECK (
  (event_type = 'SettlementInitiated' AND aggregate_version = 1)
  OR (event_type = 'LedgerEntryRecorded' AND aggregate_version >= 2)
)$c$);
SELECT pg_temp.ensure_constraint('events', 'events_payload_envelope_chk', $c$CHECK (
  clearledger.event_columns_match(payload, event_id, settlement_id, aggregate_version, event_type,
                                  correlation_id, idempotency_key, occurred_at)
)$c$);

-- outbox
SELECT pg_temp.ensure_constraint('outbox', 'outbox_settlement_version_key', $c$UNIQUE (settlement_id, aggregate_version)$c$);
SELECT pg_temp.ensure_constraint('outbox', 'outbox_event_version_fkey', $c$FOREIGN KEY (settlement_id, aggregate_version)
  REFERENCES clearledger.events(settlement_id, aggregate_version) ON DELETE CASCADE$c$);
SELECT pg_temp.ensure_constraint('outbox', 'outbox_version_chk',            $c$CHECK (aggregate_version >= 1)$c$);
SELECT pg_temp.ensure_constraint('outbox', 'outbox_correlation_id_len_chk', $c$CHECK (clearledger.tlen_between(correlation_id, 4, 128) AND char_length(correlation_id) <= 128)$c$);
SELECT pg_temp.ensure_constraint('outbox', 'outbox_attempts_chk',           $c$CHECK (attempts >= 0)$c$);
SELECT pg_temp.ensure_constraint('outbox', 'outbox_published_chk', $c$CHECK (
  published_at IS NULL OR (attempts >= 1 AND last_error IS NULL AND published_at >= created_at)
)$c$);
SELECT pg_temp.ensure_constraint('outbox', 'outbox_archived_chk', $c$CHECK (
  archived_at IS NULL OR (published_at IS NOT NULL AND archived_at >= published_at)
)$c$);
SELECT pg_temp.ensure_constraint('outbox', 'outbox_payload_envelope_chk', $c$CHECK (
  clearledger.outbox_columns_match(payload, event_id, settlement_id, aggregate_version, correlation_id)
)$c$);

-- idempotency_keys
SELECT pg_temp.ensure_constraint('idempotency_keys', 'idempotency_keys_scope_chk', $c$CHECK (
  scope ~* '^(create|entry):[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
)$c$);
SELECT pg_temp.ensure_constraint('idempotency_keys', 'idempotency_keys_key_len_chk', $c$CHECK (
  clearledger.tlen_between(idempotency_key, 8, 128) AND char_length(idempotency_key) <= 128
)$c$);
SELECT pg_temp.ensure_constraint('idempotency_keys', 'idempotency_keys_request_hash_chk', $c$CHECK (request_hash ~ '^[0-9a-f]{64}$')$c$);
SELECT pg_temp.ensure_constraint('idempotency_keys', 'idempotency_keys_status_code_chk', $c$CHECK (
  (scope LIKE 'create:%' AND status_code = 201) OR (scope LIKE 'entry:%' AND status_code = 202)
)$c$);
SELECT pg_temp.ensure_constraint('idempotency_keys', 'idempotency_keys_response_body_chk', $c$CHECK (
  clearledger.is_valid_write_response(scope, status_code, response_body)
)$c$);

-- ---------------------------------------------------------------------------
-- Trigger functions
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION clearledger.trg_settlements_before_insert()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.version IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'settlement % must be initiated at version 1 (got %)', NEW.settlement_id, NEW.version
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.trg_settlements_before_update()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.current_status = 'RECONCILED' THEN
    RAISE EXCEPTION 'settlement % is RECONCILED (terminal) and cannot be modified', OLD.settlement_id;
  END IF;

  IF NEW.settlement_id IS DISTINCT FROM OLD.settlement_id
     OR NEW.account_id   IS DISTINCT FROM OLD.account_id
     OR NEW.reference    IS DISTINCT FROM OLD.reference
     OR NEW.debit_party  IS DISTINCT FROM OLD.debit_party
     OR NEW.credit_party IS DISTINCT FROM OLD.credit_party
     OR NEW.created_at   IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'settlement % header columns are immutable', OLD.settlement_id;
  END IF;

  IF NEW.version IS DISTINCT FROM OLD.version + 1 THEN
    RAISE EXCEPTION 'settlement % version must advance by exactly 1 (% -> %)', OLD.settlement_id, OLD.version, NEW.version;
  END IF;

  IF NEW.entry_count IS DISTINCT FROM OLD.entry_count + 1 THEN
    RAISE EXCEPTION 'settlement % entry_count must advance by exactly 1 (% -> %)', OLD.settlement_id, OLD.entry_count, NEW.entry_count;
  END IF;

  IF NEW.last_entry_id IS NULL OR NEW.last_entry_id IS NOT DISTINCT FROM OLD.last_entry_id THEN
    RAISE EXCEPTION 'settlement % update requires a new last_entry_id', OLD.settlement_id;
  END IF;

  IF NEW.updated_at < OLD.updated_at THEN
    RAISE EXCEPTION 'settlement % updated_at cannot move backwards', OLD.settlement_id;
  END IF;

  IF NOT clearledger.is_valid_transition(OLD.current_status, NEW.current_status) THEN
    RAISE EXCEPTION 'settlement % illegal status transition % -> %', OLD.settlement_id, OLD.current_status, NEW.current_status;
  END IF;

  RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.trg_events_before_insert()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  s       clearledger.settlements%ROWTYPE;
  d       jsonb;
  max_v   integer;
  prev    clearledger.events%ROWTYPE;
  entry   text;
BEGIN
  IF NOT clearledger.is_valid_envelope(NEW.payload) THEN
    RAISE EXCEPTION 'event % payload is not a valid ClearLedgerDomainEventEnvelope', NEW.event_id
      USING ERRCODE = 'check_violation';
  END IF;
  d := NEW.payload->'data';

  SELECT * INTO s FROM clearledger.settlements WHERE settlement_id = NEW.settlement_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'event % references unknown settlement %', NEW.event_id, NEW.settlement_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  -- contiguous per-settlement versions starting at 1
  SELECT max(aggregate_version) INTO max_v FROM clearledger.events WHERE settlement_id = NEW.settlement_id;
  IF NEW.aggregate_version IS DISTINCT FROM COALESCE(max_v, 0) + 1 THEN
    RAISE EXCEPTION 'event % version % is not contiguous (expected %)', NEW.event_id, NEW.aggregate_version, COALESCE(max_v, 0) + 1;
  END IF;

  -- entryId unique per settlement
  entry := d->>'entryId';
  IF entry IS NOT NULL AND EXISTS (
    SELECT 1 FROM clearledger.events e
    WHERE e.settlement_id = NEW.settlement_id
      AND e.event_type = 'LedgerEntryRecorded'
      AND lower(e.payload->'data'->>'entryId') = lower(entry)
  ) THEN
    RAISE EXCEPTION 'entryId % already recorded for settlement %', entry, NEW.settlement_id
      USING ERRCODE = 'unique_violation';
  END IF;

  -- event must mirror the parent settlement row
  IF s.account_id      IS DISTINCT FROM d->>'accountId'
     OR s.reference    IS DISTINCT FROM d->>'reference'
     OR s.debit_party  IS DISTINCT FROM d->>'debitParty'
     OR s.credit_party IS DISTINCT FROM d->>'creditParty'
     OR s.current_status IS DISTINCT FROM d->>'status'
     OR s.current_stage  IS DISTINCT FROM d->>'clearingStage'
     OR s.last_entry_id  IS DISTINCT FROM (d->>'entryId')::uuid
     OR s.last_memo      IS DISTINCT FROM (d->>'memo')
     OR s.version        IS DISTINCT FROM NEW.aggregate_version
     OR s.updated_at     IS DISTINCT FROM NEW.occurred_at THEN
    RAISE EXCEPTION 'event % does not match settlement % state', NEW.event_id, NEW.settlement_id;
  END IF;

  IF NEW.aggregate_version = 1 THEN
    IF s.created_at IS DISTINCT FROM NEW.occurred_at THEN
      RAISE EXCEPTION 'initiation event % occurred_at must equal settlement created_at', NEW.event_id;
    END IF;
  ELSE
    SELECT * INTO prev FROM clearledger.events
     WHERE settlement_id = NEW.settlement_id AND aggregate_version = NEW.aggregate_version - 1;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'event % has no predecessor version %', NEW.event_id, NEW.aggregate_version - 1;
    END IF;
    IF NEW.occurred_at < prev.occurred_at THEN
      RAISE EXCEPTION 'event % occurred_at precedes previous event', NEW.event_id;
    END IF;
    IF NOT clearledger.is_valid_transition(prev.payload->'data'->>'status', d->>'status') THEN
      RAISE EXCEPTION 'event % illegal status transition % -> %', NEW.event_id,
        prev.payload->'data'->>'status', d->>'status';
    END IF;
  END IF;

  RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.trg_append_only()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'clearledger.% is append-only: % rejected', TG_TABLE_NAME, TG_OP;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.trg_outbox_before_insert()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  e     clearledger.events%ROWTYPE;
  max_v integer;
BEGIN
  IF NOT clearledger.is_valid_envelope(NEW.payload) THEN
    RAISE EXCEPTION 'outbox payload for event % is not a valid envelope', NEW.event_id
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT * INTO e FROM clearledger.events WHERE event_id = NEW.event_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'outbox row references unknown event %', NEW.event_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF e.settlement_id IS DISTINCT FROM NEW.settlement_id
     OR e.aggregate_version IS DISTINCT FROM NEW.aggregate_version
     OR e.correlation_id IS DISTINCT FROM NEW.correlation_id
     OR e.payload IS DISTINCT FROM NEW.payload THEN
    RAISE EXCEPTION 'outbox row for event % does not mirror clearledger.events', NEW.event_id;
  END IF;

  SELECT max(aggregate_version) INTO max_v FROM clearledger.outbox WHERE settlement_id = NEW.settlement_id;
  IF NEW.aggregate_version IS DISTINCT FROM COALESCE(max_v, 0) + 1 THEN
    RAISE EXCEPTION 'outbox version % for settlement % is not contiguous (expected %)',
      NEW.aggregate_version, NEW.settlement_id, COALESCE(max_v, 0) + 1;
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
    RAISE EXCEPTION 'outbox row % envelope columns are immutable', OLD.seq;
  END IF;

  IF NEW.attempts < OLD.attempts THEN
    RAISE EXCEPTION 'outbox row % attempts cannot decrease', OLD.seq;
  END IF;

  IF OLD.published_at IS NULL AND NEW.published_at IS NOT NULL THEN
    -- publishing
    IF NEW.attempts <= OLD.attempts THEN
      RAISE EXCEPTION 'outbox row % publish must increment attempts', OLD.seq;
    END IF;
    IF NEW.archived_at IS NOT NULL THEN
      RAISE EXCEPTION 'outbox row % cannot be archived while being published', OLD.seq;
    END IF;
  ELSIF OLD.published_at IS NOT NULL AND NEW.published_at IS NOT NULL THEN
    -- already published: only archival bookkeeping may change
    IF NEW.published_at IS DISTINCT FROM OLD.published_at
       OR NEW.attempts IS DISTINCT FROM OLD.attempts
       OR NEW.last_error IS DISTINCT FROM OLD.last_error THEN
      RAISE EXCEPTION 'outbox row % published_at/attempts/last_error are immutable once published', OLD.seq;
    END IF;
    IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NOT NULL
       AND NEW.archived_at IS DISTINCT FROM OLD.archived_at THEN
      RAISE EXCEPTION 'outbox row % archived_at cannot be rewritten without reset', OLD.seq;
    END IF;
  ELSIF OLD.published_at IS NOT NULL AND NEW.published_at IS NULL THEN
    -- operational replay reset
    IF NEW.archived_at IS NOT NULL THEN
      RAISE EXCEPTION 'outbox row % replay reset requires archived_at = NULL', OLD.seq;
    END IF;
  ELSE
    -- unpublished -> unpublished (delivery failure bookkeeping)
    IF NEW.archived_at IS NOT NULL THEN
      RAISE EXCEPTION 'outbox row % cannot be archived before publication', OLD.seq;
    END IF;
  END IF;

  RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.trg_outbox_before_delete()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'clearledger.outbox rows cannot be deleted (seq %)', OLD.seq;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.trg_idempotency_before_insert()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  b   jsonb := NEW.response_body;
  eid uuid;
  sid uuid;
  ver integer;
BEGIN
  IF NOT clearledger.is_valid_write_response(NEW.scope, NEW.status_code, b) THEN
    RAISE EXCEPTION 'idempotency key % has an invalid response body', NEW.idempotency_key
      USING ERRCODE = 'check_violation';
  END IF;

  eid := (b->>'eventId')::uuid;
  sid := (b->>'settlementId')::uuid;
  ver := (b->>'version')::integer;

  IF NOT EXISTS (
    SELECT 1 FROM clearledger.events e
    WHERE e.event_id = eid AND e.settlement_id = sid AND e.aggregate_version = ver
      AND e.idempotency_key = NEW.idempotency_key
  ) THEN
    RAISE EXCEPTION 'idempotency key % does not reference a committed event', NEW.idempotency_key
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM clearledger.outbox o
    WHERE o.event_id = eid AND o.settlement_id = sid AND o.aggregate_version = ver
  ) THEN
    RAISE EXCEPTION 'idempotency key % does not reference an outbox row', NEW.idempotency_key
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  RETURN NEW;
END
$$;

-- ---------------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE TRIGGER settlements_before_insert
  BEFORE INSERT ON clearledger.settlements
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_settlements_before_insert();

CREATE OR REPLACE TRIGGER settlements_before_update
  BEFORE UPDATE ON clearledger.settlements
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_settlements_before_update();

CREATE OR REPLACE TRIGGER events_before_insert
  BEFORE INSERT ON clearledger.events
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_events_before_insert();

CREATE OR REPLACE TRIGGER events_append_only
  BEFORE UPDATE OR DELETE ON clearledger.events
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_append_only();

CREATE OR REPLACE TRIGGER outbox_before_insert
  BEFORE INSERT ON clearledger.outbox
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_outbox_before_insert();

CREATE OR REPLACE TRIGGER outbox_before_update
  BEFORE UPDATE ON clearledger.outbox
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_outbox_before_update();

CREATE OR REPLACE TRIGGER outbox_before_delete
  BEFORE DELETE ON clearledger.outbox
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_outbox_before_delete();

CREATE OR REPLACE TRIGGER idempotency_keys_before_insert
  BEFORE INSERT ON clearledger.idempotency_keys
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_idempotency_before_insert();

CREATE OR REPLACE TRIGGER idempotency_keys_append_only
  BEFORE UPDATE OR DELETE ON clearledger.idempotency_keys
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_append_only();

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_clearledger_outbox_unpublished
  ON clearledger.outbox (seq) WHERE published_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_clearledger_outbox_unarchived
  ON clearledger.outbox (seq) WHERE published_at IS NOT NULL AND archived_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_clearledger_events_settlement_version
  ON clearledger.events (settlement_id, aggregate_version);
CLEARLEDGER_SQL_EOF
}

# Embedded convergence program
write_converge_py() {
cat <<'CLEARLEDGER_PY_EOF'
#!/usr/bin/env python3
"""ClearLedger data-plane / control-plane convergence.

PostgreSQL is the system of record. This script converges every derived store
against it and removes out-of-band control-plane drift that Terraform does not
own exclusively:

  1. IAM: strip out-of-band inline/attached policies from the six workload
     roles and delete detached <prefix>-* customer-managed policies.
  2. Security groups: revoke forbidden egress rules (rds/valkey: none, alb: no
     0.0.0.0/0, ::/0 or all-protocol egress).
  3. Outbox: drain unpublished rows through the outbox_relay Lambda.
  4. SQS: wait until the projector has drained the main queue.
  5. DynamoDB: 1-to-1 STATE / EVENT#nnnnnnnn items with PostgreSQL.
  6. S3: 1-to-1 canonical NDJSON audit batches with clearledger.outbox (via the
     audit_archiver Lambda first, then deterministic repair), purging
     noncurrent versions and delete markers.
  7. Valkey: only clearledger:settlement:<id> keys, populated for every
     settlement with the canonical SettlementProjection JSON and TTL 90.

Usage: converge.py <config.json> <manifest.json>
"""
import datetime as dt
import hashlib
import json
import re
import sys
import time

import boto3
import psycopg
import redis
from botocore.config import Config

CFG = json.load(open(sys.argv[1]))
MAN = json.load(open(sys.argv[2]))
PREFIX = CFG["resource_prefix"]
EP = CFG["aws_endpoint_url"]
REGION = CFG["region"]
CACHE_TTL = 90
AUDIT_PREFIX = "ledger-audit/"
AUDIT_BATCH = 100
KEY_RE = re.compile(r"^ledger-audit/batch-(\d{8})-(\d{8})-([0-9a-f]{16})\.ndjson$")

BOTO_CFG = Config(retries={"max_attempts": 6, "mode": "standard"}, read_timeout=180, connect_timeout=10)


def log(msg):
    print(f"[converge] {msg}", file=sys.stderr, flush=True)


def client(name):
    return boto3.client(name, endpoint_url=EP, region_name=REGION,
                        aws_access_key_id="test", aws_secret_access_key="test", config=BOTO_CFG)


def db():
    return psycopg.connect(
        host=MAN["database"]["endpoint"], port=MAN["database"]["port"],
        dbname=CFG["db_name"], user=CFG["db_username"], password=CFG["db_password"],
        connect_timeout=10, autocommit=True)


# ---------------------------------------------------------------------------
# Canonical serialisations (mirror the Rust workers byte-for-byte)
# ---------------------------------------------------------------------------

ENVELOPE_ORDER = ["schemaVersion", "eventId", "eventType", "aggregateType", "aggregateId",
                  "aggregateVersion", "occurredAt", "correlationId", "idempotencyKey", "data"]
DATA_ORDER = ["kind", "accountId", "reference", "debitParty", "creditParty", "entryId",
              "status", "clearingStage", "memo"]


def _ordered(obj, order):
    out = {k: obj[k] for k in order if k in obj}
    for k in obj:  # never drop unknown keys (schema forbids them anyway)
        if k not in out:
            out[k] = obj[k]
    return out


def canonical_envelope(payload):
    env = _ordered(payload, ENVELOPE_ORDER)
    if isinstance(env.get("data"), dict):
        env["data"] = _ordered(env["data"], DATA_ORDER)
    return json.dumps(env, separators=(",", ":"), ensure_ascii=False)


def rfc3339(ts, z=False):
    """chrono::DateTime::to_rfc3339_opts(SecondsFormat::AutoSi, z)."""
    ts = ts.astimezone(dt.timezone.utc)
    base = ts.strftime("%Y-%m-%dT%H:%M:%S")
    us = ts.microsecond
    if us == 0:
        frac = ""
    elif us % 1000 == 0:
        frac = ".%03d" % (us // 1000)
    else:
        frac = ".%06d" % us
    return base + frac + ("Z" if z else "+00:00")


# ---------------------------------------------------------------------------
# 1. IAM drift
# ---------------------------------------------------------------------------

def converge_iam():
    iam = client("iam")
    roles = [arn.split("/")[-1] for arn in MAN["iam"].values()]
    for role in roles:
        canonical = f"{role}-least-privilege"
        try:
            names = iam.list_role_policies(RoleName=role).get("PolicyNames", [])
        except iam.exceptions.NoSuchEntityException:
            continue
        for name in names:
            if name != canonical:
                log(f"iam: deleting out-of-band inline policy {role}/{name}")
                iam.delete_role_policy(RoleName=role, PolicyName=name)
        for ap in iam.list_attached_role_policies(RoleName=role).get("AttachedPolicies", []):
            log(f"iam: detaching out-of-band policy {ap['PolicyArn']} from {role}")
            iam.detach_role_policy(RoleName=role, PolicyArn=ap["PolicyArn"])

    paginator = iam.get_paginator("list_policies")
    for page in paginator.paginate(Scope="Local"):
        for pol in page.get("Policies", []):
            if not pol["PolicyName"].startswith(PREFIX):
                continue
            arn = pol["Arn"]
            ents = iam.list_entities_for_policy(PolicyArn=arn)
            if ents.get("PolicyRoles") or ents.get("PolicyUsers") or ents.get("PolicyGroups"):
                continue
            log(f"iam: deleting detached out-of-band policy {arn}")
            for v in iam.list_policy_versions(PolicyArn=arn).get("Versions", []):
                if not v["IsDefaultVersion"]:
                    iam.delete_policy_version(PolicyArn=arn, VersionId=v["VersionId"])
            iam.delete_policy(PolicyArn=arn)


# ---------------------------------------------------------------------------
# 2. Security-group egress drift
# ---------------------------------------------------------------------------

def converge_security_groups():
    ec2 = client("ec2")
    sgs = MAN["network"]["security_group_ids"]
    resp = ec2.describe_security_groups(GroupIds=list(sgs.values()))
    by_id = {g["GroupId"]: g for g in resp["SecurityGroups"]}
    for role, gid in sgs.items():
        g = by_id.get(gid)
        if not g:
            continue
        bad = []
        for perm in g.get("IpPermissionsEgress", []):
            if role in ("rds", "valkey"):
                bad.append(perm)
            elif role == "alb":
                open4 = any(r.get("CidrIp") == "0.0.0.0/0" for r in perm.get("IpRanges", []))
                open6 = any(r.get("CidrIpv6") == "::/0" for r in perm.get("Ipv6Ranges", []))
                if open4 or open6 or perm.get("IpProtocol") == "-1":
                    bad.append(perm)
        if bad:
            log(f"sg: revoking {len(bad)} forbidden egress rule(s) on {role} ({gid})")
            clean = []
            for p in bad:
                q = {k: v for k, v in p.items() if k in ("IpProtocol", "FromPort", "ToPort", "IpRanges",
                                                         "Ipv6Ranges", "PrefixListIds", "UserIdGroupPairs")}
                for k in ("IpRanges", "Ipv6Ranges", "PrefixListIds", "UserIdGroupPairs"):
                    if k in q and not q[k]:
                        del q[k]
                clean.append(q)
            try:
                ec2.revoke_security_group_egress(GroupId=gid, IpPermissions=clean)
            except Exception as exc:  # noqa: BLE001
                log(f"sg: revoke failed on {gid}: {exc}")


# ---------------------------------------------------------------------------
# 3. Outbox drain via outbox_relay
# ---------------------------------------------------------------------------

def invoke(fn):
    lam = client("lambda")
    r = lam.invoke(FunctionName=fn, InvocationType="RequestResponse", Payload=b"{}")
    body = r["Payload"].read()
    if r.get("FunctionError"):
        raise RuntimeError(f"{fn} failed: {body[:500]!r}")
    return body


def count(conn, sql):
    return conn.execute(sql).fetchone()[0]


def drain_outbox(conn, deadline):
    fn = MAN["workers"]["outbox_relay"]["function_name"]
    last = None
    while True:
        n = count(conn, "SELECT count(*) FROM clearledger.outbox WHERE published_at IS NULL")
        if n == 0:
            log("outbox: no unpublished rows")
            return
        if time.time() > deadline:
            raise RuntimeError(f"outbox: {n} rows still unpublished at deadline")
        log(f"outbox: {n} unpublished row(s); invoking {fn}")
        try:
            invoke(fn)
        except Exception as exc:  # noqa: BLE001
            log(f"outbox: relay invocation error: {exc}")
            time.sleep(3)
        if last is not None and n >= last:
            time.sleep(2)
        last = n


# ---------------------------------------------------------------------------
# 4. Wait for the projector to drain SQS
# ---------------------------------------------------------------------------

def wait_queue_drained(deadline):
    sqs = client("sqs")
    url = MAN["messaging"]["queue_url"]
    stable = 0
    while time.time() < deadline:
        a = sqs.get_queue_attributes(QueueUrl=url, AttributeNames=[
            "ApproximateNumberOfMessages", "ApproximateNumberOfMessagesNotVisible",
            "ApproximateNumberOfMessagesDelayed"])["Attributes"]
        total = sum(int(a.get(k, 0)) for k in a)
        if total == 0:
            stable += 1
            if stable >= 2:
                log("sqs: main queue drained")
                return True
        else:
            stable = 0
        time.sleep(1.5)
    log("sqs: main queue not fully drained before deadline; continuing")
    return False


# ---------------------------------------------------------------------------
# 5. DynamoDB projections
# ---------------------------------------------------------------------------

def S(v):
    return {"S": v}


def N(v):
    return {"N": str(int(v))}


def load_pg(conn):
    settlements = conn.execute("""
        SELECT settlement_id::text, account_id, reference, debit_party, credit_party, current_status,
               current_stage, last_entry_id::text, last_memo, version, entry_count, updated_at
          FROM clearledger.settlements ORDER BY settlement_id""").fetchall()
    events = conn.execute("""
        SELECT settlement_id::text, event_id::text, aggregate_version, event_type, correlation_id,
               occurred_at, payload
          FROM clearledger.events ORDER BY settlement_id, aggregate_version""").fetchall()
    return settlements, events


def expected_items(settlements, events):
    items = {}
    for (sid, acct, ref, dp, cp, status, stage, last_entry, last_memo, version, entry_count, updated) in settlements:
        it = {
            "PK": S(f"SETTLEMENT#{sid}"), "SK": S("STATE"),
            "GSI1PK": S(f"ACCOUNT#{acct}"), "GSI1SK": S(f"SETTLEMENT#{sid}"),
            "settlement_id": S(sid), "account_id": S(acct), "reference": S(ref),
            "debit_party": S(dp), "credit_party": S(cp), "status": S(status),
            "clearing_stage": S(stage), "version": N(version), "entry_count": N(entry_count),
            "updated_at": S(rfc3339(updated)),
        }
        if last_entry is not None:
            it["last_entry_id"] = S(last_entry)
        if last_memo is not None:
            it["last_memo"] = S(last_memo)
        items[(f"SETTLEMENT#{sid}", "STATE")] = it
    for (sid, eid, ver, etype, corr, occurred, payload) in events:
        data = payload.get("data") or {}
        it = {
            "PK": S(f"SETTLEMENT#{sid}"), "SK": S("EVENT#%08d" % ver),
            "settlement_id": S(sid), "event_id": S(eid), "version": N(ver), "event_type": S(etype),
            "status": S(data.get("status")), "clearing_stage": S(data.get("clearingStage")),
            "occurred_at": S(rfc3339(occurred)), "correlation_id": S(corr),
            "envelope": S(canonical_envelope(payload)),
        }
        if data.get("entryId") is not None:
            it["entry_id"] = S(data["entryId"])
        if data.get("memo") is not None:
            it["memo"] = S(data["memo"])
        items[(f"SETTLEMENT#{sid}", "EVENT#%08d" % ver)] = it
    return items


def converge_dynamodb(conn):
    ddb = client("dynamodb")
    table = MAN["projections"]["table_name"]
    settlements, events = load_pg(conn)
    want = expected_items(settlements, events)

    have = {}
    kw = {"TableName": table, "ConsistentRead": True}
    while True:
        page = ddb.scan(**kw)
        for it in page.get("Items", []):
            pk = it.get("PK", {}).get("S")
            sk = it.get("SK", {}).get("S")
            have[(pk, sk)] = it
        if "LastEvaluatedKey" not in page:
            break
        kw["ExclusiveStartKey"] = page["LastEvaluatedKey"]

    deleted = written = 0
    for key, it in have.items():
        if key not in want:
            ddb.delete_item(TableName=table, Key={"PK": it["PK"], "SK": it["SK"]})
            deleted += 1
    for key, it in want.items():
        if have.get(key) != it:
            ddb.put_item(TableName=table, Item=it)
            written += 1
    log(f"dynamodb: {len(want)} expected item(s); wrote {written}, deleted {deleted}")
    return settlements


# ---------------------------------------------------------------------------
# 6. S3 audit archive
# ---------------------------------------------------------------------------

def list_versions(s3, bucket):
    versions, markers = [], []
    kw = {"Bucket": bucket}
    while True:
        page = s3.list_object_versions(**kw)
        versions.extend(page.get("Versions", []) or [])
        markers.extend(page.get("DeleteMarkers", []) or [])
        if not page.get("IsTruncated"):
            break
        kw["KeyMarker"] = page.get("NextKeyMarker")
        if page.get("NextVersionIdMarker"):
            kw["VersionIdMarker"] = page["NextVersionIdMarker"]
        else:
            kw.pop("VersionIdMarker", None)
    return versions, markers


def batch_body(rows):
    return "".join(canonical_envelope(p) + "\n" for (_, p) in rows).encode()


def batch_key(rows, body):
    return "%sbatch-%08d-%08d-%s.ndjson" % (AUDIT_PREFIX, rows[0][0], rows[-1][0],
                                            hashlib.sha256(body).hexdigest()[:16])


def run_archiver(conn, deadline):
    fn = MAN["workers"]["audit_archiver"]["function_name"]
    for _ in range(50):
        n = count(conn, "SELECT count(*) FROM clearledger.outbox WHERE published_at IS NOT NULL AND archived_at IS NULL")
        if n == 0 or time.time() > deadline:
            return
        log(f"s3: {n} published row(s) awaiting archival; invoking {fn}")
        try:
            invoke(fn)
        except Exception as exc:  # noqa: BLE001
            log(f"s3: archiver invocation error: {exc}")
            return


def s3_pass(conn, s3, bucket):
    """One reconciliation pass. Returns number of mutations performed."""
    rows = conn.execute("""SELECT seq, payload, published_at IS NOT NULL, archived_at IS NOT NULL
                             FROM clearledger.outbox ORDER BY seq""").fetchall()
    by_seq = {r[0]: r for r in rows}
    seqs = [r[0] for r in rows]

    versions, markers = list_versions(s3, bucket)
    latest = [v for v in versions if v.get("IsLatest")]
    changes = 0

    # Validate current objects.
    valid = []  # (first, last, key)
    for v in latest:
        key = v["Key"]
        m = KEY_RE.match(key)
        ok = False
        if m:
            first, last, digest = int(m.group(1)), int(m.group(2)), m.group(3)
            if first <= last:
                try:
                    body = s3.get_object(Bucket=bucket, Key=key, VersionId=v["VersionId"])["Body"].read()
                except Exception:  # noqa: BLE001
                    body = None
                if body is not None and hashlib.sha256(body).hexdigest()[:16] == digest:
                    in_range = [s for s in seqs if first <= s <= last]
                    if in_range and in_range[0] == first and in_range[-1] == last \
                            and all(by_seq[s][2] for s in in_range):
                        expect = batch_body([(s, by_seq[s][1]) for s in in_range])
                        ok = body == expect
        if ok:
            valid.append((first, last, key))

    # Choose a disjoint subset (earliest first, then widest).
    valid.sort(key=lambda t: (t[0], -(t[1] - t[0])))
    keep, covered_to = [], -1
    for first, last, key in valid:
        if first > covered_to:
            keep.append((first, last, key))
            covered_to = last
    keep_keys = {k for _, _, k in keep}

    covered = set()
    for first, last, _ in keep:
        covered.update(s for s in seqs if first <= s <= last)

    # Mark rows covered by kept objects as archived.
    need_mark = [s for s in covered if not by_seq[s][3]]
    if need_mark:
        conn.execute("UPDATE clearledger.outbox SET archived_at = NOW() "
                     "WHERE seq = ANY(%s) AND archived_at IS NULL", (need_mark,))
        changes += len(need_mark)

    # Write deterministic batches for published rows not covered by any object.
    runs, cur = [], []
    for s in seqs:
        published = by_seq[s][2]
        if s in covered or not published:
            if cur:
                runs.append(cur)
                cur = []
            continue
        cur.append(s)
        if len(cur) == AUDIT_BATCH:
            runs.append(cur)
            cur = []
    if cur:
        runs.append(cur)

    for run in runs:
        brows = [(s, by_seq[s][1]) for s in run]
        body = batch_body(brows)
        key = batch_key(brows, body)
        s3.put_object(Bucket=bucket, Key=key, Body=body, ContentType="application/x-ndjson")
        keep_keys.add(key)
        conn.execute("UPDATE clearledger.outbox SET archived_at = NOW() "
                     "WHERE seq = ANY(%s) AND archived_at IS NULL", (run,))
        log(f"s3: wrote {key} ({len(run)} row(s))")
        changes += 1

    # Purge everything that is not the single current version of a kept batch.
    versions, markers = list_versions(s3, bucket)
    doomed = [(v["Key"], v["VersionId"]) for v in versions
              if not (v.get("IsLatest") and v["Key"] in keep_keys)]
    doomed += [(m["Key"], m["VersionId"]) for m in markers]
    for i in range(0, len(doomed), 500):
        chunk = doomed[i:i + 500]
        s3.delete_objects(Bucket=bucket, Delete={
            "Objects": [{"Key": k, "VersionId": vid} for k, vid in chunk], "Quiet": True})
    if doomed:
        log(f"s3: purged {len(doomed)} stray/noncurrent version(s) and delete marker(s)")
        changes += len(doomed)
    return changes


def converge_s3(conn, deadline):
    s3 = client("s3")
    bucket = MAN["audit"]["bucket_name"]
    run_archiver(conn, deadline)
    for i in range(6):
        changes = s3_pass(conn, s3, bucket)
        if changes == 0:
            log(f"s3: archive converged (pass {i + 1})")
            return
        time.sleep(1)
    log("s3: archive still changing after 6 passes")


# ---------------------------------------------------------------------------
# 7. Valkey cache
# ---------------------------------------------------------------------------

def projection_json(row):
    (sid, acct, ref, dp, cp, status, stage, last_entry, last_memo, version, entry_count, updated) = row
    p = {"settlementId": sid, "accountId": acct, "reference": ref, "debitParty": dp,
         "creditParty": cp, "status": status, "clearingStage": stage}
    if last_entry is not None:
        p["lastEntryId"] = last_entry
    if last_memo is not None:
        p["lastMemo"] = last_memo
    p["version"] = version
    p["entryCount"] = entry_count
    p["updatedAt"] = rfc3339(updated, z=True)
    return json.dumps(p, separators=(",", ":"), ensure_ascii=False)


def converge_valkey(conn):
    r = redis.Redis(host=MAN["cache"]["endpoint"], port=int(MAN["cache"]["port"]),
                    socket_timeout=10, socket_connect_timeout=10)
    settlements, _ = load_pg(conn)
    want = {f"clearledger:settlement:{row[0]}": projection_json(row) for row in settlements}
    stray = [k for k in r.scan_iter(match="*", count=1000) if k.decode(errors="replace") not in want]
    for i in range(0, len(stray), 500):
        r.delete(*stray[i:i + 500])
    pipe = r.pipeline(transaction=False)
    for k, v in want.items():
        pipe.set(k, v, ex=CACHE_TTL)
    pipe.execute()
    log(f"valkey: populated {len(want)} key(s), purged {len(stray)} stray key(s)")


# ---------------------------------------------------------------------------

def main():
    start = time.time()
    budget = float(sys.argv[3]) if len(sys.argv) > 3 else 300.0
    deadline = start + budget

    converge_iam()
    converge_security_groups()

    with db() as conn:
        drain_outbox(conn, deadline)
        wait_queue_drained(min(deadline, time.time() + 60))
        converge_dynamodb(conn)
        converge_s3(conn, deadline)
        # Late outbox rows (live traffic) -> publish again before the final sweep.
        drain_outbox(conn, deadline)
        wait_queue_drained(min(deadline, time.time() + 30))
        converge_dynamodb(conn)
        converge_valkey(conn)
    log(f"done in {time.time() - start:.1f}s")


if __name__ == "__main__":
    main()
CLEARLEDGER_PY_EOF
}

# ---------------------------------------------------------------------------
# 1. Terraform / OpenTofu apply (creates, repairs drift, re-wires resources)
# ---------------------------------------------------------------------------
cd "${INFRA_DIR}"
log "initialising ${TF} in ${INFRA_DIR}"
"${TF}" init -input=false -no-color >"${WORK_DIR}/init.log" 2>&1 || { cat "${WORK_DIR}/init.log" >&2; die "${TF} init failed"; }

apply_ok=0
for attempt in 1 2 3; do
  log "${TF} apply (attempt ${attempt})"
  if "${TF}" apply -auto-approve -input=false -no-color -compact-warnings \
        -state="${INFRA_DIR}/terraform.tfstate" \
        -var "config_path=${CONFIG_PATH}" >"${WORK_DIR}/apply.log" 2>&1; then
    grep -E '^  # .* (will be|must be)|^(Plan:|Apply complete|No changes)' "${WORK_DIR}/apply.log" >&2 || true
    apply_ok=1
    break
  fi
  grep -vE 'Still (creating|modifying|destroying)' "${WORK_DIR}/apply.log" | tail -n 60 >&2
  sleep $(( attempt * 5 ))
done
[[ ${apply_ok} -eq 1 ]] || die "${TF} apply failed"

"${TF}" output -state="${INFRA_DIR}/terraform.tfstate" -json manifest >"${WORK_DIR}/manifest.json" \
  || die "unable to read manifest output"

# ---------------------------------------------------------------------------
# 2. Manifest export + schema validation
# ---------------------------------------------------------------------------
SCHEMA_PATH="${CLEARLEDGER_MANIFEST_SCHEMA:-/workspace/contracts/schemas/manifest.schema.json}"
python3 - "${WORK_DIR}/manifest.json" "${SCHEMA_PATH}" <<'PY'
import json, sys, os
m = json.load(open(sys.argv[1]))
if os.path.exists(sys.argv[2]):
    import jsonschema
    jsonschema.validate(m, json.load(open(sys.argv[2])))
PY
install -m 0600 "${WORK_DIR}/manifest.json" "${MANIFEST_PATH}.tmp"
mv -f "${MANIFEST_PATH}.tmp" "${MANIFEST_PATH}"
log "manifest written to ${MANIFEST_PATH}"

DB_HOST=$(jq -er '.database.endpoint' "${MANIFEST_PATH}")
DB_PORT=$(jq -er '.database.port' "${MANIFEST_PATH}")
SERVICE_URL=$(jq -er '.service_url' "${MANIFEST_PATH}")

# ---------------------------------------------------------------------------
# 3. PostgreSQL schema (idempotent)
# ---------------------------------------------------------------------------
export PGPASSWORD="${DB_PASSWORD}" PGCONNECT_TIMEOUT=5
log "waiting for PostgreSQL at ${DB_HOST}:${DB_PORT}"
for i in $(seq 1 90); do
  if psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -Atqc 'SELECT 1' >/dev/null 2>&1; then break; fi
  [[ $i -eq 90 ]] && die "PostgreSQL not reachable"
  sleep 2
done

write_schema_sql >"${WORK_DIR}/schema.sql"
schema_ok=0
for attempt in 1 2 3; do
  if psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -X -q \
       -v ON_ERROR_STOP=1 --single-transaction -f "${WORK_DIR}/schema.sql" >"${WORK_DIR}/schema.log" 2>&1; then
    schema_ok=1; break
  fi
  cat "${WORK_DIR}/schema.log" >&2
  sleep 3
done
[[ ${schema_ok} -eq 1 ]] || die "schema initialisation failed"
log "clearledger schema, constraints, triggers and indexes are in place"

# ---------------------------------------------------------------------------
# 4. Wait for the API behind the ALB
# ---------------------------------------------------------------------------
log "waiting for ${SERVICE_URL}/health/ready"
ready=0
while (( $(remaining) > 60 )); do
  code=$(curl -s -o "${WORK_DIR}/ready.json" -w '%{http_code}' -m 5 "${SERVICE_URL}/health/ready" || true)
  if [[ "${code}" == "200" ]]; then ready=1; break; fi
  sleep 3
done
[[ ${ready} -eq 1 ]] || die "API did not become ready (last status ${code:-none})"
log "API ready: $(cat "${WORK_DIR}/ready.json")"

# ---------------------------------------------------------------------------
# 5. Control-plane + data-plane convergence against PostgreSQL
# ---------------------------------------------------------------------------
write_converge_py >"${WORK_DIR}/converge.py"
budget=$(( $(remaining) - 15 ))
(( budget > 30 )) || budget=30
log "converging derived stores (budget ${budget}s)"
python3 "${WORK_DIR}/converge.py" "${CONFIG_PATH}" "${MANIFEST_PATH}" "${budget}" || die "convergence failed"

code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "${SERVICE_URL}/health/ready" || true)
[[ "${code}" == "200" ]] || die "API not ready after convergence (status ${code})"
log "deploy complete"
exit 0
