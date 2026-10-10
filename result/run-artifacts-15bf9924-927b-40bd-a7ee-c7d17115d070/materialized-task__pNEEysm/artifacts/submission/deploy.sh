#!/usr/bin/env bash
# ClearLedger deployment: Terraform/OpenTofu infrastructure + PostgreSQL schema + data-plane convergence.
# Idempotent: safe to re-run after control-plane drift, partial failures or recovery drills.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA="${HERE}/infra"
CONFIG="${CLEARLEDGER_CONFIG:-/workspace/config/config.json}"
MANIFEST="${HERE}/manifest.json"
STATE="${INFRA}/terraform.tfstate"
SCHEMA_JSON="${CLEARLEDGER_MANIFEST_SCHEMA:-/workspace/contracts/schemas/manifest.schema.json}"
export CLEARLEDGER_CONFIG="${CONFIG}"
export TF_IN_AUTOMATION=1 TF_INPUT=0
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"

log() { printf '[deploy %s] %s\n' "$(date +%H:%M:%S)" "$*"; }

[[ -r "${CONFIG}" ]] || { echo "config not found: ${CONFIG}" >&2; exit 1; }
cfg() { jq -r --arg k "$1" '.[$k]' "${CONFIG}"; }
PREFIX="$(cfg resource_prefix)"
REGION="$(cfg region)"
ENDPOINT="$(cfg aws_endpoint_url)"
export AWS_REGION="${REGION}" AWS_DEFAULT_REGION="${REGION}" AWS_ENDPOINT_URL="${ENDPOINT}"
export TF_VAR_config_file="${CONFIG}"

if command -v terraform >/dev/null 2>&1; then TF=terraform
elif command -v tofu >/dev/null 2>&1; then TF=tofu
else echo "neither terraform nor tofu found" >&2; exit 1; fi

# serialise concurrent runs
exec 9>"${HERE}/.deploy.lock"
flock -w 600 9 || { echo "another deploy is running" >&2; exit 1; }

WORK="$(mktemp -d /tmp/clearledger-deploy.XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT
export PYTHONPATH="${WORK}" PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1

cat > "${WORK}/common.py" <<'PYEOF_common'
import json, os, sys, time, re, hashlib, datetime
import boto3
from botocore.config import Config

def log(tag, msg):
    print(f"[{tag}] {msg}", flush=True)

def load_cfg(path="/workspace/config/config.json"):
    with open(path) as f:
        return json.load(f)

def client(cfg, svc, **kw):
    return boto3.client(svc, endpoint_url=cfg["aws_endpoint_url"], region_name=cfg["region"],
                        aws_access_key_id="test", aws_secret_access_key="test",
                        config=Config(retries={"max_attempts": 5, "mode": "standard"},
                                      connect_timeout=10, read_timeout=120), **kw)

def state_resources(state_path):
    """Return {(type, name, index_key): attributes} from a local terraform state (best effort)."""
    out = {}
    try:
        with open(state_path) as f:
            st = json.load(f)
    except Exception:
        return out
    for r in st.get("resources", []):
        if r.get("mode") != "managed":
            continue
        for inst in r.get("instances", []):
            out[(r["type"], r["name"], inst.get("index_key"))] = inst.get("attributes", {})
    return out

PYEOF_common

cat > "${WORK}/schema.py" <<'PYEOF_schema'
"""ClearLedger PostgreSQL schema: functions, tables, constraints, triggers, indexes."""

UUID_RE = r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
TS_RE = r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$"

SCHEMA_SQL = "CREATE SCHEMA IF NOT EXISTS clearledger"

FUNCTIONS = [
# ---------------------------------------------------------------- helpers
r"""
CREATE OR REPLACE FUNCTION clearledger.canon(v text, lo integer, hi integer)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $f$
  SELECT v IS NOT NULL AND v = btrim(v) AND char_length(v) BETWEEN lo AND hi
$f$
""",
r"""
CREATE OR REPLACE FUNCTION clearledger.status_rank(s text)
RETURNS integer LANGUAGE sql IMMUTABLE AS $f$
  SELECT CASE s WHEN 'INITIATED' THEN 0 WHEN 'VALIDATED' THEN 1 WHEN 'RESERVED' THEN 2
                WHEN 'CLEARED' THEN 3 WHEN 'SETTLED' THEN 4 WHEN 'RECONCILED' THEN 5
                ELSE NULL END
$f$
""",
r"""
CREATE OR REPLACE FUNCTION clearledger.status_transition_ok(o text, n text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $f$
  SELECT COALESCE(CASE
    WHEN o = 'RECONCILED' THEN false
    WHEN o = 'DISPUTED' THEN n IN ('DISPUTED', 'RECONCILED')
    WHEN o IN ('INITIATED', 'VALIDATED', 'RESERVED', 'CLEARED', 'SETTLED') THEN
      (n = 'DISPUTED'
       OR (clearledger.status_rank(n) IS NOT NULL
           AND clearledger.status_rank(n) >= clearledger.status_rank(o)))
    ELSE false
  END, false)
$f$
""",
# ---------------------------------------------------------------- envelope validation
r"""
CREATE OR REPLACE FUNCTION clearledger.envelope_valid(p jsonb)
RETURNS boolean LANGUAGE plpgsql STABLE AS $f$
DECLARE
  d jsonb;
  v integer;
  et text;
  k text;
BEGIN
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN RETURN false; END IF;
  IF NOT (p ?& ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId',
                     'aggregateVersion','occurredAt','correlationId','idempotencyKey','data']) THEN
    RETURN false;
  END IF;
  IF (SELECT count(*) FROM jsonb_object_keys(p)) <> 10 THEN RETURN false; END IF;

  IF jsonb_typeof(p->'schemaVersion') <> 'string' OR p->>'schemaVersion' <> '1.0' THEN RETURN false; END IF;
  IF jsonb_typeof(p->'aggregateType') <> 'string' OR p->>'aggregateType' <> 'settlement' THEN RETURN false; END IF;
  IF jsonb_typeof(p->'eventId') <> 'string' OR p->>'eventId' !~ '__UUID__' THEN RETURN false; END IF;
  IF jsonb_typeof(p->'aggregateId') <> 'string' OR p->>'aggregateId' !~ '__UUID__' THEN RETURN false; END IF;
  IF jsonb_typeof(p->'aggregateVersion') <> 'number' OR (p->'aggregateVersion')::text !~ '^[1-9][0-9]{0,8}$' THEN RETURN false; END IF;
  IF jsonb_typeof(p->'occurredAt') <> 'string' OR p->>'occurredAt' !~ '__TS__' THEN RETURN false; END IF;
  PERFORM (p->>'occurredAt')::timestamptz;
  IF jsonb_typeof(p->'correlationId') <> 'string' OR NOT clearledger.canon(p->>'correlationId', 4, 128) THEN RETURN false; END IF;
  IF jsonb_typeof(p->'idempotencyKey') <> 'string' OR NOT clearledger.canon(p->>'idempotencyKey', 8, 128) THEN RETURN false; END IF;
  IF jsonb_typeof(p->'eventType') <> 'string' THEN RETURN false; END IF;

  v := (p->'aggregateVersion')::text::integer;
  et := p->>'eventType';
  d := p->'data';
  IF jsonb_typeof(d) <> 'object' THEN RETURN false; END IF;
  FOR k IN SELECT jsonb_object_keys(d) LOOP
    IF k NOT IN ('kind','accountId','reference','debitParty','creditParty','entryId','status','clearingStage','memo') THEN
      RETURN false;
    END IF;
  END LOOP;
  IF NOT (d ?& ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage']) THEN RETURN false; END IF;
  IF jsonb_typeof(d->'kind') <> 'string' THEN RETURN false; END IF;
  IF jsonb_typeof(d->'accountId') <> 'string' OR NOT clearledger.canon(d->>'accountId', 3, 64) THEN RETURN false; END IF;
  IF jsonb_typeof(d->'reference') <> 'string' OR NOT clearledger.canon(d->>'reference', 3, 64) THEN RETURN false; END IF;
  IF jsonb_typeof(d->'debitParty') <> 'string' OR NOT clearledger.canon(d->>'debitParty', 2, 64) THEN RETURN false; END IF;
  IF jsonb_typeof(d->'creditParty') <> 'string' OR NOT clearledger.canon(d->>'creditParty', 2, 64) THEN RETURN false; END IF;
  IF d->>'debitParty' = d->>'creditParty' THEN RETURN false; END IF;
  IF jsonb_typeof(d->'status') <> 'string'
     OR d->>'status' NOT IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED') THEN
    RETURN false;
  END IF;
  IF jsonb_typeof(d->'clearingStage') <> 'string' THEN RETURN false; END IF;
  IF d ? 'memo' AND jsonb_typeof(d->'memo') NOT IN ('string', 'null') THEN RETURN false; END IF;
  IF d ? 'entryId' AND jsonb_typeof(d->'entryId') NOT IN ('string', 'null') THEN RETURN false; END IF;
  IF jsonb_typeof(d->'memo') = 'string' AND NOT clearledger.canon(d->>'memo', 1, 256) THEN RETURN false; END IF;

  IF v = 1 THEN
    IF et <> 'SettlementInitiated' OR d->>'kind' <> 'settlementInitiated' THEN RETURN false; END IF;
    IF d->>'status' <> 'INITIATED' THEN RETURN false; END IF;
    IF d->>'clearingStage' <> 'INITIATED@' || (d->>'debitParty') THEN RETURN false; END IF;
    IF d->>'memo' IS DISTINCT FROM 'Settlement initiated' THEN RETURN false; END IF;
    IF d->>'entryId' IS NOT NULL THEN RETURN false; END IF;
  ELSE
    IF et <> 'LedgerEntryRecorded' OR d->>'kind' <> 'ledgerEntryRecorded' THEN RETURN false; END IF;
    IF d->>'status' = 'INITIATED' THEN RETURN false; END IF;
    IF NOT clearledger.canon(d->>'clearingStage', 2, 64) THEN RETURN false; END IF;
    IF jsonb_typeof(d->'entryId') <> 'string' OR d->>'entryId' !~ '__UUID__' THEN RETURN false; END IF;
  END IF;
  RETURN true;
EXCEPTION WHEN OTHERS THEN
  RETURN false;
END
$f$
""",
r"""
CREATE OR REPLACE FUNCTION clearledger.envelope_matches(
  p jsonb, eid uuid, sid uuid, ver integer, etype text, corr text, idem text, occ timestamptz)
RETURNS boolean LANGUAGE plpgsql STABLE AS $f$
BEGIN
  RETURN clearledger.envelope_valid(p)
     AND (p->>'eventId')::uuid = eid
     AND (p->>'aggregateId')::uuid = sid
     AND (p->'aggregateVersion')::text::integer = ver
     AND p->>'eventType' = etype
     AND p->>'correlationId' = corr
     AND p->>'idempotencyKey' = idem
     AND (p->>'occurredAt')::timestamptz = occ;
EXCEPTION WHEN OTHERS THEN
  RETURN false;
END
$f$
""",
r"""
CREATE OR REPLACE FUNCTION clearledger.idem_body_valid(b jsonb)
RETURNS boolean LANGUAGE plpgsql STABLE AS $f$
BEGIN
  IF b IS NULL OR jsonb_typeof(b) <> 'object' THEN RETURN false; END IF;
  IF NOT (b ?& ARRAY['settlementId','eventId','version','accepted','idempotentReplay']) THEN RETURN false; END IF;
  IF (SELECT count(*) FROM jsonb_object_keys(b)) <> 5 THEN RETURN false; END IF;
  IF jsonb_typeof(b->'settlementId') <> 'string' OR b->>'settlementId' !~ '__UUID__' THEN RETURN false; END IF;
  IF jsonb_typeof(b->'eventId') <> 'string' OR b->>'eventId' !~ '__UUID__' THEN RETURN false; END IF;
  IF jsonb_typeof(b->'version') <> 'number' OR (b->'version')::text !~ '^[1-9][0-9]{0,8}$' THEN RETURN false; END IF;
  IF b->'accepted' IS DISTINCT FROM 'true'::jsonb THEN RETURN false; END IF;
  IF b->'idempotentReplay' IS DISTINCT FROM 'false'::jsonb THEN RETURN false; END IF;
  RETURN true;
EXCEPTION WHEN OTHERS THEN
  RETURN false;
END
$f$
""",
r"""
CREATE OR REPLACE FUNCTION clearledger.idem_valid(scope text, body jsonb, status_code integer)
RETURNS boolean LANGUAGE plpgsql STABLE AS $f$
DECLARE ver integer;
BEGIN
  IF scope IS NULL OR scope !~ ('^(create|entry):' || substr('__UUID__', 2, length('__UUID__') - 2)) THEN RETURN false; END IF;
  IF NOT clearledger.idem_body_valid(body) THEN RETURN false; END IF;
  IF lower(split_part(scope, ':', 2)) <> lower(body->>'settlementId') THEN RETURN false; END IF;
  ver := (body->'version')::text::integer;
  IF scope LIKE 'create:%' THEN
    RETURN status_code = 201 AND ver = 1;
  ELSE
    RETURN status_code = 202 AND ver >= 2;
  END IF;
EXCEPTION WHEN OTHERS THEN
  RETURN false;
END
$f$
""",
# ---------------------------------------------------------------- settlements triggers
r"""
CREATE OR REPLACE FUNCTION clearledger.trg_settlements_guard()
RETURNS trigger LANGUAGE plpgsql AS $f$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'clearledger.settlements is append-only: DELETE is not permitted' USING ERRCODE = 'P0001';
  END IF;

  IF OLD.current_status = 'RECONCILED' THEN
    RAISE EXCEPTION 'settlement % is RECONCILED and can no longer be updated', OLD.settlement_id USING ERRCODE = 'P0001';
  END IF;
  IF NEW.settlement_id IS DISTINCT FROM OLD.settlement_id
     OR NEW.account_id IS DISTINCT FROM OLD.account_id
     OR NEW.reference IS DISTINCT FROM OLD.reference
     OR NEW.debit_party IS DISTINCT FROM OLD.debit_party
     OR NEW.credit_party IS DISTINCT FROM OLD.credit_party
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'settlement header columns are immutable' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.version IS DISTINCT FROM OLD.version + 1 OR NEW.entry_count IS DISTINCT FROM OLD.entry_count + 1 THEN
    RAISE EXCEPTION 'settlement version and entry_count must advance by exactly 1' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.last_entry_id IS NULL OR NEW.last_entry_id IS NOT DISTINCT FROM OLD.last_entry_id THEN
    RAISE EXCEPTION 'settlement update requires a new last_entry_id' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.updated_at IS NULL OR NEW.updated_at <= OLD.updated_at THEN
    RAISE EXCEPTION 'settlement updated_at must strictly increase' USING ERRCODE = 'P0001';
  END IF;
  IF NOT clearledger.status_transition_ok(OLD.current_status, NEW.current_status) THEN
    RAISE EXCEPTION 'illegal settlement status transition % -> %', OLD.current_status, NEW.current_status USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END
$f$
""",
# ---------------------------------------------------------------- events triggers
r"""
CREATE OR REPLACE FUNCTION clearledger.trg_events_insert()
RETURNS trigger LANGUAGE plpgsql AS $f$
DECLARE
  s clearledger.settlements%ROWTYPE;
  prev clearledger.events%ROWTYPE;
  d jsonb;
  maxv integer;
BEGIN
  IF NOT clearledger.envelope_matches(NEW.payload, NEW.event_id, NEW.settlement_id, NEW.aggregate_version,
                                      NEW.event_type, NEW.correlation_id, NEW.idempotency_key, NEW.occurred_at) THEN
    RAISE EXCEPTION 'event payload is not a valid ClearLedgerDomainEventEnvelope matching the event columns'
      USING ERRCODE = '23514';
  END IF;
  d := NEW.payload->'data';

  SELECT * INTO s FROM clearledger.settlements WHERE settlement_id = NEW.settlement_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'settlement % does not exist', NEW.settlement_id USING ERRCODE = '23503';
  END IF;

  SELECT COALESCE(MAX(aggregate_version), 0) INTO maxv FROM clearledger.events WHERE settlement_id = NEW.settlement_id;
  IF NEW.aggregate_version <= maxv THEN
    RAISE EXCEPTION 'aggregate_version % already recorded for settlement %', NEW.aggregate_version, NEW.settlement_id
      USING ERRCODE = '23505';
  END IF;
  IF NEW.aggregate_version <> maxv + 1 THEN
    RAISE EXCEPTION 'aggregate_version must be contiguous (expected %, got %)', maxv + 1, NEW.aggregate_version
      USING ERRCODE = 'P0001';
  END IF;

  IF s.account_id IS DISTINCT FROM d->>'accountId'
     OR s.reference IS DISTINCT FROM d->>'reference'
     OR s.debit_party IS DISTINCT FROM d->>'debitParty'
     OR s.credit_party IS DISTINCT FROM d->>'creditParty'
     OR s.current_status IS DISTINCT FROM d->>'status'
     OR s.current_stage IS DISTINCT FROM d->>'clearingStage'
     OR s.last_entry_id IS DISTINCT FROM (d->>'entryId')::uuid
     OR s.last_memo IS DISTINCT FROM d->>'memo'
     OR s.version IS DISTINCT FROM NEW.aggregate_version
     OR s.updated_at IS DISTINCT FROM NEW.occurred_at THEN
    RAISE EXCEPTION 'event does not match the current settlement row' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.aggregate_version = 1 AND NEW.occurred_at IS DISTINCT FROM s.created_at THEN
    RAISE EXCEPTION 'initial event occurred_at must equal settlement created_at' USING ERRCODE = 'P0001';
  END IF;

  IF NEW.aggregate_version >= 2 THEN
    SELECT * INTO prev FROM clearledger.events
      WHERE settlement_id = NEW.settlement_id AND aggregate_version = NEW.aggregate_version - 1;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'previous event missing for settlement %', NEW.settlement_id USING ERRCODE = 'P0001';
    END IF;
    IF NEW.occurred_at <= prev.occurred_at THEN
      RAISE EXCEPTION 'occurred_at must strictly increase per settlement' USING ERRCODE = 'P0001';
    END IF;
    IF NOT clearledger.status_transition_ok(prev.payload->'data'->>'status', d->>'status') THEN
      RAISE EXCEPTION 'illegal status transition % -> %', prev.payload->'data'->>'status', d->>'status'
        USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END
$f$
""",
r"""
CREATE OR REPLACE FUNCTION clearledger.trg_events_immutable()
RETURNS trigger LANGUAGE plpgsql AS $f$
BEGIN
  RAISE EXCEPTION 'clearledger.events is append-only: % is not permitted', TG_OP USING ERRCODE = 'P0001';
END
$f$
""",
# ---------------------------------------------------------------- outbox triggers
r"""
CREATE OR REPLACE FUNCTION clearledger.trg_outbox_insert()
RETURNS trigger LANGUAGE plpgsql AS $f$
DECLARE
  e clearledger.events%ROWTYPE;
  maxv integer;
BEGIN
  IF NOT clearledger.envelope_valid(NEW.payload) THEN
    RAISE EXCEPTION 'outbox payload is not a valid ClearLedgerDomainEventEnvelope' USING ERRCODE = '23514';
  END IF;
  SELECT * INTO e FROM clearledger.events WHERE event_id = NEW.event_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'event % does not exist', NEW.event_id USING ERRCODE = '23503';
  END IF;
  IF e.settlement_id <> NEW.settlement_id OR e.aggregate_version <> NEW.aggregate_version
     OR e.correlation_id <> NEW.correlation_id OR e.payload <> NEW.payload THEN
    RAISE EXCEPTION 'outbox row must exactly mirror its event' USING ERRCODE = 'P0001';
  END IF;
  SELECT COALESCE(MAX(aggregate_version), 0) INTO maxv FROM clearledger.outbox WHERE settlement_id = NEW.settlement_id;
  IF NEW.aggregate_version <= maxv THEN
    RAISE EXCEPTION 'outbox aggregate_version % already present for settlement %', NEW.aggregate_version, NEW.settlement_id
      USING ERRCODE = '23505';
  END IF;
  IF NEW.aggregate_version <> maxv + 1 THEN
    RAISE EXCEPTION 'outbox aggregate_version must be contiguous (expected %, got %)', maxv + 1, NEW.aggregate_version
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END
$f$
""",
r"""
CREATE OR REPLACE FUNCTION clearledger.trg_outbox_update()
RETURNS trigger LANGUAGE plpgsql AS $f$
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
      RAISE EXCEPTION 'publishing an outbox row requires incrementing attempts and archived_at IS NULL' USING ERRCODE = 'P0001';
    END IF;
  ELSIF OLD.published_at IS NOT NULL AND NEW.published_at IS NOT NULL THEN
    IF NEW.published_at <> OLD.published_at OR NEW.attempts <> OLD.attempts
       OR NEW.last_error IS DISTINCT FROM OLD.last_error THEN
      RAISE EXCEPTION 'published_at, attempts and last_error of a published row are immutable' USING ERRCODE = 'P0001';
    END IF;
  ELSIF OLD.published_at IS NOT NULL AND NEW.published_at IS NULL THEN
    IF NEW.archived_at IS NOT NULL THEN
      RAISE EXCEPTION 'resetting published_at requires resetting archived_at' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NOT NULL AND NEW.archived_at <> OLD.archived_at THEN
    RAISE EXCEPTION 'archived_at cannot be changed without first resetting it to NULL' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END
$f$
""",
r"""
CREATE OR REPLACE FUNCTION clearledger.trg_outbox_delete()
RETURNS trigger LANGUAGE plpgsql AS $f$
BEGIN
  RAISE EXCEPTION 'clearledger.outbox rows cannot be deleted' USING ERRCODE = 'P0001';
END
$f$
""",
# ---------------------------------------------------------------- idempotency triggers
r"""
CREATE OR REPLACE FUNCTION clearledger.trg_idem_insert()
RETURNS trigger LANGUAGE plpgsql AS $f$
DECLARE
  b jsonb := NEW.response_body;
  eid uuid;
  sid uuid;
  ver integer;
BEGIN
  IF NOT clearledger.idem_valid(NEW.scope, b, NEW.status_code) THEN
    RAISE EXCEPTION 'idempotency record is not a valid WriteAcceptedResponse for its scope' USING ERRCODE = '23514';
  END IF;
  eid := (b->>'eventId')::uuid;
  sid := (b->>'settlementId')::uuid;
  ver := (b->'version')::text::integer;
  IF NOT EXISTS (SELECT 1 FROM clearledger.events
                 WHERE event_id = eid AND settlement_id = sid AND aggregate_version = ver
                   AND idempotency_key = NEW.idempotency_key) THEN
    RAISE EXCEPTION 'referenced event does not exist in clearledger.events' USING ERRCODE = '23503';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM clearledger.outbox
                 WHERE event_id = eid AND settlement_id = sid AND aggregate_version = ver) THEN
    RAISE EXCEPTION 'referenced event does not exist in clearledger.outbox' USING ERRCODE = '23503';
  END IF;
  RETURN NEW;
END
$f$
""",
r"""
CREATE OR REPLACE FUNCTION clearledger.trg_idem_immutable()
RETURNS trigger LANGUAGE plpgsql AS $f$
BEGIN
  RAISE EXCEPTION 'clearledger.idempotency_keys is immutable: % is not permitted', TG_OP USING ERRCODE = 'P0001';
END
$f$
""",
]
FUNCTIONS = [f.replace("__UUID__", UUID_RE).replace("__TS__", TS_RE) for f in FUNCTIONS]

TABLES = [
"""
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
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
)""",
"""
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
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
)""",
"""
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
  last_error        TEXT        NULL
)""",
"""
CREATE TABLE IF NOT EXISTS clearledger.idempotency_keys (
  scope           TEXT        NOT NULL,
  idempotency_key TEXT        NOT NULL,
  request_hash    TEXT        NOT NULL,
  status_code     INTEGER     NOT NULL,
  response_body   JSONB       NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
)""",
]

# (table, constraint name, definition) -- applied in order, only when missing.
CONSTRAINTS = [
  # ---- settlements
  ("settlements", "settlements_pkey", "PRIMARY KEY (settlement_id)"),
  ("settlements", "settlements_account_id_canonical", "CHECK (clearledger.canon(account_id, 3, 64))"),
  ("settlements", "settlements_reference_canonical", "CHECK (clearledger.canon(reference, 3, 64))"),
  ("settlements", "settlements_debit_party_canonical", "CHECK (clearledger.canon(debit_party, 2, 64))"),
  ("settlements", "settlements_credit_party_canonical", "CHECK (clearledger.canon(credit_party, 2, 64))"),
  ("settlements", "settlements_parties_differ", "CHECK (debit_party <> credit_party)"),
  ("settlements", "settlements_status_valid",
   "CHECK (current_status IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED'))"),
  ("settlements", "settlements_stage_canonical",
   "CHECK (current_stage = btrim(current_stage) AND ((version = 1 AND current_stage = 'INITIATED@' || debit_party) "
   "OR (version > 1 AND char_length(current_stage) BETWEEN 2 AND 64)))"),
  ("settlements", "settlements_memo_canonical", "CHECK (last_memo IS NULL OR clearledger.canon(last_memo, 1, 256))"),
  ("settlements", "settlements_version_positive", "CHECK (version >= 1)"),
  ("settlements", "settlements_entry_count_nonnegative", "CHECK (entry_count >= 0)"),
  ("settlements", "settlements_initial_state",
   "CHECK (version <> 1 OR (entry_count = 0 AND current_status = 'INITIATED' "
   "AND current_stage = 'INITIATED@' || debit_party AND last_entry_id IS NULL "
   "AND last_memo = 'Settlement initiated' AND updated_at = created_at))"),
  ("settlements", "settlements_later_state",
   "CHECK (version = 1 OR (entry_count = version - 1 AND current_status <> 'INITIATED' "
   "AND last_entry_id IS NOT NULL AND updated_at > created_at))"),
  # ---- events
  ("events", "events_pkey", "PRIMARY KEY (seq)"),
  ("events", "events_event_id_key", "UNIQUE (event_id)"),
  ("events", "events_settlement_version_key", "UNIQUE (settlement_id, aggregate_version)"),
  ("events", "events_settlement_idempotency_key", "UNIQUE (settlement_id, idempotency_key)"),
  ("events", "events_settlement_fk",
   "FOREIGN KEY (settlement_id) REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE"),
  ("events", "events_version_positive", "CHECK (aggregate_version >= 1)"),
  ("events", "events_type_valid", "CHECK (event_type IN ('SettlementInitiated','LedgerEntryRecorded'))"),
  ("events", "events_correlation_id_canonical", "CHECK (clearledger.canon(correlation_id, 4, 128))"),
  ("events", "events_idempotency_key_canonical", "CHECK (clearledger.canon(idempotency_key, 8, 128))"),
  ("events", "events_payload_envelope",
   "CHECK (clearledger.envelope_matches(payload, event_id, settlement_id, aggregate_version, event_type, "
   "correlation_id, idempotency_key, occurred_at))"),
  # ---- outbox
  ("outbox", "outbox_pkey", "PRIMARY KEY (seq)"),
  ("outbox", "outbox_event_id_key", "UNIQUE (event_id)"),
  ("outbox", "outbox_settlement_version_key", "UNIQUE (settlement_id, aggregate_version)"),
  ("outbox", "outbox_event_fk",
   "FOREIGN KEY (event_id) REFERENCES clearledger.events(event_id) ON DELETE CASCADE"),
  ("outbox", "outbox_settlement_fk",
   "FOREIGN KEY (settlement_id) REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE"),
  ("outbox", "outbox_settlement_version_fk",
   "FOREIGN KEY (settlement_id, aggregate_version) REFERENCES clearledger.events(settlement_id, aggregate_version) ON DELETE CASCADE"),
  ("outbox", "outbox_correlation_id_canonical", "CHECK (correlation_id = btrim(correlation_id))"),
  ("outbox", "outbox_payload_envelope",
   "CHECK (clearledger.envelope_valid(payload) AND (payload->>'eventId')::uuid = event_id "
   "AND (payload->>'aggregateId')::uuid = settlement_id "
   "AND (payload->'aggregateVersion')::text::integer = aggregate_version "
   "AND payload->>'correlationId' = correlation_id)"),
  ("outbox", "outbox_attempts_nonnegative", "CHECK (attempts >= 0)"),
  ("outbox", "outbox_unattempted_clean",
   "CHECK (attempts <> 0 OR (published_at IS NULL AND last_error IS NULL))"),
  ("outbox", "outbox_published_state",
   "CHECK (published_at IS NULL OR (attempts >= 1 AND last_error IS NULL AND published_at >= created_at))"),
  ("outbox", "outbox_error_state",
   "CHECK (last_error IS NULL OR (published_at IS NULL AND attempts >= 1 "
   "AND length(btrim(last_error)) > 0 AND last_error = btrim(last_error)))"),
  ("outbox", "outbox_archived_state",
   "CHECK (archived_at IS NULL OR (published_at IS NOT NULL AND archived_at >= published_at))"),
  # ---- idempotency_keys
  ("idempotency_keys", "idempotency_keys_pkey", "PRIMARY KEY (scope, idempotency_key)"),
  ("idempotency_keys", "idempotency_keys_key_canonical", "CHECK (clearledger.canon(idempotency_key, 8, 128))"),
  ("idempotency_keys", "idempotency_keys_hash_valid", "CHECK (request_hash ~ '^[0-9a-f]{64}$')"),
  ("idempotency_keys", "idempotency_keys_response_valid",
   "CHECK (clearledger.idem_valid(scope, response_body, status_code))"),
]

# name -> (table, create statement, function name, expected pg_trigger.tgtype)
_TGTYPE = {"BEFORE INSERT": 7, "BEFORE UPDATE": 19, "BEFORE DELETE": 11, "BEFORE DELETE OR UPDATE": 27}
def _trg(name, table, when, func):
    return (name, table,
            f"CREATE OR REPLACE TRIGGER {name} {when} ON clearledger.{table} FOR EACH ROW EXECUTE FUNCTION clearledger.{func}()",
            func, _TGTYPE[when])

TRIGGERS = [
  _trg("trg_settlements_guard", "settlements", "BEFORE DELETE OR UPDATE", "trg_settlements_guard"),
  _trg("trg_events_insert", "events", "BEFORE INSERT", "trg_events_insert"),
  _trg("trg_events_immutable", "events", "BEFORE DELETE OR UPDATE", "trg_events_immutable"),
  _trg("trg_outbox_insert", "outbox", "BEFORE INSERT", "trg_outbox_insert"),
  _trg("trg_outbox_update", "outbox", "BEFORE UPDATE", "trg_outbox_update"),
  _trg("trg_outbox_delete", "outbox", "BEFORE DELETE", "trg_outbox_delete"),
  _trg("trg_idem_insert", "idempotency_keys", "BEFORE INSERT", "trg_idem_insert"),
  _trg("trg_idem_immutable", "idempotency_keys", "BEFORE DELETE OR UPDATE", "trg_idem_immutable"),
]

# name -> (table, create sql, expected pg_indexes.indexdef)
INDEXES = [
  ("idx_clearledger_outbox_unpublished",
   "CREATE INDEX idx_clearledger_outbox_unpublished ON clearledger.outbox (seq) WHERE published_at IS NULL",
   "CREATE INDEX idx_clearledger_outbox_unpublished ON clearledger.outbox USING btree (seq) WHERE (published_at IS NULL)"),
  ("idx_clearledger_outbox_unarchived",
   "CREATE INDEX idx_clearledger_outbox_unarchived ON clearledger.outbox (seq) WHERE published_at IS NOT NULL AND archived_at IS NULL",
   "CREATE INDEX idx_clearledger_outbox_unarchived ON clearledger.outbox USING btree (seq) WHERE ((published_at IS NOT NULL) AND (archived_at IS NULL))"),
  ("idx_clearledger_events_settlement_version",
   "CREATE INDEX idx_clearledger_events_settlement_version ON clearledger.events (settlement_id, aggregate_version)",
   "CREATE INDEX idx_clearledger_events_settlement_version ON clearledger.events USING btree (settlement_id, aggregate_version)"),
  ("idx_clearledger_idempotency_event",
   "CREATE UNIQUE INDEX idx_clearledger_idempotency_event ON clearledger.idempotency_keys (((response_body->>'eventId')::uuid))",
   "CREATE UNIQUE INDEX idx_clearledger_idempotency_event ON clearledger.idempotency_keys USING btree ((((response_body ->> 'eventId'::text))::uuid))"),
  ("idx_clearledger_idempotency_version",
   "CREATE UNIQUE INDEX idx_clearledger_idempotency_version ON clearledger.idempotency_keys (((response_body->>'settlementId')::uuid), ((response_body->>'version')::integer))",
   "CREATE UNIQUE INDEX idx_clearledger_idempotency_version ON clearledger.idempotency_keys USING btree ((((response_body ->> 'settlementId'::text))::uuid), (((response_body ->> 'version'::text))::integer))"),
  ("idx_clearledger_entry_id",
   "CREATE UNIQUE INDEX idx_clearledger_entry_id ON clearledger.events (settlement_id, ((payload->'data'->>'entryId')::uuid)) WHERE event_type = 'LedgerEntryRecorded'",
   "CREATE UNIQUE INDEX idx_clearledger_entry_id ON clearledger.events USING btree (settlement_id, ((((payload -> 'data'::text) ->> 'entryId'::text))::uuid)) WHERE (event_type = 'LedgerEntryRecorded'::text)"),
]

PYEOF_schema

cat > "${WORK}/apply_schema.py" <<'PYEOF_apply_schema'
import sys, psycopg2
from schema import *

def norm(d):
    return "".join(ch for ch in d.lower() if ch not in " ()")

def log(m): print(f"[schema] {m}", flush=True)

def apply_schema(dsn):
    conn = psycopg2.connect(dsn, connect_timeout=10)
    conn.autocommit = False
    cur = conn.cursor()
    cur.execute("SET lock_timeout = '30s'")
    cur.execute("SELECT pg_advisory_xact_lock(hashtext('clearledger-schema'))")
    cur.execute(SCHEMA_SQL)
    # helper functions first (CHECK constraints use them), then tables, then trigger
    # functions (they reference table row types).
    for f in FUNCTIONS:
        if "clearledger.trg_" not in f.split("(")[0]:
            cur.execute(f)
    for t in TABLES:
        cur.execute(t)
    for f in FUNCTIONS:
        if "clearledger.trg_" in f.split("(")[0]:
            cur.execute(f)

    cur.execute("""SELECT c.relname, con.conname, con.convalidated
                   FROM pg_constraint con JOIN pg_class c ON c.oid = con.conrelid
                   JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'clearledger'""")
    have = {(r[0], r[1]): r[2] for r in cur.fetchall()}
    for table, name, ddl in CONSTRAINTS:
        if (table, name) not in have:
            log(f"adding constraint {table}.{name}")
            cur.execute(f"ALTER TABLE clearledger.{table} ADD CONSTRAINT {name} {ddl}")
        elif not have[(table, name)]:
            log(f"validating constraint {table}.{name}")
            cur.execute(f"ALTER TABLE clearledger.{table} VALIDATE CONSTRAINT {name}")

    cur.execute("""SELECT t.tgname, p.proname, t.tgtype, c.relname
                   FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
                   JOIN pg_namespace n ON n.oid = c.relnamespace
                   JOIN pg_proc p ON p.oid = t.tgfoid
                   WHERE n.nspname = 'clearledger' AND NOT t.tgisinternal""")
    have_trg = {r[0]: (r[1], r[2], r[3]) for r in cur.fetchall()}
    for name, table, create, func, tgtype in TRIGGERS:
        if have_trg.get(name) != (func, tgtype, table):
            log(f"(re)creating trigger {name}")
            cur.execute(create)
    for table in ("settlements", "events", "outbox", "idempotency_keys"):
        cur.execute("""SELECT count(*) FROM pg_trigger t WHERE t.tgrelid = %s::regclass AND t.tgenabled <> 'O'""",
                    (f"clearledger.{table}",))
        if cur.fetchone()[0]:
            log(f"enabling triggers on {table}")
            cur.execute("SAVEPOINT en")
            try:
                cur.execute(f"ALTER TABLE clearledger.{table} ENABLE TRIGGER ALL")
            except psycopg2.Error as e:
                log(f"ENABLE TRIGGER ALL failed ({e.pgcode}); falling back to USER triggers")
                cur.execute("ROLLBACK TO SAVEPOINT en")
                cur.execute(f"ALTER TABLE clearledger.{table} ENABLE TRIGGER USER")
    conn.commit()

    # indexes: built outside the transaction (CONCURRENTLY) so live writers are not blocked.
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute("SET lock_timeout = '30s'")
    cur.execute("""SELECT i.relname, pg_get_indexdef(i.oid), x.indisvalid
                   FROM pg_index x JOIN pg_class i ON i.oid = x.indexrelid
                   JOIN pg_namespace n ON n.oid = i.relnamespace WHERE n.nspname = 'clearledger'""")
    have_idx = {r[0]: (r[1], r[2]) for r in cur.fetchall()}
    for name, create, expected in INDEXES:
        cur_def = have_idx.get(name)
        if cur_def and norm(cur_def[0]) == norm(expected) and cur_def[1]:
            continue
        if cur_def:
            log(f"dropping drifted index {name}")
            cur.execute(f"DROP INDEX IF EXISTS clearledger.{name}")
        log(f"creating index {name}")
        cur.execute(create.replace("CREATE INDEX", "CREATE INDEX CONCURRENTLY", 1)
                    .replace("CREATE UNIQUE INDEX", "CREATE UNIQUE INDEX CONCURRENTLY", 1))
    cur.close()
    conn.close()
    log("schema converged")

if __name__ == "__main__":
    apply_schema(sys.argv[1])

PYEOF_apply_schema

cat > "${WORK}/prekms.py" <<'PYEOF_prekms'
from common import *

USAGES = ("database", "messaging", "projection", "audit")

def reconcile_kms(cfg, state_path):
    """Undo out-of-band disable / pending deletion / rotation / tag drift on the four CMKs
    *before* terraform runs: a key in PendingDeletion looks 'deleted' to the provider and
    would cascade into replacing RDS, SQS, DynamoDB and S3 encryption."""
    prefix = cfg["resource_prefix"]
    kms = client(cfg, "kms")
    ids = {}
    st = state_resources(state_path)
    for u in USAGES:
        a = st.get(("aws_kms_key", "this", u))
        if a and a.get("key_id"):
            ids[u] = a["key_id"]
    # aliases (also covers a missing/stale state)
    try:
        pg = kms.get_paginator("list_aliases")
        for page in pg.paginate():
            for al in page["Aliases"]:
                for u in USAGES:
                    if al["AliasName"] == f"alias/{prefix}-{u}" and al.get("TargetKeyId"):
                        ids.setdefault(u, al["TargetKeyId"])
    except Exception as e:
        log("kms", f"list_aliases failed: {e}")
    for u in USAGES:
        kid = ids.get(u)
        if not kid:
            continue
        try:
            meta = kms.describe_key(KeyId=kid)["KeyMetadata"]
        except kms.exceptions.NotFoundException:
            continue
        state = meta.get("KeyState")
        if state == "PendingDeletion":
            log("kms", f"{u} key {kid} is pending deletion -> cancel_key_deletion")
            kms.cancel_key_deletion(KeyId=kid)
            state = "Disabled"
        meta = kms.describe_key(KeyId=kid)["KeyMetadata"]
        if not meta.get("Enabled") or meta.get("KeyState") != "Enabled":
            log("kms", f"{u} key {kid} is {meta.get('KeyState')} -> enable_key")
            kms.enable_key(KeyId=kid)
        try:
            if not kms.get_key_rotation_status(KeyId=kid).get("KeyRotationEnabled"):
                log("kms", f"{u} key rotation disabled -> enable_key_rotation")
                kms.enable_key_rotation(KeyId=kid)
        except Exception as e:
            log("kms", f"rotation check failed for {u}: {e}")
        try:
            tags = {t["TagKey"]: t["TagValue"] for t in kms.list_resource_tags(KeyId=kid).get("Tags", [])}
        except Exception:
            tags = {}
        want = {"ClearLedgerDeployment": prefix, "ClearLedgerKeyUsage": u, "Name": f"{prefix}-{u}"}
        missing = [{"TagKey": k, "TagValue": v} for k, v in want.items() if tags.get(k) != v]
        if missing:
            log("kms", f"{u} key tags drifted -> restoring {[m['TagKey'] for m in missing]}")
            kms.tag_resource(KeyId=kid, Tags=missing)

if __name__ == "__main__":
    cfg = load_cfg()
    reconcile_kms(cfg, sys.argv[1])

PYEOF_prekms

cat > "${WORK}/iamfix.py" <<'PYEOF_iamfix'
from common import *

ROLE_KEYS = {"ecs_execution": "ecs-execution", "ecs_task": "ecs-task", "projector": "projector",
             "relay": "relay", "archiver": "archiver", "scheduler": "scheduler"}


def delete_policy_fully(iam, arn):
    try:
        for v in iam.list_policy_versions(PolicyArn=arn).get("Versions", []):
            if not v.get("IsDefaultVersion"):
                iam.delete_policy_version(PolicyArn=arn, VersionId=v["VersionId"])
        iam.delete_policy(PolicyArn=arn)
    except Exception as e:
        log("iam", f"could not delete policy {arn}: {e}")


def reconcile_iam(cfg):
    """Each of the six roles keeps only its canonical Terraform-managed inline policy."""
    prefix = cfg["resource_prefix"]
    iam = client(cfg, "iam")
    for key, slug in ROLE_KEYS.items():
        role = f"{prefix}-{slug}"
        canonical = f"{prefix}-{key}-policy"
        try:
            iam.get_role(RoleName=role)
        except Exception:
            continue
        for name in iam.list_role_policies(RoleName=role).get("PolicyNames", []):
            if name != canonical:
                log("iam", f"removing out-of-band inline policy {name} from {role}")
                iam.delete_role_policy(RoleName=role, PolicyName=name)
        for p in iam.list_attached_role_policies(RoleName=role).get("AttachedPolicies", []):
            log("iam", f"detaching out-of-band managed policy {p['PolicyName']} from {role}")
            iam.detach_role_policy(RoleName=role, PolicyArn=p["PolicyArn"])
    # unattached prefix-scoped customer-managed policies
    try:
        for page in iam.get_paginator("list_policies").paginate(Scope="Local"):
            for p in page["Policies"]:
                if p["PolicyName"].startswith(prefix) and not p.get("AttachmentCount"):
                    log("iam", f"deleting unattached managed policy {p['PolicyName']}")
                    delete_policy_fully(iam, p["Arn"])
    except Exception as e:
        log("iam", f"policy listing failed: {e}")


def reconcile_sg(cfg, manifest):
    """Safety net behind Terraform's exclusive inline rules."""
    ec2 = client(cfg, "ec2")
    ids = manifest["network"]["security_group_ids"]
    groups = {g["GroupId"]: g for g in ec2.describe_security_groups(GroupIds=list(ids.values()))["SecurityGroups"]}

    def public(p):
        return any(r.get("CidrIp") == "0.0.0.0/0" for r in p.get("IpRanges", [])) or \
               any(r.get("CidrIpv6") == "::/0" for r in p.get("Ipv6Ranges", []))

    def revoke(gid, perms, egress):
        if not perms:
            return
        log("vpc", f"revoking {len(perms)} out-of-band {'egress' if egress else 'ingress'} rule(s) on {gid}")
        if egress:
            ec2.revoke_security_group_egress(GroupId=gid, IpPermissions=perms)
        else:
            ec2.revoke_security_group_ingress(GroupId=gid, IpPermissions=perms)

    for name, gid in ids.items():
        g = groups.get(gid)
        if not g:
            continue
        ing, egr = g.get("IpPermissions", []), g.get("IpPermissionsEgress", [])
        if name == "ecs":
            ok = lambda p: p.get("IpProtocol") == "tcp" and p.get("FromPort") == 8080 and p.get("ToPort") == 8080 \
                and not p.get("IpRanges") and not p.get("Ipv6Ranges") \
                and [x["GroupId"] for x in p.get("UserIdGroupPairs", [])] == [ids["alb"]]
            revoke(gid, [p for p in ing if not ok(p)], False)
        elif name in ("rds", "valkey"):
            revoke(gid, [p for p in ing if public(p)], False)
            revoke(gid, egr, True)
        elif name == "alb":
            revoke(gid, [p for p in egr if public(p)], True)

PYEOF_iamfix

cat > "${WORK}/data.py" <<'PYEOF_data'
"""Bidirectional convergence of the derived data stores against PostgreSQL."""
import urllib.request, urllib.parse, base64, concurrent.futures as cf
import psycopg2, psycopg2.extras, redis
from decimal import Decimal
from boto3.dynamodb.types import TypeDeserializer
from common import *

TAG = "data"
DES = TypeDeserializer()


def dsn_from(cfg, manifest):
    d = manifest["database"]
    return f"postgres://{cfg['db_username']}:{cfg['db_password']}@{d['endpoint']}:{d['port']}/{cfg['db_name']}"


def parse_ts(v):
    if isinstance(v, datetime.datetime):
        return v if v.tzinfo else v.replace(tzinfo=datetime.timezone.utc)
    s = str(v).strip()
    if s[-1:] in ("Z", "z"):
        s = s[:-1] + "+00:00"
    s = re.sub(r"\.(\d+)", lambda m: "." + m.group(1)[:6].ljust(6, "0"), s, count=1)
    dt = datetime.datetime.fromisoformat(s)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    return dt.astimezone(datetime.timezone.utc)


def invoke(lam, fn, payload, tries=3):
    last = None
    for i in range(tries):
        try:
            r = lam.invoke(FunctionName=fn, Payload=json.dumps(payload).encode())
            body = r["Payload"].read()
            if r.get("FunctionError"):
                last = f"FunctionError {r['FunctionError']}: {body[:300]!r}"
                time.sleep(1 + i)
                continue
            try:
                return json.loads(body or b"{}")
            except Exception:
                return {"raw": body.decode("utf-8", "replace")}
        except Exception as e:
            last = str(e)
            time.sleep(1 + i)
    log(TAG, f"invoke {fn} failed: {last}")
    return None


# ------------------------------------------------------------------ outbox relay
def converge_outbox(cfg, conn, lam, relay_fn):
    cur = conn.cursor()
    for attempt in range(60):
        cur.execute("SELECT count(*) FROM clearledger.outbox WHERE published_at IS NULL")
        n = cur.fetchone()[0]
        conn.commit()
        if n == 0:
            if attempt:
                log("outbox", "all outbox rows published")
            return True
        log("outbox", f"{n} unpublished outbox rows -> invoking relay")
        r = invoke(lam, relay_fn, {})
        if r is None or (r.get("published", 0) == 0 and r.get("failed", 0) > 0):
            time.sleep(3)
    log("outbox", "WARNING: unpublished outbox rows remain")
    return False


def wait_queue_drain(cfg, manifest, timeout=45):
    sqs = client(cfg, "sqs")
    url = manifest["messaging"]["queue_url"]
    end = time.time() + timeout
    while time.time() < end:
        try:
            a = sqs.get_queue_attributes(QueueUrl=url, AttributeNames=["ApproximateNumberOfMessages",
                                         "ApproximateNumberOfMessagesNotVisible"])["Attributes"]
        except Exception as e:
            log("sqs", f"cannot read queue attributes: {e}")
            return
        if int(a["ApproximateNumberOfMessages"]) + int(a["ApproximateNumberOfMessagesNotVisible"]) == 0:
            return
        time.sleep(2)
    log("sqs", "queue still has messages after wait; continuing (projector writes are idempotent)")


# ------------------------------------------------------------------ DynamoDB
STATE_REQ = {"PK", "SK", "GSI1PK", "GSI1SK", "settlement_id", "account_id", "reference", "debit_party",
             "credit_party", "status", "clearing_stage", "version", "entry_count", "updated_at"}
STATE_OPT = {"last_entry_id", "last_memo"}
EVENT_REQ = {"PK", "SK", "settlement_id", "event_id", "version", "event_type", "status", "clearing_stage",
             "occurred_at", "correlation_id", "envelope"}
EVENT_OPT = {"entry_id", "memo"}


def deser(item):
    out = {}
    for k, v in item.items():
        x = DES.deserialize(v)
        if isinstance(x, Decimal):
            x = int(x) if x == x.to_integral_value() else x
        out[k] = x
    return out


def check_state(it, s, events):
    """Return None when consistent, 'behind' when merely older, or a reason string."""
    names = set(it)
    if names - STATE_REQ - STATE_OPT:
        return f"unexpected attributes {sorted(names - STATE_REQ - STATE_OPT)}"
    if STATE_REQ - names:
        return f"missing attributes {sorted(STATE_REQ - names)}"
    sid = str(s["settlement_id"])
    try:
        if int(it["version"]) < s["version"]:
            return "behind"
        exp = {
            "PK": f"SETTLEMENT#{sid}", "SK": "STATE", "GSI1PK": f"ACCOUNT#{s['account_id']}",
            "GSI1SK": f"SETTLEMENT#{sid}", "settlement_id": sid, "account_id": s["account_id"],
            "reference": s["reference"], "debit_party": s["debit_party"], "credit_party": s["credit_party"],
            "status": s["current_status"], "clearing_stage": s["current_stage"], "version": s["version"],
            "entry_count": s["entry_count"],
        }
        for k, v in exp.items():
            if it.get(k) != v:
                return f"{k}={it.get(k)!r} expected {v!r}"
        if parse_ts(it["updated_at"]) != parse_ts(s["updated_at"]):
            return f"updated_at={it['updated_at']!r}"
        le = str(s["last_entry_id"]) if s["last_entry_id"] else None
        if it.get("last_entry_id") != le:
            return f"last_entry_id={it.get('last_entry_id')!r} expected {le!r}"
        if "last_memo" in it:
            retained = None
            for ev in events:
                m = ev["payload"].get("data", {}).get("memo")
                if m is not None:
                    retained = m
            if it["last_memo"] not in (s["last_memo"], retained):
                return f"last_memo={it['last_memo']!r}"
    except Exception as e:
        return f"unparseable state item: {e}"
    return None


def check_event(it, ev, sid):
    names = set(it)
    if names - EVENT_REQ - EVENT_OPT:
        return f"unexpected attributes {sorted(names - EVENT_REQ - EVENT_OPT)}"
    if EVENT_REQ - names:
        return f"missing attributes {sorted(EVENT_REQ - names)}"
    p = ev["payload"]
    d = p.get("data", {})
    try:
        exp = {"PK": f"SETTLEMENT#{sid}", "SK": f"EVENT#{ev['aggregate_version']:08d}", "settlement_id": sid,
               "event_id": str(ev["event_id"]), "version": ev["aggregate_version"], "event_type": ev["event_type"],
               "status": d.get("status"), "clearing_stage": d.get("clearingStage"),
               "correlation_id": ev["correlation_id"]}
        for k, v in exp.items():
            if it.get(k) != v:
                return f"{k}={it.get(k)!r} expected {v!r}"
        if parse_ts(it["occurred_at"]) != parse_ts(ev["occurred_at"]):
            return f"occurred_at={it['occurred_at']!r}"
        if json.loads(it["envelope"]) != p:
            return "envelope differs from PostgreSQL payload"
        for attr, key in (("entry_id", "entryId"), ("memo", "memo")):
            want = d.get(key)
            if want is None:
                if attr in it and it[attr] is not None:
                    return f"{attr} should be absent"
            elif it.get(attr) != want:
                return f"{attr}={it.get(attr)!r} expected {want!r}"
    except Exception as e:
        return f"unparseable event item: {e}"
    return None


def load_pg(conn):
    cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    cur.execute("SELECT * FROM clearledger.settlements ORDER BY created_at, settlement_id")
    settlements = {str(r["settlement_id"]): r for r in cur.fetchall()}
    cur.execute("SELECT seq, event_id, settlement_id, aggregate_version, event_type, correlation_id, occurred_at, payload "
                "FROM clearledger.events ORDER BY settlement_id, aggregate_version")
    events = {}
    for r in cur.fetchall():
        events.setdefault(str(r["settlement_id"]), []).append(r)
    conn.commit()
    return settlements, events


def scan_table(ddb, table):
    items = []
    kw = {"TableName": table, "ConsistentRead": True}
    while True:
        r = ddb.scan(**kw)
        items.extend(deser(i) for i in r["Items"])
        if "LastEvaluatedKey" not in r:
            return items
        kw["ExclusiveStartKey"] = r["LastEvaluatedKey"]


def batch_delete(ddb, table, keys):
    keys = list(keys)
    for i in range(0, len(keys), 25):
        chunk = [{"DeleteRequest": {"Key": {"PK": {"S": pk}, "SK": {"S": sk}}}} for pk, sk in keys[i:i + 25]]
        req = {table: chunk}
        for _ in range(8):
            r = ddb.batch_write_item(RequestItems=req)
            req = r.get("UnprocessedItems") or {}
            if not req:
                break
            time.sleep(0.5)


def diagnose(items_by_pk, settlements, events):
    """-> (orphan_keys, {sid: (delete_keys, reason)})"""
    orphan, bad = [], {}
    for pk, items in items_by_pk.items():
        m = re.match(r"^SETTLEMENT#(.+)$", pk or "")
        sid = m.group(1) if m else None
        if sid not in settlements:
            orphan.extend((pk, it["SK"]) for it in items.values())
    for sid, s in settlements.items():
        pk = f"SETTLEMENT#{sid}"
        items = items_by_pk.get(pk, {})
        evs = events.get(sid, [])
        dele, reasons = [], []
        want_sk = {"STATE"} | {f"EVENT#{e['aggregate_version']:08d}" for e in evs}
        for sk, it in items.items():
            if sk not in want_sk:
                dele.append((pk, sk))
                reasons.append(f"stray {sk}")
        st = items.get("STATE")
        if st is None:
            reasons.append("STATE missing")
        else:
            r = check_state(st, s, evs)
            if r == "behind":
                reasons.append("STATE behind")
            elif r:
                dele.append((pk, "STATE"))
                reasons.append(f"STATE {r}")
        for e in evs:
            sk = f"EVENT#{e['aggregate_version']:08d}"
            it = items.get(sk)
            if it is None:
                reasons.append(f"{sk} missing")
            else:
                r = check_event(it, e, sid)
                if r:
                    dele.append((pk, sk))
                    reasons.append(f"{sk} {r}")
        if reasons:
            bad[sid] = (dele, reasons)
    return orphan, bad


def replay(lam, fn, evs):
    ok = True
    for i in range(0, len(evs), 5):
        chunk = evs[i:i + 5]
        recs = [{"messageId": str(e["event_id"]), "body": json.dumps(e["payload"]),
                 "eventSource": "aws:sqs", "attributes": {}, "messageAttributes": {}} for e in chunk]
        r = invoke(lam, fn, {"Records": recs})
        if r is None or r.get("batchItemFailures"):
            ok = False
    return ok


def converge_dynamo(cfg, manifest, conn):
    ddb = client(cfg, "dynamodb")
    lam = client(cfg, "lambda")
    table = manifest["projections"]["table_name"]
    fn = manifest["workers"]["projector"]["function_name"]
    for rnd in (1, 2):
        settlements, events = load_pg(conn)
        by_pk = {}
        for it in scan_table(ddb, table):
            by_pk.setdefault(it.get("PK"), {})[it.get("SK")] = it
        orphan, bad = diagnose(by_pk, settlements, events)
        if not orphan and not bad:
            log("dynamodb", f"projection table converged ({len(settlements)} settlements)")
            return True
        if rnd == 2:
            log("dynamodb", f"WARNING: {len(bad)} settlements / {len(orphan)} orphan items still divergent")
            for sid, (_, why) in list(bad.items())[:5]:
                log("dynamodb", f"  {sid}: {why[:3]}")
            return False
        if orphan:
            log("dynamodb", f"deleting {len(orphan)} orphan/stray items")
            batch_delete(ddb, table, orphan)
        todo = []
        for sid, (dele, why) in bad.items():
            log("dynamodb", f"repairing {sid}: {'; '.join(why[:3])}")
            if dele:
                batch_delete(ddb, table, dele)
            todo.append(sid)
        with cf.ThreadPoolExecutor(max_workers=6) as ex:
            list(ex.map(lambda sid: replay(lam, fn, events.get(sid, [])), todo))
    return False


# ------------------------------------------------------------------ S3 audit archive
CANON = re.compile(r"^ledger-audit/batch-(\d{8})-(\d{8})-([0-9a-f]{16})\.ndjson$")


def list_versions(s3, bucket):
    versions, markers = [], []
    kw = {"Bucket": bucket}
    while True:
        r = s3.list_object_versions(**kw)
        versions.extend(r.get("Versions", []))
        markers.extend(r.get("DeleteMarkers", []))
        if not r.get("IsTruncated"):
            return versions, markers
        kw["KeyMarker"] = r.get("NextKeyMarker")
        kw["VersionIdMarker"] = r.get("NextVersionIdMarker")


def purge_versions(s3, bucket, entries):
    entries = list(entries)
    for i in range(0, len(entries), 500):
        chunk = entries[i:i + 500]
        s3.delete_objects(Bucket=bucket, Delete={"Objects": [{"Key": e["Key"], "VersionId": e["VersionId"]}
                                                              for e in chunk], "Quiet": True})


def abort_uploads(s3, bucket):
    try:
        r = s3.list_multipart_uploads(Bucket=bucket)
        for u in r.get("Uploads", []):
            s3.abort_multipart_upload(Bucket=bucket, Key=u["Key"], UploadId=u["UploadId"])
    except Exception as e:
        log("s3", f"multipart cleanup skipped: {e}")


def load_outbox(conn):
    cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    cur.execute("SELECT seq, event_id, payload, published_at, archived_at FROM clearledger.outbox ORDER BY seq")
    rows = cur.fetchall()
    conn.commit()
    return rows


def audit_state(s3, bucket, rows):
    """Classify the bucket.  Returns dict with valid batches, bad version entries, covered seq set."""
    versions, markers = list_versions(s3, bucket)
    by_event = {str(r["event_id"]): r for r in rows}
    seqs = sorted(r["seq"] for r in rows)
    bad_entries = list(markers)
    latest = {}
    for v in versions:
        if v.get("IsLatest"):
            latest[v["Key"]] = v
        else:
            bad_entries.append(v)
    marker_latest = {m["Key"] for m in markers if m.get("IsLatest")}
    cands = []
    for key, v in latest.items():
        if key in marker_latest:
            bad_entries.append(v)
            continue
        m = CANON.match(key)
        reason = None
        if not m:
            reason = "non-canonical key"
        else:
            first, last, h = int(m.group(1)), int(m.group(2)), m.group(3)
            body = s3.get_object(Bucket=bucket, Key=key, VersionId=v["VersionId"])["Body"].read()
            if hashlib.sha256(body).hexdigest()[:16] != h:
                reason = "sha256 mismatch"
            else:
                try:
                    text = body.decode("utf-8")
                    lines = text.split("\n")
                    if lines and lines[-1] == "":
                        lines.pop()
                    got = []
                    for ln in lines:
                        p = json.loads(ln)
                        row = by_event.get(p.get("eventId"))
                        if row is None or row["payload"] != p:
                            raise ValueError("line does not match an outbox row")
                        got.append(row["seq"])
                    if not got or got != sorted(set(got)) or got[0] != first or got[-1] != last:
                        raise ValueError("seq bounds/order mismatch")
                    if got != [s for s in seqs if first <= s <= last]:
                        raise ValueError("not a gap-free slice of the outbox")
                    cands.append((first, last, key, v, set(got)))
                except Exception as e:
                    reason = str(e)
        if reason:
            log("s3", f"invalid audit object {key}: {reason}")
            bad_entries.append(v)
    cands.sort()
    valid, covered, hi = [], set(), 0
    for first, last, key, v, got in cands:
        if first <= hi:
            log("s3", f"overlapping audit object {key}")
            bad_entries.append(v)
            continue
        valid.append(key)
        covered |= got
        hi = last
    return {"valid": valid, "bad": bad_entries, "covered": covered, "all": versions + markers}


def pause_schedule(cfg, name, state):
    """Best effort: flip a schedule state without losing its definition."""
    try:
        sc = client(cfg, "scheduler")
        s = sc.get_schedule(Name=name)
        if s.get("State") == state:
            return s.get("State")
        kw = dict(Name=name, ScheduleExpression=s["ScheduleExpression"], FlexibleTimeWindow=s["FlexibleTimeWindow"],
                  Target=s["Target"], State=state)
        for k in ("GroupName", "Description", "ScheduleExpressionTimezone", "StartDate", "EndDate", "KmsKeyArn"):
            if s.get(k):
                kw[k] = s[k]
        sc.update_schedule(**kw)
        return s.get("State")
    except Exception as e:
        log("s3", f"could not set schedule {name} to {state}: {e}")
        return None


def run_archiver(lam, fn):
    total = 0
    for _ in range(2000):
        r = invoke(lam, fn, {})
        if r is None:
            return False
        n = int(r.get("archived", 0) or 0)
        total += n
        if n == 0:
            break
    log("s3", f"archiver wrote {total} rows")
    return True


def converge_s3(cfg, manifest, conn):
    s3 = client(cfg, "s3")
    lam = client(cfg, "lambda")
    bucket = manifest["audit"]["bucket_name"]
    arch_fn = manifest["workers"]["audit_archiver"]["function_name"]
    relay_fn = manifest["workers"]["outbox_relay"]["function_name"]
    sched = manifest["schedules"]["archive_schedule_name"]
    abort_uploads(s3, bucket)

    rows = load_outbox(conn)
    st = audit_state(s3, bucket, rows)
    covered = st["covered"]
    rows_by_seq = {r["seq"]: r for r in rows}
    uncovered = [r for r in rows if r["seq"] not in covered]
    hi = max(covered) if covered else 0
    stamp = [r for r in rows if r["seq"] in covered and r["archived_at"] is None]
    need_work = bool(uncovered) or bool(stamp)
    rebuild = any(r["seq"] < hi for r in uncovered) or any(r["published_at"] is None for r in stamp)

    if not need_work:
        if st["bad"]:
            log("s3", f"purging {len(st['bad'])} invalid/noncurrent object versions and delete markers")
            purge_versions(s3, bucket, st["bad"])
        log("s3", f"audit archive converged ({len(st['valid'])} batches)")
        return True

    prev = pause_schedule(cfg, sched, "DISABLED")
    try:
        cur = conn.cursor()
        if rebuild:
            log("s3", "audit archive inconsistent with outbox -> full rebuild from PostgreSQL")
            purge_versions(s3, bucket, st["all"])
            cur.execute("UPDATE clearledger.outbox SET archived_at = NULL WHERE archived_at IS NOT NULL")
            conn.commit()
        else:
            if st["bad"]:
                purge_versions(s3, bucket, st["bad"])
            if stamp:
                log("s3", f"stamping {len(stamp)} rows already present in valid batches")
                cur.execute("UPDATE clearledger.outbox SET archived_at = NOW() "
                            "WHERE seq = ANY(%s) AND archived_at IS NULL AND published_at IS NOT NULL",
                            ([r["seq"] for r in stamp],))
            res = [r["seq"] for r in uncovered if r["archived_at"] is not None]
            if res:
                cur.execute("UPDATE clearledger.outbox SET archived_at = NULL WHERE seq = ANY(%s)", (res,))
            conn.commit()
        converge_outbox(cfg, conn, lam, relay_fn)
        run_archiver(lam, arch_fn)
    finally:
        if prev == "ENABLED":
            pause_schedule(cfg, sched, "ENABLED")

    rows = load_outbox(conn)
    st = audit_state(s3, bucket, rows)
    if st["bad"]:
        purge_versions(s3, bucket, st["bad"])
    left = [r for r in rows if r["seq"] not in st["covered"] or r["archived_at"] is None]
    if left:
        log("s3", f"WARNING: {len(left)} outbox rows are not covered by audit batches")
        return False
    log("s3", f"audit archive converged ({len(st['valid'])} batches)")
    return True


# ------------------------------------------------------------------ Valkey
def fetch_token(manifest, which="read"):
    c = manifest["auth"]["clients"][which]
    basic = base64.b64encode(f"{c['client_id']}:{c['client_secret']}".encode()).decode()
    data = urllib.parse.urlencode({"grant_type": "client_credentials", "scope": c["scope"]}).encode()
    req = urllib.request.Request(manifest["auth"]["token_endpoint"], data=data,
                                 headers={"Authorization": f"Basic {basic}",
                                          "Content-Type": "application/x-www-form-urlencoded"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read())["access_token"]


def http_get(url, token):
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}", "X-Correlation-Id": "deploy-warm"})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status, r.headers, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read()


def projection_json(it):
    out = {"settlementId": it["settlement_id"], "accountId": it["account_id"], "reference": it["reference"],
           "debitParty": it["debit_party"], "creditParty": it["credit_party"], "status": it["status"],
           "clearingStage": it["clearing_stage"], "lastEntryId": it.get("last_entry_id"),
           "lastMemo": it.get("last_memo"), "version": it["version"], "entryCount": it["entry_count"],
           "updatedAt": parse_ts(it["updated_at"]).strftime("%Y-%m-%dT%H:%M:%S.%fZ")}
    return out


def converge_valkey(cfg, manifest, conn):
    c = manifest["cache"]
    r = redis.Redis(host=c["endpoint"], port=int(c["port"]), socket_timeout=10, socket_connect_timeout=10)
    settlements, _ = load_pg(conn)
    keys = [k for k in r.scan_iter(match="*", count=1000)]
    if keys:
        log("valkey", f"clearing {len(keys)} cache keys before repopulating")
        for i in range(0, len(keys), 500):
            r.delete(*keys[i:i + 500])
    base = manifest["service_url"].rstrip("/")
    try:
        token = fetch_token(manifest, "read")
    except Exception as e:
        token = None
        log("valkey", f"could not obtain read token ({e}); writing cache entries directly")
    ddb = client(cfg, "dynamodb")
    table = manifest["projections"]["table_name"]

    def warm(sid):
        key = f"clearledger:settlement:{sid}".encode()
        if token:
            for _ in range(3):
                try:
                    code, hdr, body = http_get(f"{base}/v1/settlements/{sid}", token)
                except Exception:
                    code = None
                if code == 200 and r.ttl(key) > 0:
                    return True
                if code == 200:
                    break
                time.sleep(1)
        # direct fallback built from the DynamoDB STATE item
        item = ddb.get_item(TableName=table, Key={"PK": {"S": f"SETTLEMENT#{sid}"}, "SK": {"S": "STATE"}},
                            ConsistentRead=True).get("Item")
        if not item:
            return False
        p = projection_json(deser(item))
        r.set(key, json.dumps(p, separators=(",", ":")), ex=90)
        return True

    with cf.ThreadPoolExecutor(max_workers=8) as ex:
        res = list(ex.map(warm, list(settlements)))
    failed = [s for s, ok in zip(settlements, res) if not ok]
    if failed:
        log("valkey", f"WARNING: {len(failed)} settlements could not be cached")
    # verify
    want = {f"clearledger:settlement:{s}" for s in settlements}
    have = {k.decode() for k in r.scan_iter(match="*", count=1000)}
    if have != want:
        log("valkey", f"WARNING: key mismatch missing={len(want - have)} extra={len(have - want)}")
        return False
    log("valkey", f"cache converged ({len(want)} entries)")
    return not failed

PYEOF_data

cat > "${WORK}/clctl.py" <<'PYEOF_clctl'
import sys, subprocess
from common import *

def main():
    phase = sys.argv[1]
    cfg = load_cfg(os.environ.get("CLEARLEDGER_CONFIG", "/workspace/config/config.json"))
    if phase == "prekms":
        from prekms import reconcile_kms
        reconcile_kms(cfg, sys.argv[2])
        return 0
    manifest = json.load(open(sys.argv[2]))
    if phase == "schema":
        from apply_schema import apply_schema
        from data import dsn_from
        dsn = dsn_from(cfg, manifest)
        last = None
        for i in range(90):
            try:
                apply_schema(dsn)
                return 0
            except Exception as e:
                last = e
                if i % 5 == 0:
                    log("schema", f"waiting for PostgreSQL: {str(e).strip()[:120]}")
                time.sleep(4)
        log("schema", f"FAILED: {last}")
        return 1
    if phase == "iam":
        from iamfix import reconcile_iam, reconcile_sg
        reconcile_iam(cfg)
        reconcile_sg(cfg, manifest)
        return 0
    if phase == "data":
        import psycopg2
        import data
        conn = psycopg2.connect(data.dsn_from(cfg, manifest), connect_timeout=10)
        lam = client(cfg, "lambda")
        results = {}
        results["outbox"] = data.converge_outbox(cfg, conn, lam, manifest["workers"]["outbox_relay"]["function_name"])
        data.wait_queue_drain(cfg, manifest)
        results["dynamodb"] = data.converge_dynamo(cfg, manifest, conn)
        results["s3"] = data.converge_s3(cfg, manifest, conn)
        results["valkey"] = data.converge_valkey(cfg, manifest, conn)
        log("data", f"summary: {results}")
        return 0 if all(results.values()) else 2
    raise SystemExit(f"unknown phase {phase}")

if __name__ == "__main__":
    sys.exit(main())

PYEOF_clctl


tf_apply() {
  ( cd "${INFRA}" && timeout 500 "${TF}" apply -auto-approve -input=false -no-color -lock-timeout=60s \
      -var "config_file=${CONFIG}" )
}

log "prefix=${PREFIX} region=${REGION} endpoint=${ENDPOINT} tool=${TF}"

log "terraform init"
( cd "${INFRA}" && "${TF}" init -input=false -no-color >/dev/null )

log "pre-apply control-plane repair (KMS keys: pending deletion / disabled / rotation / tags)"
python3 "${WORK}/clctl.py" prekms "${STATE}"

log "terraform apply"
if ! tf_apply; then
  log "apply failed; repairing and retrying once"
  python3 "${WORK}/clctl.py" prekms "${STATE}"
  sleep 5
  tf_apply
fi

export_manifest() {
  ( cd "${INFRA}" && "${TF}" output -json manifest ) | jq -S . > "${WORK}/manifest.new"
  python3 - "${WORK}/manifest.new" "${SCHEMA_JSON}" <<'PYV'
import json, sys
m = json.load(open(sys.argv[1]))
try:
    import jsonschema
    jsonschema.validate(m, json.load(open(sys.argv[2])))
except ImportError:
    pass
PYV
  mv "${WORK}/manifest.new" "${MANIFEST}"
  chmod 0644 "${MANIFEST}"
}
log "exporting manifest"
export_manifest

log "applying PostgreSQL schema, constraints, triggers and indexes"
python3 "${WORK}/clctl.py" schema "${MANIFEST}"

log "reconciling IAM role policies and security group rules"
python3 "${WORK}/clctl.py" iam "${MANIFEST}"

SERVICE_URL="$(jq -r .service_url "${MANIFEST}")"
wait_ready() {
  local deadline=$(( SECONDS + $1 )) code=000
  while (( SECONDS < deadline )); do
    code="$(curl -s -o "${WORK}/ready.body" -w '%{http_code}' -m 5 "${SERVICE_URL}/health/ready" || true)"
    if [[ "${code}" == "200" ]]; then return 0; fi
    sleep 3
  done
  log "last readiness response: ${code} $(head -c 300 "${WORK}/ready.body" 2>/dev/null || true)"
  return 1
}
log "waiting for ${SERVICE_URL}/health/ready"
wait_ready 240 || { log "API did not become ready"; exit 1; }
log "API ready"

log "converging data stores against PostgreSQL (outbox -> SQS, DynamoDB, S3 audit archive, Valkey)"
rc=0
python3 "${WORK}/clctl.py" data "${MANIFEST}" || rc=$?
if (( rc != 0 )); then
  log "data convergence reported unresolved items (rc=${rc}); retrying once"
  sleep 3
  python3 "${WORK}/clctl.py" data "${MANIFEST}"
fi

# the data phase may have disturbed nothing, but make sure the service still answers
wait_ready 60 || { log "API not ready after convergence"; exit 1; }
export_manifest
log "deploy complete: ${SERVICE_URL}"
