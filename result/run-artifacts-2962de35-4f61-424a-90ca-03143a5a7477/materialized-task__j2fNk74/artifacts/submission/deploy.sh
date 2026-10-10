#!/usr/bin/env bash
# ClearLedger deployment / repair / convergence entrypoint.
set -Eeuo pipefail

SUBMISSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${SUBMISSION_DIR}/infra"
CONFIG_FILE="${CLEARLEDGER_CONFIG:-/workspace/config/config.json}"
MANIFEST_FILE="${SUBMISSION_DIR}/manifest.json"
SCHEMA_FILE="/workspace/contracts/schemas/manifest.schema.json"
DEPLOY_START=$(date +%s)

log() { printf '[deploy %s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

[[ -f "${CONFIG_FILE}" ]] || die "config file ${CONFIG_FILE} not found"

cfg() { jq -r --arg k "$1" '.[$k] // empty' "${CONFIG_FILE}"; }

PREFIX="$(cfg resource_prefix)"
REGION="$(cfg region)"
ENDPOINT="$(cfg aws_endpoint_url)"
DB_NAME="$(cfg db_name)"
DB_USER="$(cfg db_username)"
DB_PASSWORD="$(cfg db_password)"
[[ -n "${PREFIX}" && -n "${REGION}" && -n "${ENDPOINT}" ]] || die "config is missing resource_prefix/region/aws_endpoint_url"
REGION="${REGION:-us-east-1}"

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_REGION="${REGION}" AWS_DEFAULT_REGION="${REGION}"
export AWS_ENDPOINT_URL="${ENDPOINT}"
export AWS_EC2_METADATA_DISABLED=true
export AWS_PAGER=""
export TF_IN_AUTOMATION=1
export TF_INPUT=0
export CHECKPOINT_DISABLE=1
export PYTHONUNBUFFERED=1
export CL_PREFIX="${PREFIX}" CL_REGION="${REGION}" CL_ENDPOINT="${ENDPOINT}"
export CL_DB_NAME="${DB_NAME}" CL_DB_USER="${DB_USER}" CL_DB_PASSWORD="${DB_PASSWORD}"
export CL_INFRA_DIR="${INFRA_DIR}"

if command -v terraform >/dev/null 2>&1; then TF=terraform
elif command -v tofu >/dev/null 2>&1; then TF=tofu
else die "neither terraform nor tofu is installed"; fi

WORK_DIR="$(mktemp -d /tmp/clearledger-deploy.XXXXXX)"
PROXY_PID=""
cleanup() {
  if [[ -n "${PROXY_PID}" ]]; then kill "${PROXY_PID}" >/dev/null 2>&1 || true; fi
  rm -rf "${WORK_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helper programs
# ---------------------------------------------------------------------------
cat > "${WORK_DIR}/proxy.py" <<'PYEOF'
# Minimal TCP forwarder. The AWS provider prefixes the account id to the S3
# Control endpoint host (<account>.<host>); *.localhost resolves to loopback,
# so we forward 127.0.0.1:<port> to the AWS endpoint.
import asyncio, sys
LPORT, RHOST, RPORT = int(sys.argv[1]), sys.argv[2], int(sys.argv[3])

async def pipe(r, w):
    try:
        while True:
            d = await r.read(65536)
            if not d:
                break
            w.write(d)
            await w.drain()
    except Exception:
        pass
    finally:
        try:
            w.close()
        except Exception:
            pass

async def handle(cr, cw):
    try:
        sr, sw = await asyncio.open_connection(RHOST, RPORT)
    except Exception:
        cw.close()
        return
    await asyncio.gather(pipe(cr, sw), pipe(sr, cw))

async def main():
    srv = await asyncio.start_server(handle, "127.0.0.1", LPORT)
    async with srv:
        await srv.serve_forever()

asyncio.run(main())
PYEOF

cat > "${WORK_DIR}/schema.sql" <<'SQLEOF'
-- ClearLedger PostgreSQL schema (idempotent)
SET client_min_messages = warning;
SELECT pg_advisory_lock(727274001);

CREATE SCHEMA IF NOT EXISTS clearledger;

-- ---------------------------------------------------------------------------
-- Helper functions
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION clearledger.cl_is_trimmed(v text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT v IS NULL OR (v = btrim(v) AND v !~ '^[[:space:]]' AND v !~ '[[:space:]]$')
$$;

CREATE OR REPLACE FUNCTION clearledger.cl_txt_ok(v text, min_len integer, max_len integer) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT v IS NOT NULL AND clearledger.cl_is_trimmed(v)
         AND char_length(v) BETWEEN min_len AND max_len
$$;

CREATE OR REPLACE FUNCTION clearledger.cl_is_uuid(v text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT v IS NOT NULL AND v ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
$$;

CREATE OR REPLACE FUNCTION clearledger.cl_status_rank(s text) RETURNS integer
LANGUAGE sql IMMUTABLE AS $$
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

CREATE OR REPLACE FUNCTION clearledger.cl_is_status(s text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT s IS NOT NULL AND s IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED')
$$;

CREATE OR REPLACE FUNCTION clearledger.cl_transition_ok(old_status text, new_status text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN old_status IS NULL OR new_status IS NULL THEN false
    WHEN NOT clearledger.cl_is_status(old_status) OR NOT clearledger.cl_is_status(new_status) THEN false
    WHEN old_status = 'RECONCILED' THEN false
    WHEN old_status = 'DISPUTED' THEN new_status IN ('DISPUTED', 'RECONCILED')
    WHEN new_status = 'DISPUTED' THEN true
    ELSE clearledger.cl_status_rank(new_status) >= clearledger.cl_status_rank(old_status)
  END
$$;

CREATE OR REPLACE FUNCTION clearledger.cl_is_timestamp(v text) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  t timestamptz;
BEGIN
  IF v IS NULL OR v !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt ][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?([Zz]|[+-][0-9]{2}:[0-9]{2})$' THEN
    RETURN false;
  END IF;
  t := v::timestamptz;
  RETURN t IS NOT NULL;
EXCEPTION WHEN OTHERS THEN
  RETURN false;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.cl_json_str(p jsonb, k text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN jsonb_typeof(p -> k) = 'string' THEN p ->> k ELSE NULL END
$$;

-- Strict validation of ClearLedgerDomainEventEnvelope (schemas/events.schema.json)
CREATE OR REPLACE FUNCTION clearledger.cl_valid_envelope(p jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  d jsonb;
  k text;
  v numeric;
  ver integer;
  etype text;
  kind text;
  st text;
  stage text;
  debit text;
  credit text;
  memo_t text;
  entry_t text;
BEGIN
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN RETURN false; END IF;

  -- additionalProperties: false + all required keys present
  FOR k IN SELECT jsonb_object_keys(p) LOOP
    IF k NOT IN ('schemaVersion','eventId','eventType','aggregateType','aggregateId',
                 'aggregateVersion','occurredAt','correlationId','idempotencyKey','data') THEN
      RETURN false;
    END IF;
  END LOOP;
  IF NOT (p ?& ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId',
                     'aggregateVersion','occurredAt','correlationId','idempotencyKey','data']) THEN
    RETURN false;
  END IF;

  IF clearledger.cl_json_str(p, 'schemaVersion') IS DISTINCT FROM '1.0' THEN RETURN false; END IF;
  IF NOT clearledger.cl_is_uuid(clearledger.cl_json_str(p, 'eventId')) THEN RETURN false; END IF;
  etype := clearledger.cl_json_str(p, 'eventType');
  IF etype IS NULL OR etype NOT IN ('SettlementInitiated', 'LedgerEntryRecorded') THEN RETURN false; END IF;
  IF clearledger.cl_json_str(p, 'aggregateType') IS DISTINCT FROM 'settlement' THEN RETURN false; END IF;
  IF NOT clearledger.cl_is_uuid(clearledger.cl_json_str(p, 'aggregateId')) THEN RETURN false; END IF;

  IF jsonb_typeof(p -> 'aggregateVersion') <> 'number' THEN RETURN false; END IF;
  v := (p ->> 'aggregateVersion')::numeric;
  IF v <> trunc(v) OR v < 1 OR v > 2147483647 THEN RETURN false; END IF;
  ver := v::integer;

  IF NOT clearledger.cl_is_timestamp(clearledger.cl_json_str(p, 'occurredAt')) THEN RETURN false; END IF;
  IF NOT clearledger.cl_txt_ok(clearledger.cl_json_str(p, 'correlationId'), 4, 128) THEN RETURN false; END IF;
  IF NOT clearledger.cl_txt_ok(clearledger.cl_json_str(p, 'idempotencyKey'), 8, 128) THEN RETURN false; END IF;

  d := p -> 'data';
  IF d IS NULL OR jsonb_typeof(d) <> 'object' THEN RETURN false; END IF;
  FOR k IN SELECT jsonb_object_keys(d) LOOP
    IF k NOT IN ('kind','accountId','reference','debitParty','creditParty','entryId','status','clearingStage','memo') THEN
      RETURN false;
    END IF;
  END LOOP;

  kind := clearledger.cl_json_str(d, 'kind');
  IF kind IS NULL OR kind NOT IN ('settlementInitiated', 'ledgerEntryRecorded') THEN RETURN false; END IF;
  IF NOT clearledger.cl_txt_ok(clearledger.cl_json_str(d, 'accountId'), 3, 64) THEN RETURN false; END IF;
  IF NOT clearledger.cl_txt_ok(clearledger.cl_json_str(d, 'reference'), 3, 64) THEN RETURN false; END IF;
  debit := clearledger.cl_json_str(d, 'debitParty');
  credit := clearledger.cl_json_str(d, 'creditParty');
  IF NOT clearledger.cl_txt_ok(debit, 2, 64) THEN RETURN false; END IF;
  IF NOT clearledger.cl_txt_ok(credit, 2, 64) THEN RETURN false; END IF;
  IF debit = credit THEN RETURN false; END IF;

  st := clearledger.cl_json_str(d, 'status');
  IF NOT clearledger.cl_is_status(st) THEN RETURN false; END IF;

  stage := clearledger.cl_json_str(d, 'clearingStage');
  IF stage IS NULL OR NOT clearledger.cl_is_trimmed(stage) OR char_length(stage) < 2 THEN RETURN false; END IF;

  -- entryId: uuid string or null
  IF d ? 'entryId' AND jsonb_typeof(d -> 'entryId') <> 'null' THEN
    IF jsonb_typeof(d -> 'entryId') <> 'string' THEN RETURN false; END IF;
    entry_t := d ->> 'entryId';
    IF NOT clearledger.cl_is_uuid(entry_t) THEN RETURN false; END IF;
  END IF;

  -- memo: string (1..256, trimmed) or null
  IF d ? 'memo' AND jsonb_typeof(d -> 'memo') <> 'null' THEN
    IF jsonb_typeof(d -> 'memo') <> 'string' THEN RETURN false; END IF;
    memo_t := d ->> 'memo';
    IF NOT clearledger.cl_txt_ok(memo_t, 1, 256) THEN RETURN false; END IF;
  END IF;

  -- version / kind / status / entryId coupling
  IF ver = 1 THEN
    IF etype <> 'SettlementInitiated' OR kind <> 'settlementInitiated' THEN RETURN false; END IF;
    IF st <> 'INITIATED' THEN RETURN false; END IF;
    IF entry_t IS NOT NULL THEN RETURN false; END IF;
    IF stage <> ('INITIATED@' || debit) THEN RETURN false; END IF;
    IF memo_t IS DISTINCT FROM 'Settlement initiated' THEN RETURN false; END IF;
  ELSE
    IF etype <> 'LedgerEntryRecorded' OR kind <> 'ledgerEntryRecorded' THEN RETURN false; END IF;
    IF st = 'INITIATED' THEN RETURN false; END IF;
    IF entry_t IS NULL THEN RETURN false; END IF;
    IF char_length(stage) > 64 THEN RETURN false; END IF;
  END IF;

  RETURN true;
EXCEPTION WHEN OTHERS THEN
  RETURN false;
END
$$;

-- Column-to-envelope equality (events & outbox)
CREATE OR REPLACE FUNCTION clearledger.cl_envelope_matches(
  p jsonb, p_event_id uuid, p_settlement_id uuid, p_version integer, p_correlation_id text
) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF NOT clearledger.cl_valid_envelope(p) THEN RETURN false; END IF;
  RETURN (p ->> 'eventId')::uuid = p_event_id
     AND (p ->> 'aggregateId')::uuid = p_settlement_id
     AND (p ->> 'aggregateVersion')::integer = p_version
     AND (p ->> 'correlationId') = p_correlation_id;
EXCEPTION WHEN OTHERS THEN
  RETURN false;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.cl_event_matches(
  p jsonb, p_event_id uuid, p_settlement_id uuid, p_version integer, p_event_type text,
  p_correlation_id text, p_idempotency_key text, p_occurred_at timestamptz
) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF NOT clearledger.cl_envelope_matches(p, p_event_id, p_settlement_id, p_version, p_correlation_id) THEN
    RETURN false;
  END IF;
  RETURN (p ->> 'eventType') = p_event_type
     AND (p ->> 'idempotencyKey') = p_idempotency_key
     AND (p ->> 'occurredAt')::timestamptz = p_occurred_at;
EXCEPTION WHEN OTHERS THEN
  RETURN false;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.cl_valid_write_response(r jsonb, p_scope text) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  k text;
  v numeric;
BEGIN
  IF r IS NULL OR jsonb_typeof(r) <> 'object' THEN RETURN false; END IF;
  FOR k IN SELECT jsonb_object_keys(r) LOOP
    IF k NOT IN ('settlementId','eventId','version','accepted','idempotentReplay') THEN RETURN false; END IF;
  END LOOP;
  IF NOT (r ?& ARRAY['settlementId','eventId','version','accepted','idempotentReplay']) THEN RETURN false; END IF;
  IF NOT clearledger.cl_is_uuid(clearledger.cl_json_str(r, 'settlementId')) THEN RETURN false; END IF;
  IF NOT clearledger.cl_is_uuid(clearledger.cl_json_str(r, 'eventId')) THEN RETURN false; END IF;
  IF jsonb_typeof(r -> 'version') <> 'number' THEN RETURN false; END IF;
  v := (r ->> 'version')::numeric;
  IF v <> trunc(v) OR v < 1 OR v > 2147483647 THEN RETURN false; END IF;
  IF r -> 'accepted' IS DISTINCT FROM 'true'::jsonb THEN RETURN false; END IF;
  IF r -> 'idempotentReplay' IS DISTINCT FROM 'false'::jsonb THEN RETURN false; END IF;
  IF p_scope IS NOT NULL AND lower(split_part(p_scope, ':', 2)) <> lower(r ->> 'settlementId') THEN
    RETURN false;
  END IF;
  RETURN true;
EXCEPTION WHEN OTHERS THEN
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

-- Re-assert NOT NULL / defaults in case of out-of-band drift
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('settlements','settlement_id'),('settlements','account_id'),('settlements','reference'),
    ('settlements','debit_party'),('settlements','credit_party'),('settlements','current_status'),
    ('settlements','current_stage'),('settlements','version'),('settlements','entry_count'),
    ('settlements','created_at'),('settlements','updated_at'),
    ('events','seq'),('events','event_id'),('events','settlement_id'),('events','aggregate_version'),
    ('events','event_type'),('events','correlation_id'),('events','idempotency_key'),
    ('events','occurred_at'),('events','payload'),('events','created_at'),
    ('outbox','seq'),('outbox','event_id'),('outbox','settlement_id'),('outbox','aggregate_version'),
    ('outbox','correlation_id'),('outbox','payload'),('outbox','created_at'),('outbox','attempts'),
    ('idempotency_keys','scope'),('idempotency_keys','idempotency_key'),('idempotency_keys','request_hash'),
    ('idempotency_keys','status_code'),('idempotency_keys','response_body'),('idempotency_keys','created_at')
  ) AS t(tbl, col) LOOP
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = 'clearledger' AND table_name = r.tbl AND column_name = r.col
                 AND is_nullable = 'YES') THEN
      EXECUTE format('ALTER TABLE clearledger.%I ALTER COLUMN %I SET NOT NULL', r.tbl, r.col);
    END IF;
  END LOOP;
END
$$;

ALTER TABLE clearledger.settlements ALTER COLUMN entry_count SET DEFAULT 0;
ALTER TABLE clearledger.settlements ALTER COLUMN created_at SET DEFAULT NOW();
ALTER TABLE clearledger.settlements ALTER COLUMN updated_at SET DEFAULT NOW();
ALTER TABLE clearledger.events ALTER COLUMN created_at SET DEFAULT NOW();
ALTER TABLE clearledger.outbox ALTER COLUMN created_at SET DEFAULT NOW();
ALTER TABLE clearledger.outbox ALTER COLUMN attempts SET DEFAULT 0;
ALTER TABLE clearledger.idempotency_keys ALTER COLUMN created_at SET DEFAULT NOW();

-- ---------------------------------------------------------------------------
-- Constraints (added when missing)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION clearledger.cl_ensure_constraint(p_table text, p_name text, p_def text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE n.nspname = 'clearledger' AND t.relname = p_table AND c.conname = p_name
  ) THEN
    EXECUTE format('ALTER TABLE clearledger.%I ADD CONSTRAINT %I %s', p_table, p_name, p_def);
  END IF;
END
$$;

-- settlements
SELECT clearledger.cl_ensure_constraint('settlements', 'settlements_pkey', 'PRIMARY KEY (settlement_id)');
SELECT clearledger.cl_ensure_constraint('settlements', 'settlements_account_id_chk',
  $c$CHECK (clearledger.cl_txt_ok(account_id, 3, 64))$c$);
SELECT clearledger.cl_ensure_constraint('settlements', 'settlements_reference_chk',
  $c$CHECK (clearledger.cl_txt_ok(reference, 3, 64))$c$);
SELECT clearledger.cl_ensure_constraint('settlements', 'settlements_debit_party_chk',
  $c$CHECK (clearledger.cl_txt_ok(debit_party, 2, 64))$c$);
SELECT clearledger.cl_ensure_constraint('settlements', 'settlements_credit_party_chk',
  $c$CHECK (clearledger.cl_txt_ok(credit_party, 2, 64))$c$);
SELECT clearledger.cl_ensure_constraint('settlements', 'settlements_parties_distinct_chk',
  $c$CHECK (debit_party <> credit_party)$c$);
SELECT clearledger.cl_ensure_constraint('settlements', 'settlements_status_chk',
  $c$CHECK (current_status IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED'))$c$);
SELECT clearledger.cl_ensure_constraint('settlements', 'settlements_stage_chk',
  $c$CHECK (clearledger.cl_is_trimmed(current_stage) AND char_length(current_stage) >= 2
            AND (version = 1 OR char_length(current_stage) <= 64))$c$);
SELECT clearledger.cl_ensure_constraint('settlements', 'settlements_last_memo_chk',
  $c$CHECK (last_memo IS NULL OR clearledger.cl_txt_ok(last_memo, 1, 256))$c$);
SELECT clearledger.cl_ensure_constraint('settlements', 'settlements_version_chk',
  $c$CHECK (version >= 1 AND entry_count >= 0)$c$);
SELECT clearledger.cl_ensure_constraint('settlements', 'settlements_initiation_chk',
  $c$CHECK (version <> 1 OR (
      entry_count = 0
      AND current_status = 'INITIATED'
      AND current_stage = 'INITIATED@' || debit_party
      AND last_entry_id IS NULL
      AND last_memo IS NOT DISTINCT FROM 'Settlement initiated'
      AND updated_at = created_at))$c$);
SELECT clearledger.cl_ensure_constraint('settlements', 'settlements_progress_chk',
  $c$CHECK (version <= 1 OR (
      entry_count = version - 1
      AND current_status <> 'INITIATED'
      AND last_entry_id IS NOT NULL
      AND updated_at > created_at))$c$);

-- events
SELECT clearledger.cl_ensure_constraint('events', 'events_pkey', 'PRIMARY KEY (seq)');
SELECT clearledger.cl_ensure_constraint('events', 'events_event_id_key', 'UNIQUE (event_id)');
SELECT clearledger.cl_ensure_constraint('events', 'events_settlement_version_key', 'UNIQUE (settlement_id, aggregate_version)');
SELECT clearledger.cl_ensure_constraint('events', 'events_settlement_idempotency_key', 'UNIQUE (settlement_id, idempotency_key)');
SELECT clearledger.cl_ensure_constraint('events', 'events_settlement_id_fkey',
  'FOREIGN KEY (settlement_id) REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE');
SELECT clearledger.cl_ensure_constraint('events', 'events_version_chk', $c$CHECK (aggregate_version >= 1)$c$);
SELECT clearledger.cl_ensure_constraint('events', 'events_event_type_chk',
  $c$CHECK (event_type IN ('SettlementInitiated','LedgerEntryRecorded')
            AND ((aggregate_version = 1) = (event_type = 'SettlementInitiated')))$c$);
SELECT clearledger.cl_ensure_constraint('events', 'events_correlation_id_chk',
  $c$CHECK (clearledger.cl_txt_ok(correlation_id, 4, 128))$c$);
SELECT clearledger.cl_ensure_constraint('events', 'events_idempotency_key_chk',
  $c$CHECK (clearledger.cl_txt_ok(idempotency_key, 8, 128))$c$);
SELECT clearledger.cl_ensure_constraint('events', 'events_payload_envelope_chk',
  $c$CHECK (clearledger.cl_event_matches(payload, event_id, settlement_id, aggregate_version, event_type,
                                          correlation_id, idempotency_key, occurred_at))$c$);

-- outbox
SELECT clearledger.cl_ensure_constraint('outbox', 'outbox_pkey', 'PRIMARY KEY (seq)');
SELECT clearledger.cl_ensure_constraint('outbox', 'outbox_event_id_key', 'UNIQUE (event_id)');
SELECT clearledger.cl_ensure_constraint('outbox', 'outbox_settlement_version_key', 'UNIQUE (settlement_id, aggregate_version)');
SELECT clearledger.cl_ensure_constraint('outbox', 'outbox_event_id_fkey',
  'FOREIGN KEY (event_id) REFERENCES clearledger.events(event_id) ON DELETE CASCADE');
SELECT clearledger.cl_ensure_constraint('outbox', 'outbox_settlement_id_fkey',
  'FOREIGN KEY (settlement_id) REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE');
SELECT clearledger.cl_ensure_constraint('outbox', 'outbox_event_version_fkey',
  'FOREIGN KEY (settlement_id, aggregate_version) REFERENCES clearledger.events(settlement_id, aggregate_version) ON DELETE CASCADE');
SELECT clearledger.cl_ensure_constraint('outbox', 'outbox_version_chk', $c$CHECK (aggregate_version >= 1)$c$);
SELECT clearledger.cl_ensure_constraint('outbox', 'outbox_correlation_id_chk',
  $c$CHECK (clearledger.cl_txt_ok(correlation_id, 4, 128))$c$);
SELECT clearledger.cl_ensure_constraint('outbox', 'outbox_payload_envelope_chk',
  $c$CHECK (clearledger.cl_envelope_matches(payload, event_id, settlement_id, aggregate_version, correlation_id))$c$);
SELECT clearledger.cl_ensure_constraint('outbox', 'outbox_attempts_chk', $c$CHECK (attempts >= 0)$c$);
SELECT clearledger.cl_ensure_constraint('outbox', 'outbox_unattempted_chk',
  $c$CHECK (attempts <> 0 OR (published_at IS NULL AND last_error IS NULL))$c$);
SELECT clearledger.cl_ensure_constraint('outbox', 'outbox_published_chk',
  $c$CHECK (published_at IS NULL OR (attempts >= 1 AND last_error IS NULL AND published_at >= created_at))$c$);
SELECT clearledger.cl_ensure_constraint('outbox', 'outbox_last_error_chk',
  $c$CHECK (last_error IS NULL OR (published_at IS NULL AND attempts >= 1
            AND length(btrim(last_error)) > 0 AND last_error = btrim(last_error)))$c$);
SELECT clearledger.cl_ensure_constraint('outbox', 'outbox_archived_chk',
  $c$CHECK (archived_at IS NULL OR (published_at IS NOT NULL AND archived_at >= published_at))$c$);

-- idempotency_keys
SELECT clearledger.cl_ensure_constraint('idempotency_keys', 'idempotency_keys_pkey', 'PRIMARY KEY (scope, idempotency_key)');
SELECT clearledger.cl_ensure_constraint('idempotency_keys', 'idempotency_keys_scope_chk',
  $c$CHECK (scope ~* '^(create|entry):[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')$c$);
SELECT clearledger.cl_ensure_constraint('idempotency_keys', 'idempotency_keys_key_chk',
  $c$CHECK (clearledger.cl_txt_ok(idempotency_key, 8, 128))$c$);
SELECT clearledger.cl_ensure_constraint('idempotency_keys', 'idempotency_keys_request_hash_chk',
  $c$CHECK (request_hash ~ '^[0-9a-f]{64}$')$c$);
SELECT clearledger.cl_ensure_constraint('idempotency_keys', 'idempotency_keys_response_chk',
  $c$CHECK (clearledger.cl_valid_write_response(response_body, scope))$c$);
SELECT clearledger.cl_ensure_constraint('idempotency_keys', 'idempotency_keys_status_code_chk',
  $c$CHECK (
      (scope LIKE 'create:%' AND status_code = 201
        AND jsonb_typeof(response_body -> 'version') = 'number' AND response_body ->> 'version' = '1')
   OR (scope LIKE 'entry:%' AND status_code = 202
        AND jsonb_typeof(response_body -> 'version') = 'number' AND response_body ->> 'version' ~ '^[0-9]+$'
        AND (response_body ->> 'version')::numeric >= 2))$c$);

-- ---------------------------------------------------------------------------
-- Trigger functions
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION clearledger.trg_settlements_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'clearledger.settlements is append-only: DELETE is not permitted (settlement %)', OLD.settlement_id
      USING ERRCODE = 'P0001';
  END IF;

  IF TG_OP = 'UPDATE' THEN
    IF NEW.settlement_id IS DISTINCT FROM OLD.settlement_id
       OR NEW.account_id IS DISTINCT FROM OLD.account_id
       OR NEW.reference IS DISTINCT FROM OLD.reference
       OR NEW.debit_party IS DISTINCT FROM OLD.debit_party
       OR NEW.credit_party IS DISTINCT FROM OLD.credit_party
       OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
      RAISE EXCEPTION 'settlement header columns are immutable' USING ERRCODE = 'P0001';
    END IF;
    IF OLD.current_status = 'RECONCILED' THEN
      RAISE EXCEPTION 'settlement % is RECONCILED (terminal)', OLD.settlement_id USING ERRCODE = 'P0001';
    END IF;
    IF NEW.version IS DISTINCT FROM OLD.version + 1 THEN
      RAISE EXCEPTION 'settlement version must advance by exactly 1 (% -> %)', OLD.version, NEW.version
        USING ERRCODE = 'P0001';
    END IF;
    IF NEW.entry_count IS DISTINCT FROM OLD.entry_count + 1 THEN
      RAISE EXCEPTION 'settlement entry_count must advance by exactly 1' USING ERRCODE = 'P0001';
    END IF;
    IF NEW.last_entry_id IS NULL OR NEW.last_entry_id IS NOT DISTINCT FROM OLD.last_entry_id THEN
      RAISE EXCEPTION 'settlement update requires a new last_entry_id' USING ERRCODE = 'P0001';
    END IF;
    IF NOT (NEW.updated_at > OLD.updated_at) THEN
      RAISE EXCEPTION 'settlement updated_at must strictly increase' USING ERRCODE = 'P0001';
    END IF;
    IF NOT clearledger.cl_transition_ok(OLD.current_status, NEW.current_status) THEN
      RAISE EXCEPTION 'illegal settlement status transition % -> %', OLD.current_status, NEW.current_status
        USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
  END IF;

  RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.trg_events_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  s clearledger.settlements%ROWTYPE;
  max_ver integer;
  prev record;
  d jsonb;
  entry_t text;
BEGIN
  IF TG_OP IN ('UPDATE', 'DELETE') THEN
    RAISE EXCEPTION 'clearledger.events is append-only: % is not permitted', TG_OP USING ERRCODE = 'P0001';
  END IF;

  IF NOT clearledger.cl_event_matches(NEW.payload, NEW.event_id, NEW.settlement_id, NEW.aggregate_version,
                                      NEW.event_type, NEW.correlation_id, NEW.idempotency_key, NEW.occurred_at) THEN
    RAISE EXCEPTION 'event payload does not conform to ClearLedgerDomainEventEnvelope or mismatches columns'
      USING ERRCODE = '23514';
  END IF;

  d := NEW.payload -> 'data';
  entry_t := CASE WHEN jsonb_typeof(d -> 'entryId') = 'string' THEN d ->> 'entryId' ELSE NULL END;

  SELECT * INTO s FROM clearledger.settlements WHERE settlement_id = NEW.settlement_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'settlement % does not exist', NEW.settlement_id USING ERRCODE = '23503';
  END IF;

  SELECT max(aggregate_version) INTO max_ver FROM clearledger.events WHERE settlement_id = NEW.settlement_id;
  IF NEW.aggregate_version IS DISTINCT FROM COALESCE(max_ver, 0) + 1 THEN
    RAISE EXCEPTION 'event aggregate_version % is not contiguous (expected %)', NEW.aggregate_version, COALESCE(max_ver, 0) + 1
      USING ERRCODE = 'P0001';
  END IF;

  IF entry_t IS NOT NULL AND EXISTS (
      SELECT 1 FROM clearledger.events e
      WHERE e.settlement_id = NEW.settlement_id
        AND e.event_type = 'LedgerEntryRecorded'
        AND lower(e.payload -> 'data' ->> 'entryId') = lower(entry_t)) THEN
    RAISE EXCEPTION 'entryId % already recorded for settlement %', entry_t, NEW.settlement_id USING ERRCODE = 'P0001';
  END IF;

  IF s.account_id IS DISTINCT FROM d ->> 'accountId'
     OR s.reference IS DISTINCT FROM d ->> 'reference'
     OR s.debit_party IS DISTINCT FROM d ->> 'debitParty'
     OR s.credit_party IS DISTINCT FROM d ->> 'creditParty'
     OR s.current_status IS DISTINCT FROM d ->> 'status'
     OR s.current_stage IS DISTINCT FROM d ->> 'clearingStage'
     OR s.last_entry_id IS DISTINCT FROM entry_t::uuid
     OR s.last_memo IS DISTINCT FROM (CASE WHEN jsonb_typeof(d -> 'memo') = 'string' THEN d ->> 'memo' ELSE NULL END)
     OR s.version IS DISTINCT FROM NEW.aggregate_version
     OR s.updated_at IS DISTINCT FROM NEW.occurred_at THEN
    RAISE EXCEPTION 'event does not match settlement % state', NEW.settlement_id USING ERRCODE = 'P0001';
  END IF;

  IF NEW.aggregate_version = 1 THEN
    IF s.created_at IS DISTINCT FROM NEW.occurred_at THEN
      RAISE EXCEPTION 'initiation event occurred_at must equal settlement created_at' USING ERRCODE = 'P0001';
    END IF;
  ELSE
    SELECT e.occurred_at, e.payload -> 'data' ->> 'status' AS status INTO prev
      FROM clearledger.events e
     WHERE e.settlement_id = NEW.settlement_id AND e.aggregate_version = NEW.aggregate_version - 1;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'preceding event missing' USING ERRCODE = 'P0001';
    END IF;
    IF NOT (NEW.occurred_at > prev.occurred_at) THEN
      RAISE EXCEPTION 'event occurred_at must be strictly after the preceding event' USING ERRCODE = 'P0001';
    END IF;
    IF NOT clearledger.cl_transition_ok(prev.status, d ->> 'status') THEN
      RAISE EXCEPTION 'illegal status transition % -> %', prev.status, d ->> 'status' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.trg_outbox_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  e record;
  max_ver integer;
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'clearledger.outbox rows cannot be deleted' USING ERRCODE = 'P0001';
  END IF;

  IF TG_OP = 'INSERT' THEN
    SELECT ev.event_id, ev.settlement_id, ev.aggregate_version, ev.correlation_id, ev.payload INTO e
      FROM clearledger.events ev WHERE ev.event_id = NEW.event_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'outbox event % does not exist in clearledger.events', NEW.event_id USING ERRCODE = '23503';
    END IF;
    IF e.settlement_id IS DISTINCT FROM NEW.settlement_id
       OR e.aggregate_version IS DISTINCT FROM NEW.aggregate_version
       OR e.correlation_id IS DISTINCT FROM NEW.correlation_id
       OR e.payload IS DISTINCT FROM NEW.payload THEN
      RAISE EXCEPTION 'outbox row must mirror clearledger.events row %', NEW.event_id USING ERRCODE = 'P0001';
    END IF;
    SELECT max(aggregate_version) INTO max_ver FROM clearledger.outbox WHERE settlement_id = NEW.settlement_id;
    IF NEW.aggregate_version IS DISTINCT FROM COALESCE(max_ver, 0) + 1 THEN
      RAISE EXCEPTION 'outbox aggregate_version % is not contiguous', NEW.aggregate_version USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
  END IF;

  -- UPDATE
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
    -- publishing
    IF NEW.attempts <= OLD.attempts THEN
      RAISE EXCEPTION 'publishing an outbox row requires incrementing attempts' USING ERRCODE = 'P0001';
    END IF;
    IF NEW.archived_at IS NOT NULL THEN
      RAISE EXCEPTION 'cannot archive while publishing' USING ERRCODE = 'P0001';
    END IF;
  ELSIF OLD.published_at IS NOT NULL AND NEW.published_at IS NOT NULL THEN
    IF NEW.published_at IS DISTINCT FROM OLD.published_at
       OR NEW.attempts IS DISTINCT FROM OLD.attempts
       OR NEW.last_error IS DISTINCT FROM OLD.last_error THEN
      RAISE EXCEPTION 'published outbox delivery columns are immutable' USING ERRCODE = 'P0001';
    END IF;
    IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NOT NULL
       AND NEW.archived_at IS DISTINCT FROM OLD.archived_at THEN
      RAISE EXCEPTION 'archived_at cannot be changed without first resetting it to NULL' USING ERRCODE = 'P0001';
    END IF;
  ELSIF OLD.published_at IS NOT NULL AND NEW.published_at IS NULL THEN
    -- operational replay reset
    IF NEW.archived_at IS NOT NULL THEN
      RAISE EXCEPTION 'replay reset requires archived_at = NULL' USING ERRCODE = 'P0001';
    END IF;
  ELSE
    -- unpublished -> unpublished (delivery failure bookkeeping)
    IF NEW.archived_at IS NOT NULL THEN
      RAISE EXCEPTION 'unpublished outbox rows cannot be archived' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.trg_idempotency_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  r jsonb;
  ev_id uuid;
  st_id uuid;
  ver integer;
BEGIN
  IF TG_OP IN ('UPDATE', 'DELETE') THEN
    RAISE EXCEPTION 'clearledger.idempotency_keys is immutable: % is not permitted', TG_OP USING ERRCODE = 'P0001';
  END IF;

  r := NEW.response_body;
  IF NOT clearledger.cl_valid_write_response(r, NEW.scope) THEN
    RAISE EXCEPTION 'idempotency response_body is not a valid WriteAcceptedResponse' USING ERRCODE = '23514';
  END IF;
  ev_id := (r ->> 'eventId')::uuid;
  st_id := (r ->> 'settlementId')::uuid;
  ver := (r ->> 'version')::integer;

  IF NOT EXISTS (SELECT 1 FROM clearledger.events e
                 WHERE e.event_id = ev_id AND e.settlement_id = st_id
                   AND e.aggregate_version = ver AND e.idempotency_key = NEW.idempotency_key) THEN
    RAISE EXCEPTION 'idempotency record references unknown event %', ev_id USING ERRCODE = '23503';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM clearledger.outbox o
                 WHERE o.event_id = ev_id AND o.settlement_id = st_id AND o.aggregate_version = ver) THEN
    RAISE EXCEPTION 'idempotency record references event % missing from outbox', ev_id USING ERRCODE = '23503';
  END IF;
  IF EXISTS (SELECT 1 FROM clearledger.idempotency_keys k
             WHERE (k.response_body ->> 'eventId')::uuid = ev_id) THEN
    RAISE EXCEPTION 'eventId % already has an idempotency record', ev_id USING ERRCODE = '23505';
  END IF;
  IF EXISTS (SELECT 1 FROM clearledger.idempotency_keys k
             WHERE (k.response_body ->> 'settlementId')::uuid = st_id
               AND (k.response_body ->> 'version')::integer = ver) THEN
    RAISE EXCEPTION 'settlement % version % already has an idempotency record', st_id, ver USING ERRCODE = '23505';
  END IF;
  RETURN NEW;
END
$$;

-- ---------------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TRIGGER trg_settlements_guard
  BEFORE UPDATE OR DELETE ON clearledger.settlements
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_settlements_guard();

CREATE OR REPLACE TRIGGER trg_events_guard
  BEFORE INSERT OR UPDATE OR DELETE ON clearledger.events
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_events_guard();

CREATE OR REPLACE TRIGGER trg_outbox_guard
  BEFORE INSERT OR UPDATE OR DELETE ON clearledger.outbox
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_outbox_guard();

CREATE OR REPLACE TRIGGER trg_idempotency_guard
  BEFORE INSERT OR UPDATE OR DELETE ON clearledger.idempotency_keys
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_idempotency_guard();

ALTER TABLE clearledger.settlements ENABLE TRIGGER USER;
ALTER TABLE clearledger.events ENABLE TRIGGER USER;
ALTER TABLE clearledger.outbox ENABLE TRIGGER USER;
ALTER TABLE clearledger.idempotency_keys ENABLE TRIGGER USER;

DO $$
BEGIN
  ALTER TABLE clearledger.settlements ENABLE TRIGGER ALL;
  ALTER TABLE clearledger.events ENABLE TRIGGER ALL;
  ALTER TABLE clearledger.outbox ENABLE TRIGGER ALL;
  ALTER TABLE clearledger.idempotency_keys ENABLE TRIGGER ALL;
EXCEPTION WHEN insufficient_privilege THEN
  NULL;
END
$$;

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  r record;
  def text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('idx_clearledger_outbox_unpublished',
     'CREATE INDEX idx_clearledger_outbox_unpublished ON clearledger.outbox USING btree (seq) WHERE (published_at IS NULL)'),
    ('idx_clearledger_outbox_unarchived',
     'CREATE INDEX idx_clearledger_outbox_unarchived ON clearledger.outbox USING btree (seq) WHERE ((published_at IS NOT NULL) AND (archived_at IS NULL))'),
    ('idx_clearledger_events_settlement_version',
     'CREATE INDEX idx_clearledger_events_settlement_version ON clearledger.events USING btree (settlement_id, aggregate_version)')
  ) AS t(name, ddl) LOOP
    SELECT indexdef INTO def FROM pg_indexes WHERE schemaname = 'clearledger' AND indexname = r.name;
    IF def IS NULL THEN
      EXECUTE r.ddl;
    ELSIF def <> r.ddl THEN
      EXECUTE format('DROP INDEX clearledger.%I', r.name);
      EXECUTE r.ddl;
    END IF;
  END LOOP;
END
$$;

-- Repair invalid indexes (e.g. failed concurrent builds)
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT c.relname FROM pg_index i
           JOIN pg_class c ON c.oid = i.indexrelid
           JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname = 'clearledger' AND NOT i.indisvalid LOOP
    EXECUTE format('REINDEX INDEX clearledger.%I', r.relname);
  END LOOP;
END
$$;

SELECT pg_advisory_unlock(727274001);
SQLEOF

cat > "${WORK_DIR}/ops.py" <<'PYEOF'
#!/usr/bin/env python3
"""ClearLedger operational helper: drift repair and data-plane convergence."""
import datetime
import hashlib
import json
import os
import re
import sys
import time

import boto3
from botocore.config import Config

PREFIX = os.environ["CL_PREFIX"]
REGION = os.environ.get("CL_REGION", "us-east-1")
ENDPOINT = os.environ["CL_ENDPOINT"]
INFRA_DIR = os.environ.get("CL_INFRA_DIR", "/workspace/submission/infra")

BOTO_CFG = Config(retries={"max_attempts": 8, "mode": "standard"}, connect_timeout=10, read_timeout=60)


def log(msg):
    print(f"[ops {datetime.datetime.utcnow():%H:%M:%S}] {msg}", file=sys.stderr, flush=True)


def client(name):
    return boto3.client(
        name,
        endpoint_url=ENDPOINT,
        region_name=REGION,
        aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID", "test"),
        aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY", "test"),
        config=BOTO_CFG,
    )


def outputs():
    path = os.environ.get("CL_OUTPUTS")
    if not path or not os.path.exists(path):
        return {}
    raw = json.load(open(path))
    return {k: v.get("value") for k, v in raw.items()}


def manifest():
    return json.load(open(os.environ["CL_MANIFEST"]))


def tfstate_resources():
    path = os.path.join(INFRA_DIR, "terraform.tfstate")
    if not os.path.exists(path):
        return []
    try:
        st = json.load(open(path))
    except Exception:
        return []
    return st.get("resources", [])


# ---------------------------------------------------------------------------
# pre-apply: KMS key repair
# ---------------------------------------------------------------------------
def preapply():
    kms = client("kms")
    key_ids = set()
    for res in tfstate_resources():
        if res.get("type") == "aws_kms_key" and res.get("mode") == "managed":
            for inst in res.get("instances", []):
                kid = inst.get("attributes", {}).get("key_id") or inst.get("attributes", {}).get("id")
                if kid:
                    key_ids.add(kid)
    try:
        for page in kms.get_paginator("list_aliases").paginate():
            for a in page.get("Aliases", []):
                if a.get("AliasName", "").startswith(f"alias/{PREFIX}-") and a.get("TargetKeyId"):
                    key_ids.add(a["TargetKeyId"])
    except Exception as e:  # noqa
        log(f"list_aliases failed: {e}")
    for kid in sorted(key_ids):
        try:
            meta = kms.describe_key(KeyId=kid)["KeyMetadata"]
        except Exception as e:
            log(f"describe_key {kid}: {e}")
            continue
        state = meta.get("KeyState")
        if state == "PendingDeletion":
            log(f"cancelling scheduled deletion of KMS key {kid}")
            kms.cancel_key_deletion(KeyId=kid)
            state = kms.describe_key(KeyId=kid)["KeyMetadata"].get("KeyState")
        if state == "Disabled":
            log(f"re-enabling KMS key {kid}")
            kms.enable_key(KeyId=kid)
        try:
            if not kms.get_key_rotation_status(KeyId=kid).get("KeyRotationEnabled"):
                kms.enable_key_rotation(KeyId=kid)
        except Exception:
            pass


# ---------------------------------------------------------------------------
# post-apply: IAM + security group drift
# ---------------------------------------------------------------------------
def delete_managed_policy(iam, arn):
    try:
        for v in iam.list_policy_versions(PolicyArn=arn).get("Versions", []):
            if not v.get("IsDefaultVersion"):
                iam.delete_policy_version(PolicyArn=arn, VersionId=v["VersionId"])
    except Exception as e:
        log(f"list/delete policy versions {arn}: {e}")
    iam.delete_policy(PolicyArn=arn)


def repair_iam():
    out = outputs()
    iam = client("iam")
    role_names = out.get("role_names") or {}
    canonical = out.get("role_policy_names") or {}
    for key, role in role_names.items():
        keep = canonical.get(key)
        try:
            names = []
            for page in iam.get_paginator("list_role_policies").paginate(RoleName=role):
                names.extend(page.get("PolicyNames", []))
            for n in names:
                if n != keep:
                    log(f"removing out-of-band inline policy {n} from {role}")
                    iam.delete_role_policy(RoleName=role, PolicyName=n)
            attached = []
            for page in iam.get_paginator("list_attached_role_policies").paginate(RoleName=role):
                attached.extend(page.get("AttachedPolicies", []))
            for p in attached:
                log(f"detaching out-of-band managed policy {p['PolicyArn']} from {role}")
                iam.detach_role_policy(RoleName=role, PolicyArn=p["PolicyArn"])
            r = iam.get_role(RoleName=role)["Role"]
            if r.get("PermissionsBoundary"):
                log(f"removing out-of-band permissions boundary from {role}")
                iam.delete_role_permissions_boundary(RoleName=role)
        except iam.exceptions.NoSuchEntityException:
            log(f"role {role} missing (terraform should have recreated it)")
    # prefixed customer-managed policies that are not attached anywhere
    try:
        pols = []
        for page in iam.get_paginator("list_policies").paginate(Scope="Local"):
            pols.extend(page.get("Policies", []))
    except Exception as e:
        log(f"list_policies failed: {e}")
        pols = []
    for p in pols:
        if not p.get("PolicyName", "").startswith(PREFIX):
            continue
        arn = p["Arn"]
        try:
            ents = iam.list_entities_for_policy(PolicyArn=arn)
            attached = ents.get("PolicyRoles", []) + ents.get("PolicyUsers", []) + ents.get("PolicyGroups", [])
            ours = set(role_names.values())
            for r in ents.get("PolicyRoles", []):
                if r["RoleName"] in ours:
                    iam.detach_role_policy(RoleName=r["RoleName"], PolicyArn=arn)
                    attached = [a for a in attached if a.get("RoleName") != r["RoleName"]]
            if not attached:
                log(f"deleting unattached prefixed policy {arn}")
                delete_managed_policy(iam, arn)
        except Exception as e:
            log(f"policy cleanup {arn}: {e}")


PUBLIC = ("0.0.0.0/0", "::/0")


def _strip(perm, keep_fn):
    """Return a revoke-able permission containing only ranges selected by keep_fn."""
    p = {k: perm[k] for k in ("IpProtocol", "FromPort", "ToPort") if k in perm}
    v4 = [r for r in perm.get("IpRanges", []) if keep_fn(r.get("CidrIp"))]
    v6 = [r for r in perm.get("Ipv6Ranges", []) if keep_fn(r.get("CidrIpv6"))]
    if not v4 and not v6:
        return None
    if v4:
        p["IpRanges"] = [{"CidrIp": r["CidrIp"]} for r in v4]
    if v6:
        p["Ipv6Ranges"] = [{"CidrIpv6": r["CidrIpv6"]} for r in v6]
    return p


def repair_security_groups():
    m = manifest()
    sgs = m["network"]["security_group_ids"]
    ec2 = client("ec2")
    for role, sg in sgs.items():
        try:
            g = ec2.describe_security_groups(GroupIds=[sg])["SecurityGroups"][0]
        except Exception as e:
            log(f"describe sg {sg}: {e}")
            continue
        if role in ("ecs", "rds", "valkey"):
            for perm in g.get("IpPermissions", []):
                if role == "ecs":
                    bad = _strip(perm, lambda c: c is not None)  # ecs ingress: SG-sourced only
                else:
                    bad = _strip(perm, lambda c: c in PUBLIC)
                if bad:
                    log(f"revoking out-of-band ingress on {role} sg {sg}: {bad}")
                    try:
                        ec2.revoke_security_group_ingress(GroupId=sg, IpPermissions=[bad])
                    except Exception as e:
                        log(f"revoke ingress failed: {e}")
        if role in ("rds", "valkey"):
            perms = g.get("IpPermissionsEgress", [])
            if perms:
                log(f"revoking out-of-band egress on {role} sg {sg}")
                for perm in perms:
                    clean = {k: v for k, v in perm.items() if k in (
                        "IpProtocol", "FromPort", "ToPort", "IpRanges", "Ipv6Ranges", "UserIdGroupPairs", "PrefixListIds")}
                    for k in ("IpRanges", "Ipv6Ranges", "UserIdGroupPairs", "PrefixListIds"):
                        if k in clean and not clean[k]:
                            del clean[k]
                    try:
                        ec2.revoke_security_group_egress(GroupId=sg, IpPermissions=[clean])
                    except Exception as e:
                        log(f"revoke egress failed: {e}")
        if role == "alb":
            for perm in g.get("IpPermissionsEgress", []):
                bad = _strip(perm, lambda c: c in PUBLIC)
                if bad:
                    log(f"revoking public egress on alb sg {sg}")
                    try:
                        ec2.revoke_security_group_egress(GroupId=sg, IpPermissions=[bad])
                    except Exception as e:
                        log(f"revoke egress failed: {e}")


def postapply():
    repair_iam()
    repair_security_groups()


# ---------------------------------------------------------------------------
# converge: data plane
# ---------------------------------------------------------------------------
ENV_ORDER = ["schemaVersion", "eventId", "eventType", "aggregateType", "aggregateId",
             "aggregateVersion", "occurredAt", "correlationId", "idempotencyKey", "data"]
DATA_ORDER = ["kind", "accountId", "reference", "debitParty", "creditParty",
              "entryId", "status", "clearingStage", "memo"]
BATCH_RE = re.compile(r"^ledger-audit/batch-(\d{8})-(\d{8})-([0-9a-f]{16})\.ndjson$")
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
AUDIT_PREFIX = "ledger-audit/"
AUDIT_BATCH = 100
CACHE_TTL = 90


def _ordered(obj, order):
    out = {}
    for k in order:
        if k in obj:
            out[k] = obj[k]
    for k in sorted(obj):
        if k not in out:
            out[k] = obj[k]
    return out


def canonical_envelope(payload):
    env = _ordered(payload, ENV_ORDER)
    if isinstance(env.get("data"), dict):
        env["data"] = _ordered(env["data"], DATA_ORDER)
    return json.dumps(env, separators=(",", ":"), ensure_ascii=False)


def _frac(dt):
    us = dt.microsecond
    if us == 0:
        return ""
    if us % 1000 == 0:
        return ".%03d" % (us // 1000)
    return ".%06d" % us


def ts_offset(dt):
    dt = dt.astimezone(datetime.timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%S") + _frac(dt) + "+00:00"


def ts_z(dt):
    dt = dt.astimezone(datetime.timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%S") + _frac(dt) + "Z"


def pg_connect():
    import psycopg2
    import psycopg2.extras  # noqa
    last = None
    for _ in range(30):
        try:
            conn = psycopg2.connect(
                host=os.environ["CL_DB_HOST"], port=int(os.environ["CL_DB_PORT"]),
                dbname=os.environ["CL_DB_NAME"], user=os.environ["CL_DB_USER"],
                password=os.environ["CL_DB_PASSWORD"], connect_timeout=10,
                application_name="clearledger-deploy")
            return conn
        except Exception as e:
            last = e
            time.sleep(2)
    raise last


def load_pg(conn):
    with conn.cursor() as cur:
        cur.execute("""
            SELECT settlement_id::text, account_id, reference, debit_party, credit_party,
                   current_status, current_stage, last_entry_id::text, last_memo, version,
                   entry_count, created_at, updated_at
              FROM clearledger.settlements""")
        cols = [d[0] for d in cur.description]
        settlements = {r[0]: dict(zip(cols, r)) for r in cur.fetchall()}
        cur.execute("""
            SELECT settlement_id::text, aggregate_version, event_id::text, event_type,
                   correlation_id, occurred_at, payload
              FROM clearledger.events ORDER BY settlement_id, aggregate_version""")
        cols = [d[0] for d in cur.description]
        events = [dict(zip(cols, r)) for r in cur.fetchall()]
    conn.commit()
    return settlements, events


def load_outbox(conn):
    with conn.cursor() as cur:
        cur.execute("""
            SELECT seq, event_id::text, payload, published_at, archived_at
              FROM clearledger.outbox ORDER BY seq""")
        cols = [d[0] for d in cur.description]
        rows = [dict(zip(cols, r)) for r in cur.fetchall()]
    conn.commit()
    return rows


# -- outbox relay ------------------------------------------------------------
def publish_outbox(conn, queue_url):
    sqs = client("sqs")
    total = 0
    while True:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT seq, payload FROM clearledger.outbox
                 WHERE published_at IS NULL ORDER BY seq LIMIT 50
                 FOR UPDATE SKIP LOCKED""")
            rows = cur.fetchall()
            if not rows:
                conn.commit()
                break
            for seq, payload in rows:
                sqs.send_message(QueueUrl=queue_url, MessageBody=canonical_envelope(payload))
                cur.execute("""
                    UPDATE clearledger.outbox
                       SET published_at = GREATEST(NOW(), created_at), attempts = attempts + 1, last_error = NULL
                     WHERE seq = %s AND published_at IS NULL""", (seq,))
                total += 1
        conn.commit()
    log(f"outbox: published {total} pending event(s)")
    return total


def wait_queue_drained(queue_url, esm_uuid, timeout=90):
    sqs = client("sqs")
    lam = client("lambda")
    try:
        st = lam.get_event_source_mapping(UUID=esm_uuid).get("State")
        if st not in ("Enabled", "Enabling", "Updating", "Creating"):
            log(f"event source mapping state {st}; enabling")
            lam.update_event_source_mapping(UUID=esm_uuid, Enabled=True)
    except Exception as e:
        log(f"esm check: {e}")
    deadline = time.time() + timeout
    zero_streak = 0
    while time.time() < deadline:
        a = sqs.get_queue_attributes(QueueUrl=queue_url, AttributeNames=[
            "ApproximateNumberOfMessages", "ApproximateNumberOfMessagesNotVisible",
            "ApproximateNumberOfMessagesDelayed"])["Attributes"]
        n = sum(int(a.get(k, 0)) for k in a)
        if n == 0:
            zero_streak += 1
            if zero_streak >= 2:
                log("main queue drained")
                return True
        else:
            zero_streak = 0
        time.sleep(1.5)
    log("main queue not fully drained before timeout; continuing")
    return False


# -- DynamoDB ---------------------------------------------------------------
def S(v):
    return {"S": str(v)}


def N(v):
    return {"N": str(int(v))}


def desired_dynamo(settlements, events):
    items = {}
    for sid, s in settlements.items():
        pk = f"SETTLEMENT#{sid}"
        it = {
            "PK": S(pk), "SK": S("STATE"),
            "GSI1PK": S(f"ACCOUNT#{s['account_id']}"), "GSI1SK": S(f"SETTLEMENT#{sid}"),
            "settlement_id": S(sid), "account_id": S(s["account_id"]), "reference": S(s["reference"]),
            "debit_party": S(s["debit_party"]), "credit_party": S(s["credit_party"]),
            "status": S(s["current_status"]), "clearing_stage": S(s["current_stage"]),
            "version": N(s["version"]), "entry_count": N(s["entry_count"]),
            "updated_at": S(ts_offset(s["updated_at"])),
        }
        if s["last_entry_id"] is not None:
            it["last_entry_id"] = S(s["last_entry_id"])
        if s["last_memo"] is not None:
            it["last_memo"] = S(s["last_memo"])
        items[(pk, "STATE")] = it
    for e in events:
        sid = e["settlement_id"]
        if sid not in settlements:
            continue
        pk = f"SETTLEMENT#{sid}"
        sk = "EVENT#%08d" % e["aggregate_version"]
        d = (e["payload"] or {}).get("data") or {}
        it = {
            "PK": S(pk), "SK": S(sk), "settlement_id": S(sid), "event_id": S(e["event_id"]),
            "version": N(e["aggregate_version"]), "event_type": S(e["event_type"]),
            "status": S(d.get("status")), "clearing_stage": S(d.get("clearingStage")),
            "occurred_at": S(ts_offset(e["occurred_at"])), "correlation_id": S(e["correlation_id"]),
            "envelope": S(canonical_envelope(e["payload"])),
        }
        if d.get("entryId") is not None:
            it["entry_id"] = S(d["entryId"])
        if d.get("memo") is not None:
            it["memo"] = S(d["memo"])
        items[(pk, sk)] = it
    return items


def scan_table(ddb, table):
    items = {}
    kw = {"TableName": table, "ConsistentRead": True}
    while True:
        r = ddb.scan(**kw)
        for it in r.get("Items", []):
            pk = it.get("PK", {}).get("S")
            sk = it.get("SK", {}).get("S")
            items[(pk, sk)] = it
        if not r.get("LastEvaluatedKey"):
            break
        kw["ExclusiveStartKey"] = r["LastEvaluatedKey"]
    return items


def _norm(item):
    return json.dumps(item, sort_keys=True)


def converge_dynamo(conn, table):
    ddb = client("dynamodb")
    existing = scan_table(ddb, table)          # scan first ...
    settlements, events = load_pg(conn)        # ... then read the system of record
    desired = desired_dynamo(settlements, events)
    puts = deletes = 0
    for key, it in desired.items():
        cur = existing.get(key)
        if cur is None or _norm(cur) != _norm(it):
            ddb.put_item(TableName=table, Item=it)
            puts += 1
    for key, cur in existing.items():
        if key in desired:
            continue
        pk, sk = key
        if pk is None or sk is None:
            continue
        ddb.delete_item(TableName=table, Key={"PK": cur["PK"], "SK": cur["SK"]})
        deletes += 1
    log(f"dynamodb: {puts} item(s) written, {deletes} stray item(s) deleted, "
        f"{len(desired)} desired item(s)")
    return puts + deletes, settlements


# -- Valkey -----------------------------------------------------------------
def projection_json(s):
    obj = {
        "settlementId": s["settlement_id"], "accountId": s["account_id"], "reference": s["reference"],
        "debitParty": s["debit_party"], "creditParty": s["credit_party"],
        "status": s["current_status"], "clearingStage": s["current_stage"],
    }
    if s["last_entry_id"] is not None:
        obj["lastEntryId"] = s["last_entry_id"]
    if s["last_memo"] is not None:
        obj["lastMemo"] = s["last_memo"]
    obj["version"] = int(s["version"])
    obj["entryCount"] = int(s["entry_count"])
    obj["updatedAt"] = ts_z(s["updated_at"])
    return json.dumps(obj, separators=(",", ":"), ensure_ascii=False)


def converge_valkey(conn, host, port):
    import redis
    settlements, _ = load_pg(conn)
    r = redis.Redis(host=host, port=int(port), socket_timeout=15, socket_connect_timeout=10)
    # purge every non-default logical database
    try:
        ks = r.info("keyspace") or {}
        for db in ks:
            idx = int(str(db).replace("db", ""))
            if idx != 0:
                rr = redis.Redis(host=host, port=int(port), db=idx, socket_timeout=15)
                rr.flushdb()
                log(f"valkey: flushed stray logical db {idx}")
    except Exception as e:
        log(f"valkey keyspace check: {e}")
    desired = {f"clearledger:settlement:{sid}": projection_json(s) for sid, s in settlements.items()}
    stray = []
    for k in r.scan_iter(match="*", count=1000):
        ks = k.decode("utf-8", "replace") if isinstance(k, bytes) else k
        if ks not in desired:
            stray.append(k)
    for i in range(0, len(stray), 500):
        r.delete(*stray[i:i + 500])
    pipe = r.pipeline(transaction=False)
    for k, v in desired.items():
        pipe.set(k, v, ex=CACHE_TTL)
    pipe.execute()
    log(f"valkey: {len(desired)} projection(s) cached, {len(stray)} stray key(s) purged")


# -- S3 audit archive ---------------------------------------------------------
def list_versions(s3, bucket):
    versions, markers = [], []
    kw = {"Bucket": bucket}
    while True:
        r = s3.list_object_versions(**kw)
        versions.extend(r.get("Versions", []) or [])
        markers.extend(r.get("DeleteMarkers", []) or [])
        if not r.get("IsTruncated"):
            break
        kw = {"Bucket": bucket}
        if r.get("NextKeyMarker"):
            kw["KeyMarker"] = r["NextKeyMarker"]
        if r.get("NextVersionIdMarker"):
            kw["VersionIdMarker"] = r["NextVersionIdMarker"]
    # objects in a bucket that was never versioned may not be listed as versions
    if not versions and not markers:
        kw = {"Bucket": bucket}
        while True:
            r = s3.list_objects_v2(**kw)
            for o in r.get("Contents", []) or []:
                versions.append({"Key": o["Key"], "VersionId": "null", "IsLatest": True})
            if not r.get("IsTruncated"):
                break
            kw["ContinuationToken"] = r["NextContinuationToken"]
    return versions, markers


def batch_body(rows):
    return "".join(canonical_envelope(r["payload"]) + "\n" for r in rows).encode("utf-8")


def batch_key(rows, body):
    digest = hashlib.sha256(body).hexdigest()[:16]
    return f"{AUDIT_PREFIX}batch-{rows[0]['seq']:08d}-{rows[-1]['seq']:08d}-{digest}.ndjson"


def delete_versions(s3, bucket, objs):
    objs = list(objs)
    for i in range(0, len(objs), 500):
        chunk = objs[i:i + 500]
        try:
            r = s3.delete_objects(Bucket=bucket, Delete={"Objects": chunk, "Quiet": True})
            for err in r.get("Errors", []) or []:
                log(f"s3 delete error {err}")
                o = {"Key": err["Key"]}
                if err.get("VersionId"):
                    o["VersionId"] = err["VersionId"]
                s3.delete_object(Bucket=bucket, **o)
        except Exception as e:
            log(f"delete_objects failed ({e}); deleting one by one")
            for o in chunk:
                try:
                    s3.delete_object(Bucket=bucket, **o)
                except Exception as e2:
                    log(f"delete_object {o}: {e2}")


def converge_s3(conn, bucket):
    s3 = client("s3")
    rows = load_outbox(conn)
    by_seq = {r["seq"]: r for r in rows}
    seqs = [r["seq"] for r in rows]
    versions, markers = list_versions(s3, bucket)

    latest = {}
    for v in versions:
        if v.get("IsLatest"):
            latest[v["Key"]] = v
    # keys whose latest entry is a delete marker have no current object
    for mk in markers:
        if mk.get("IsLatest"):
            latest.pop(mk["Key"], None)

    import bisect
    candidates = []
    for key, v in latest.items():
        m = BATCH_RE.match(key)
        if not m:
            continue
        first, last, digest = int(m.group(1)), int(m.group(2)), m.group(3)
        if first > last or first not in by_seq or last not in by_seq:
            continue
        lo = bisect.bisect_left(seqs, first)
        hi = bisect.bisect_right(seqs, last)
        slice_rows = [by_seq[s] for s in seqs[lo:hi]]
        if any(r["published_at"] is None for r in slice_rows):
            continue
        try:
            kw = {"Bucket": bucket, "Key": key}
            if v.get("VersionId") and v["VersionId"] != "null":
                kw["VersionId"] = v["VersionId"]
            body = s3.get_object(**kw)["Body"].read()
        except Exception as e:
            log(f"s3 get {key}: {e}")
            continue
        if hashlib.sha256(body).hexdigest()[:16] != digest:
            continue
        if body != batch_body(slice_rows):
            continue
        candidates.append((first, last, key, v.get("VersionId"), slice_rows))

    candidates.sort(key=lambda c: (c[0], c[1]))
    accepted = []
    last_end = -1
    for c in candidates:
        if c[0] > last_end:
            accepted.append(c)
            last_end = c[1]

    keep = {(c[2], c[3]) for c in accepted}
    to_delete = []
    for v in versions:
        if (v["Key"], v.get("VersionId")) not in keep:
            o = {"Key": v["Key"]}
            if v.get("VersionId") and v["VersionId"] != "null":
                o["VersionId"] = v["VersionId"]
            to_delete.append(o)
    for mk in markers:
        o = {"Key": mk["Key"]}
        if mk.get("VersionId"):
            o["VersionId"] = mk["VersionId"]
        to_delete.append(o)

    covered = set()
    for c in accepted:
        for r in c[4]:
            covered.add(r["seq"])

    # build new batches from runs of uncovered, published rows
    runs, cur = [], []
    for s in seqs:
        r = by_seq[s]
        if s in covered or r["published_at"] is None:
            if cur:
                runs.append(cur)
                cur = []
            continue
        cur.append(r)
        if len(cur) >= AUDIT_BATCH:
            runs.append(cur)
            cur = []
    if cur:
        runs.append(cur)

    written = []
    for run in runs:
        body = batch_body(run)
        key = batch_key(run, body)
        s3.put_object(Bucket=bucket, Key=key, Body=body, ContentType="application/x-ndjson")
        written.append(key)
        for r in run:
            covered.add(r["seq"])

    if to_delete:
        delete_versions(s3, bucket, to_delete)

    # purge any noncurrent versions created by overwrites of identical keys
    versions2, markers2 = list_versions(s3, bucket)
    extra = []
    for v in versions2:
        if not v.get("IsLatest"):
            extra.append({"Key": v["Key"], "VersionId": v["VersionId"]})
    for mk in markers2:
        extra.append({"Key": mk["Key"], "VersionId": mk["VersionId"]})
    if extra:
        delete_versions(s3, bucket, extra)

    # stamp archived_at for every archived row
    stamp = sorted(s for s in covered if by_seq[s]["archived_at"] is None)
    if stamp:
        with conn.cursor() as cur:
            cur.execute("""
                UPDATE clearledger.outbox
                   SET archived_at = GREATEST(NOW(), published_at)
                 WHERE seq = ANY(%s) AND archived_at IS NULL AND published_at IS NOT NULL""", (stamp,))
        conn.commit()
    changes = len(written) + len(to_delete) + len(extra) + len(stamp)
    log(f"s3: kept {len(accepted)} batch(es), wrote {len(written)}, purged {len(to_delete) + len(extra)} "
        f"version(s)/marker(s), stamped {len(stamp)} row(s)")
    return changes


def converge():
    m = manifest()
    conn = pg_connect()
    conn.autocommit = False
    queue_url = m["messaging"]["queue_url"]
    publish_outbox(conn, queue_url)
    wait_queue_drained(queue_url, m["messaging"]["event_source_mapping_uuid"])
    bucket = m["audit"]["bucket_name"]
    for i in range(3):
        if converge_s3(conn, bucket) == 0:
            break
    table = m["projections"]["table_name"]
    for i in range(3):
        changed, _ = converge_dynamo(conn, table)
        if changed == 0:
            break
    # a few more relay passes in case live traffic added rows meanwhile
    if publish_outbox(conn, queue_url):
        wait_queue_drained(queue_url, m["messaging"]["event_source_mapping_uuid"], timeout=45)
        converge_s3(conn, bucket)
        converge_dynamo(conn, table)
    converge_valkey(conn, m["cache"]["endpoint"], m["cache"]["port"])
    conn.close()


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "preapply":
        preapply()
    elif cmd == "postapply":
        postapply()
    elif cmd == "converge":
        converge()
    else:
        print("usage: ops.py preapply|postapply|converge", file=sys.stderr)
        sys.exit(2)
PYEOF

# ---------------------------------------------------------------------------
# S3 Control forwarder
# ---------------------------------------------------------------------------
start_proxy() {
  local host port
  host="$(python3 -c 'import sys,urllib.parse as u; p=u.urlparse(sys.argv[1]); print(p.hostname)' "${ENDPOINT}")"
  port="$(python3 -c 'import sys,urllib.parse as u; p=u.urlparse(sys.argv[1]); print(p.port or 80)' "${ENDPOINT}")"
  PROXY_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
  python3 "${WORK_DIR}/proxy.py" "${PROXY_PORT}" "${host}" "${port}" >/dev/null 2>&1 &
  PROXY_PID=$!
  for _ in $(seq 1 50); do
    if python3 -c 'import socket,sys; socket.create_connection(("127.0.0.1",int(sys.argv[1])),1).close()' "${PROXY_PORT}" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
  export AWS_ENDPOINT_URL_S3_CONTROL="http://localhost:${PROXY_PORT}"
  S3CONTROL_URL="http://localhost:${PROXY_PORT}"
}
start_proxy

# ---------------------------------------------------------------------------
# Terraform inputs
# ---------------------------------------------------------------------------
ENDPOINT_HOST="$(python3 -c 'import sys,urllib.parse as u; print(u.urlparse(sys.argv[1]).hostname)' "${ENDPOINT}")"
jq --arg s3c "${S3CONTROL_URL}" --arg host "${ENDPOINT_HOST}" '{
    resource_prefix, region, aws_endpoint_url, db_name, db_username, db_password,
    api_image, projector_image, relay_image, archiver_image,
    api_image_id: (.api_image_id // ""), projector_image_id: (.projector_image_id // ""),
    relay_image_id: (.relay_image_id // ""), archiver_image_id: (.archiver_image_id // ""),
    container_aws_endpoint_url: .aws_endpoint_url,
    s3control_endpoint_url: $s3c,
    service_host: $host
  }' "${CONFIG_FILE}" > "${WORK_DIR}/deploy.tfvars.json"

# ---------------------------------------------------------------------------
# 1. Pre-apply control-plane repair (KMS keys pending deletion / disabled)
# ---------------------------------------------------------------------------
log "pre-apply repair"
python3 "${WORK_DIR}/ops.py" preapply || log "pre-apply repair reported problems (continuing)"

# ---------------------------------------------------------------------------
# 2. terraform init + apply
# ---------------------------------------------------------------------------
cd "${INFRA_DIR}"
log "${TF} init"
"${TF}" init -input=false -no-color -upgrade=false >"${WORK_DIR}/init.log" 2>&1 || { cat "${WORK_DIR}/init.log" >&2; die "${TF} init failed"; }

apply_ok=0
for attempt in 1 2 3 4; do
  log "${TF} apply (attempt ${attempt})"
  if "${TF}" apply -input=false -no-color -auto-approve -lock-timeout=120s \
       -state="${INFRA_DIR}/terraform.tfstate" \
       -var-file="${WORK_DIR}/deploy.tfvars.json" >"${WORK_DIR}/apply.log" 2>&1; then
    apply_ok=1
    grep -E '^(Apply complete|Plan:)' "${WORK_DIR}/apply.log" >&2 || true
    break
  fi
  grep -E 'Error|error' "${WORK_DIR}/apply.log" | head -40 >&2 || true
  sleep $((attempt * 5))
done
[[ "${apply_ok}" == "1" ]] || { tail -80 "${WORK_DIR}/apply.log" >&2; die "${TF} apply failed"; }

"${TF}" output -state="${INFRA_DIR}/terraform.tfstate" -json manifest > "${WORK_DIR}/manifest.raw.json"
"${TF}" output -state="${INFRA_DIR}/terraform.tfstate" -json > "${WORK_DIR}/outputs.json"
export CL_OUTPUTS="${WORK_DIR}/outputs.json"

# ---------------------------------------------------------------------------
# 3. Manifest
# ---------------------------------------------------------------------------
jq '.' "${WORK_DIR}/manifest.raw.json" > "${MANIFEST_FILE}.tmp"
mv "${MANIFEST_FILE}.tmp" "${MANIFEST_FILE}"
chmod 600 "${MANIFEST_FILE}" 2>/dev/null || true
if [[ -f "${SCHEMA_FILE}" ]]; then
  python3 - "${MANIFEST_FILE}" "${SCHEMA_FILE}" <<'PYEOF' || die "manifest does not satisfy schema"
import json, sys
try:
    import jsonschema
except ImportError:
    sys.exit(0)
m = json.load(open(sys.argv[1])); s = json.load(open(sys.argv[2]))
jsonschema.validate(m, s)
PYEOF
fi
log "manifest written to ${MANIFEST_FILE}"

SERVICE_URL="$(jq -r .service_url "${MANIFEST_FILE}")"
DB_HOST="$(jq -r .database.endpoint "${MANIFEST_FILE}")"
DB_PORT="$(jq -r .database.port "${MANIFEST_FILE}")"
export CL_MANIFEST="${MANIFEST_FILE}" CL_DB_HOST="${DB_HOST}" CL_DB_PORT="${DB_PORT}"

# ---------------------------------------------------------------------------
# 4. PostgreSQL schema
# ---------------------------------------------------------------------------
log "waiting for PostgreSQL at ${DB_HOST}:${DB_PORT}"
export PGPASSWORD="${DB_PASSWORD}" PGCONNECT_TIMEOUT=5
for i in $(seq 1 90); do
  if psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -tAc 'select 1' >/dev/null 2>&1; then break; fi
  [[ $i -eq 90 ]] && die "PostgreSQL not reachable"
  sleep 2
done
log "applying clearledger schema"
schema_ok=0
for attempt in 1 2 3; do
  if psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -v ON_ERROR_STOP=1 -q -X \
       -f "${WORK_DIR}/schema.sql" >"${WORK_DIR}/schema.log" 2>&1; then
    schema_ok=1; break
  fi
  tail -20 "${WORK_DIR}/schema.log" >&2
  sleep 3
done
[[ "${schema_ok}" == "1" ]] || die "schema migration failed"

# ---------------------------------------------------------------------------
# 5. Post-apply control-plane drift repair (IAM, security groups)
# ---------------------------------------------------------------------------
log "post-apply drift repair"
python3 "${WORK_DIR}/ops.py" postapply || die "post-apply drift repair failed"

# ---------------------------------------------------------------------------
# 6. Wait for the API
# ---------------------------------------------------------------------------
log "waiting for ${SERVICE_URL}/health/ready"
ready=0
for i in $(seq 1 120); do
  code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "${SERVICE_URL}/health/ready" || true)"
  if [[ "${code}" == "200" ]]; then ready=1; break; fi
  sleep 3
done
[[ "${ready}" == "1" ]] || die "API did not become ready"
log "API ready"

# ---------------------------------------------------------------------------
# 7. Data-plane convergence (outbox -> SQS, DynamoDB, S3 archive, Valkey)
# ---------------------------------------------------------------------------
log "data-plane convergence"
python3 "${WORK_DIR}/ops.py" converge || die "data-plane convergence failed"

code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "${SERVICE_URL}/health/ready" || true)"
[[ "${code}" == "200" ]] || die "API not ready after convergence (HTTP ${code})"

log "deploy complete in $(( $(date +%s) - DEPLOY_START ))s"
exit 0
