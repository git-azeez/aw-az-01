#!/usr/bin/env bash
set -euo pipefail

unset HTTP_PROXY http_proxy HTTPS_PROXY https_proxy
export PATH="/opt/venv/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
export NO_PROXY="localhost,127.0.0.1,::1,aws,runtime"
export no_proxy="localhost,127.0.0.1,::1,aws,runtime"

CONFIG_FILE="/workspace/config/config.json"
SUBMISSION_DIR="/workspace/submission"
INFRA_DIR="${SUBMISSION_DIR}/infra"
STATE_FILE="${INFRA_DIR}/terraform.tfstate"
MANIFEST_FILE="${SUBMISSION_DIR}/manifest.json"
TFVARS_FILE="${INFRA_DIR}/config.auto.tfvars.json"

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "Missing ${CONFIG_FILE}" >&2
  exit 1
fi

if command -v terraform >/dev/null 2>&1; then
  IAC_BIN="terraform"
elif command -v tofu >/dev/null 2>&1; then
  IAC_BIN="tofu"
else
  echo "Neither terraform nor tofu is available" >&2
  exit 1
fi

export AWS_REGION="$(jq -r '.region' "${CONFIG_FILE}")"
export AWS_DEFAULT_REGION="${AWS_REGION}"
export AWS_ENDPOINT_URL="$(jq -r '.aws_endpoint_url' "${CONFIG_FILE}")"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export TF_IN_AUTOMATION=1

cp "${CONFIG_FILE}" "${TFVARS_FILE}"

pushd "${INFRA_DIR}" >/dev/null

"${IAC_BIN}" init -input=false -no-color >/dev/null

"${IAC_BIN}" apply \
  -input=false \
  -auto-approve \
  -no-color \
  -state="${STATE_FILE}"

"${IAC_BIN}" output \
  -json \
  -state="${STATE_FILE}" \
  manifest >"${MANIFEST_FILE}.tmp"

mv "${MANIFEST_FILE}.tmp" "${MANIFEST_FILE}"
popd >/dev/null

DB_RAW_HOST="$(jq -r '.database.endpoint' "${MANIFEST_FILE}")"
if [[ "${DB_RAW_HOST}" == "localhost" || "${DB_RAW_HOST}" == *.amazonaws.com ]]; then
  DB_HOST="aws"
else
  DB_HOST="${DB_RAW_HOST}"
fi
DB_PORT="$(jq -r '.database.port' "${MANIFEST_FILE}")"
DB_NAME="$(jq -r '.database.db_name' "${MANIFEST_FILE}")"
DB_USER="$(jq -r '.database.username' "${MANIFEST_FILE}")"
export PGPASSWORD="$(jq -r '.db_password' "${CONFIG_FILE}")"

for _ in $(seq 1 30); do
  if psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -c "SELECT 1" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

psql -v ON_ERROR_STOP=1 -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" <<'SQL' >/dev/null
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
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_settlements_nonempty_fields CHECK (
        char_length(btrim(account_id)) >= 3
        AND btrim(reference) <> ''
        AND btrim(debit_party) <> ''
        AND btrim(credit_party) <> ''
        AND char_length(btrim(current_stage)) >= 2
    ),
    CONSTRAINT chk_settlements_distinct_parties CHECK (debit_party <> credit_party),
    CONSTRAINT chk_settlements_version_positive CHECK (version >= 1),
    CONSTRAINT chk_settlements_entry_count_version CHECK (entry_count >= 0 AND entry_count = version - 1),
    CONSTRAINT chk_settlements_lifecycle_state CHECK (
        (
            version = 1
            AND entry_count = 0
            AND current_status = 'INITIATED'
            AND last_entry_id IS NULL
            AND (last_memo IS NULL OR btrim(last_memo) <> '')
        )
        OR
        (version > 1 AND entry_count = version - 1 AND current_status <> 'INITIATED' AND last_entry_id IS NOT NULL)
    ),
    CONSTRAINT chk_settlements_status_enum CHECK (
        current_status IN (
            'INITIATED',
            'VALIDATED',
            'RESERVED',
            'CLEARED',
            'SETTLED',
            'RECONCILED',
            'DISPUTED'
        )
    )
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
    UNIQUE (settlement_id, aggregate_version),
    CONSTRAINT chk_events_nonempty_fields CHECK (
        char_length(btrim(correlation_id)) >= 4
        AND char_length(btrim(idempotency_key)) BETWEEN 8 AND 128
    ),
    CONSTRAINT chk_events_version_positive CHECK (aggregate_version >= 1),
    CONSTRAINT chk_events_type_version CHECK (
        (event_type = 'SettlementInitiated' AND aggregate_version = 1)
        OR
        (event_type = 'LedgerEntryRecorded' AND aggregate_version >= 2)
    ),
    CONSTRAINT chk_events_payload_coherence CHECK (
        (
            jsonb_typeof(payload) = 'object'
            AND payload->>'schemaVersion' = '1.0'
            AND payload->>'aggregateType' = 'settlement'
            AND payload->>'eventId' = event_id::text
            AND payload->>'aggregateId' = settlement_id::text
            AND (payload->>'aggregateVersion') ~ '^[0-9]+$'
            AND (payload->>'aggregateVersion')::integer = aggregate_version
            AND payload->>'eventType' = event_type
            AND payload->>'correlationId' = correlation_id
            AND payload->>'idempotencyKey' = idempotency_key
            AND btrim(COALESCE(payload->>'occurredAt', '')) <> ''
            AND jsonb_typeof(payload->'data') = 'object'
            AND char_length(btrim(COALESCE(payload #>> '{data,accountId}', ''))) >= 3
            AND char_length(btrim(COALESCE(payload #>> '{data,clearingStage}', ''))) >= 2
            AND (
                (
                    event_type = 'SettlementInitiated'
                    AND payload #>> '{data,kind}' = 'settlementInitiated'
                    AND payload #>> '{data,status}' = 'INITIATED'
                    AND (payload->'data'->'entryId' IS NULL OR jsonb_typeof(payload->'data'->'entryId') = 'null')
                    AND btrim(COALESCE(payload #>> '{data,reference}', '')) <> ''
                    AND btrim(COALESCE(payload #>> '{data,debitParty}', '')) <> ''
                    AND btrim(COALESCE(payload #>> '{data,creditParty}', '')) <> ''
                    AND (payload #>> '{data,debitParty}') <> (payload #>> '{data,creditParty}')
                )
                OR
                (
                    event_type = 'LedgerEntryRecorded'
                    AND payload #>> '{data,kind}' = 'ledgerEntryRecorded'
                    AND (payload #>> '{data,status}') IN ('VALIDATED', 'RESERVED', 'CLEARED', 'SETTLED', 'RECONCILED', 'DISPUTED')
                    AND btrim(COALESCE(payload #>> '{data,entryId}', '')) <> ''
                )
            )
        ) IS TRUE
    )
);

CREATE TABLE IF NOT EXISTS clearledger.outbox (
    seq BIGSERIAL PRIMARY KEY,
    event_id UUID NOT NULL UNIQUE REFERENCES clearledger.events(event_id) ON DELETE CASCADE,
    settlement_id UUID NOT NULL REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE,
    aggregate_version INTEGER NOT NULL,
    correlation_id TEXT NOT NULL,
    payload JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    published_at TIMESTAMPTZ NULL,
    archived_at TIMESTAMPTZ NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    last_error TEXT NULL,
    UNIQUE (settlement_id, aggregate_version),
    FOREIGN KEY (settlement_id, aggregate_version)
        REFERENCES clearledger.events(settlement_id, aggregate_version) ON DELETE CASCADE,
    CONSTRAINT chk_outbox_nonempty_corr CHECK (char_length(btrim(correlation_id)) >= 4),
    CONSTRAINT chk_outbox_version_positive CHECK (aggregate_version >= 1),
    CONSTRAINT chk_outbox_attempts_nonnegative CHECK (attempts >= 0),
    CONSTRAINT chk_outbox_published_attempts CHECK (
        published_at IS NULL OR (attempts >= 1 AND last_error IS NULL)
    ),
    CONSTRAINT chk_outbox_archived_requires_published CHECK (
        archived_at IS NULL OR (published_at IS NOT NULL AND archived_at >= published_at)
    ),
    CONSTRAINT chk_outbox_payload_coherence CHECK (
        (
            jsonb_typeof(payload) = 'object'
            AND payload->>'schemaVersion' = '1.0'
            AND payload->>'aggregateType' = 'settlement'
            AND payload->>'eventId' = event_id::text
            AND payload->>'aggregateId' = settlement_id::text
            AND (payload->>'aggregateVersion') ~ '^[0-9]+$'
            AND (payload->>'aggregateVersion')::integer = aggregate_version
            AND payload->>'correlationId' = correlation_id
            AND char_length(btrim(COALESCE(payload->>'idempotencyKey', ''))) BETWEEN 8 AND 128
            AND btrim(COALESCE(payload->>'occurredAt', '')) <> ''
            AND jsonb_typeof(payload->'data') = 'object'
            AND char_length(btrim(COALESCE(payload #>> '{data,accountId}', ''))) >= 3
            AND char_length(btrim(COALESCE(payload #>> '{data,clearingStage}', ''))) >= 2
            AND (
                (
                    aggregate_version = 1
                    AND payload->>'eventType' = 'SettlementInitiated'
                    AND payload #>> '{data,kind}' = 'settlementInitiated'
                    AND payload #>> '{data,status}' = 'INITIATED'
                    AND (payload->'data'->'entryId' IS NULL OR jsonb_typeof(payload->'data'->'entryId') = 'null')
                )
                OR
                (
                    aggregate_version >= 2
                    AND payload->>'eventType' = 'LedgerEntryRecorded'
                    AND payload #>> '{data,kind}' = 'ledgerEntryRecorded'
                    AND (payload #>> '{data,status}') IN ('VALIDATED', 'RESERVED', 'CLEARED', 'SETTLED', 'RECONCILED', 'DISPUTED')
                    AND btrim(COALESCE(payload #>> '{data,entryId}', '')) <> ''
                )
            )
        ) IS TRUE
    )
);

CREATE TABLE IF NOT EXISTS clearledger.idempotency_keys (
    scope TEXT NOT NULL,
    idempotency_key TEXT NOT NULL,
    request_hash TEXT NOT NULL,
    status_code INTEGER NOT NULL,
    response_body JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (scope, idempotency_key),
    CONSTRAINT chk_idempotency_fields CHECK (
        (
            scope ~ '^(create|entry):[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
            AND request_hash ~ '^[0-9a-f]{64}$'
            AND char_length(btrim(idempotency_key)) BETWEEN 8 AND 128
            AND jsonb_typeof(response_body) = 'object'
            AND response_body->>'settlementId' = split_part(scope, ':', 2)
            AND (response_body->>'eventId') ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
            AND (response_body->>'version') ~ '^[0-9]+$'
            AND response_body->'accepted' = 'true'::jsonb
            AND response_body->'idempotentReplay' = 'false'::jsonb
        ) IS TRUE
    ),
    CONSTRAINT chk_idempotency_status_code CHECK (
        (
            (scope LIKE 'create:%' AND status_code = 201 AND (response_body->>'version')::integer = 1)
            OR
            (scope LIKE 'entry:%' AND status_code = 202 AND (response_body->>'version')::integer >= 2)
        ) IS TRUE
    )
);

CREATE OR REPLACE FUNCTION clearledger.fn_guard_idempotency_keys()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_ev_sid uuid;
    v_ev_ver integer;
    v_ev_idem text;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT settlement_id, aggregate_version, idempotency_key
          INTO v_ev_sid, v_ev_ver, v_ev_idem
          FROM clearledger.events
         WHERE event_id = (NEW.response_body->>'eventId')::uuid;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Idempotency eventId % not found in clearledger.events', NEW.response_body->>'eventId'
                USING ERRCODE = '23503';
        END IF;

        IF v_ev_sid <> (NEW.response_body->>'settlementId')::uuid
           OR v_ev_ver <> (NEW.response_body->>'version')::integer
           OR v_ev_idem <> NEW.idempotency_key THEN
            RAISE EXCEPTION 'Idempotency row does not match referenced clearledger.events row'
                USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
    END IF;

    RAISE EXCEPTION 'clearledger.idempotency_keys is an append-only ledger (% is forbidden)', TG_OP
        USING ERRCODE = '23514';
END;
$$;

DROP TRIGGER IF EXISTS trg_clearledger_idempotency_guard ON clearledger.idempotency_keys;
CREATE TRIGGER trg_clearledger_idempotency_guard
    BEFORE INSERT OR UPDATE OR DELETE ON clearledger.idempotency_keys
    FOR EACH ROW
    EXECUTE FUNCTION clearledger.fn_guard_idempotency_keys();

CREATE OR REPLACE FUNCTION clearledger.fn_status_rank(p_status text)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE p_status
        WHEN 'INITIATED' THEN 0
        WHEN 'VALIDATED' THEN 1
        WHEN 'RESERVED' THEN 2
        WHEN 'CLEARED' THEN 3
        WHEN 'SETTLED' THEN 4
        WHEN 'RECONCILED' THEN 5
        ELSE -1
    END;
$$;

CREATE OR REPLACE FUNCTION clearledger.fn_guard_settlements_update()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.settlement_id <> OLD.settlement_id
       OR NEW.account_id <> OLD.account_id
       OR NEW.reference <> OLD.reference
       OR NEW.debit_party <> OLD.debit_party
       OR NEW.credit_party <> OLD.credit_party
       OR NEW.created_at <> OLD.created_at THEN
        RAISE EXCEPTION 'Immutable settlement header attributes cannot be modified'
            USING ERRCODE = '23514';
    END IF;

    IF NEW.version <> OLD.version + 1 OR NEW.entry_count <> OLD.entry_count + 1 THEN
        RAISE EXCEPTION 'Settlement version and entry_count must increment by exactly 1'
            USING ERRCODE = '23514';
    END IF;

    IF OLD.current_status = 'RECONCILED' AND NEW.current_status <> 'RECONCILED' THEN
        RAISE EXCEPTION 'RECONCILED settlement is terminal and cannot transition to %', NEW.current_status
            USING ERRCODE = '23514';
    END IF;

    IF OLD.current_status = 'DISPUTED'
       AND NEW.current_status NOT IN ('DISPUTED', 'RECONCILED') THEN
        RAISE EXCEPTION 'DISPUTED settlement can only remain DISPUTED or resolve to RECONCILED, not %', NEW.current_status
            USING ERRCODE = '23514';
    END IF;

    IF OLD.current_status <> 'DISPUTED' AND NEW.current_status <> 'DISPUTED' THEN
        IF clearledger.fn_status_rank(NEW.current_status) < clearledger.fn_status_rank(OLD.current_status) THEN
            RAISE EXCEPTION 'Settlement cannot regress from % to %', OLD.current_status, NEW.current_status
                USING ERRCODE = '23514';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_clearledger_settlements_before_update ON clearledger.settlements;
CREATE TRIGGER trg_clearledger_settlements_before_update
    BEFORE UPDATE ON clearledger.settlements
    FOR EACH ROW
    EXECUTE FUNCTION clearledger.fn_guard_settlements_update();

CREATE OR REPLACE FUNCTION clearledger.fn_guard_events_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_max_ver integer;
    v_acct text;
    v_ref text;
    v_debit text;
    v_credit text;
    v_status text;
    v_stage text;
    v_last_entry uuid;
    v_last_memo text;
    v_parent_ver integer;
    v_dup_entry integer;
BEGIN
    SELECT COALESCE(MAX(aggregate_version), 0)
      INTO v_max_ver
      FROM clearledger.events
     WHERE settlement_id = NEW.settlement_id;

    IF NEW.aggregate_version <> v_max_ver + 1 THEN
        RAISE EXCEPTION 'Non-contiguous event aggregate_version % (expected %)', NEW.aggregate_version, v_max_ver + 1
            USING ERRCODE = '23514';
    END IF;

    SELECT account_id, reference, debit_party, credit_party, current_status, current_stage, last_entry_id, last_memo, version
      INTO v_acct, v_ref, v_debit, v_credit, v_status, v_stage, v_last_entry, v_last_memo, v_parent_ver
      FROM clearledger.settlements
     WHERE settlement_id = NEW.settlement_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Parent settlement % does not exist', NEW.settlement_id
            USING ERRCODE = '23503';
    END IF;

    IF v_parent_ver <> NEW.aggregate_version
       OR v_acct <> (NEW.payload #>> '{data,accountId}')
       OR v_status <> (NEW.payload #>> '{data,status}')
       OR v_stage <> (NEW.payload #>> '{data,clearingStage}')
       OR COALESCE(NEW.payload #>> '{data,reference}', v_ref) <> v_ref
       OR COALESCE(NEW.payload #>> '{data,debitParty}', v_debit) <> v_debit
       OR COALESCE(NEW.payload #>> '{data,creditParty}', v_credit) <> v_credit
       OR COALESCE(v_last_memo, '') <> COALESCE(NEW.payload #>> '{data,memo}', '') THEN
        RAISE EXCEPTION 'Event row does not match parent settlement state at version %', NEW.aggregate_version
            USING ERRCODE = '23514';
    END IF;

    IF NEW.aggregate_version >= 2 THEN
        IF v_last_entry IS NULL OR v_last_entry::text <> (NEW.payload #>> '{data,entryId}') THEN
            RAISE EXCEPTION 'LedgerEntryRecorded entryId does not match parent settlement last_entry_id'
                USING ERRCODE = '23514';
        END IF;

        SELECT COUNT(*)
          INTO v_dup_entry
          FROM clearledger.events
         WHERE settlement_id = NEW.settlement_id
           AND aggregate_version >= 2
           AND (payload #>> '{data,entryId}') = (NEW.payload #>> '{data,entryId}');

        IF v_dup_entry > 0 THEN
            RAISE EXCEPTION 'Duplicate entryId % for settlement %', NEW.payload #>> '{data,entryId}', NEW.settlement_id
                USING ERRCODE = '23514';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_clearledger_events_before_insert ON clearledger.events;
CREATE TRIGGER trg_clearledger_events_before_insert
    BEFORE INSERT ON clearledger.events
    FOR EACH ROW
    EXECUTE FUNCTION clearledger.fn_guard_events_insert();

CREATE OR REPLACE FUNCTION clearledger.fn_guard_events_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'clearledger.events is an append-only event log (% is forbidden)', TG_OP
        USING ERRCODE = '23514';
END;
$$;

DROP TRIGGER IF EXISTS trg_clearledger_events_immutable ON clearledger.events;
CREATE TRIGGER trg_clearledger_events_immutable
    BEFORE UPDATE OR DELETE ON clearledger.events
    FOR EACH ROW
    EXECUTE FUNCTION clearledger.fn_guard_events_immutable();

CREATE OR REPLACE FUNCTION clearledger.fn_guard_outbox_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_max_outbox_ver integer;
    v_ev_sid uuid;
    v_ev_ver integer;
    v_ev_corr text;
    v_ev_payload jsonb;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT COALESCE(MAX(aggregate_version), 0)
          INTO v_max_outbox_ver
          FROM clearledger.outbox
         WHERE settlement_id = NEW.settlement_id;

        IF NEW.aggregate_version <> v_max_outbox_ver + 1 THEN
            RAISE EXCEPTION 'Non-contiguous outbox aggregate_version % (expected %)', NEW.aggregate_version, v_max_outbox_ver + 1
                USING ERRCODE = '23514';
        END IF;

        SELECT settlement_id, aggregate_version, correlation_id, payload
          INTO v_ev_sid, v_ev_ver, v_ev_corr, v_ev_payload
          FROM clearledger.events
         WHERE event_id = NEW.event_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Outbox event_id % not found in clearledger.events', NEW.event_id
                USING ERRCODE = '23503';
        END IF;

        IF v_ev_sid <> NEW.settlement_id
           OR v_ev_ver <> NEW.aggregate_version
           OR v_ev_corr <> NEW.correlation_id
           OR v_ev_payload <> NEW.payload THEN
            RAISE EXCEPTION 'Outbox row does not match referenced clearledger.events row'
                USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
    END IF;

    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'clearledger.outbox rows cannot be deleted'
            USING ERRCODE = '23514';
    END IF;

    IF NEW.seq <> OLD.seq
       OR NEW.event_id <> OLD.event_id
       OR NEW.settlement_id <> OLD.settlement_id
       OR NEW.aggregate_version <> OLD.aggregate_version
       OR NEW.correlation_id <> OLD.correlation_id
       OR NEW.payload <> OLD.payload
       OR NEW.created_at <> OLD.created_at
       OR NEW.attempts < OLD.attempts THEN
        RAISE EXCEPTION 'clearledger.outbox envelope is immutable and attempts cannot decrease'
            USING ERRCODE = '23514';
    END IF;

    IF OLD.published_at IS NULL AND NEW.published_at IS NOT NULL THEN
        IF NEW.attempts < OLD.attempts + 1 OR NEW.archived_at IS NOT NULL THEN
            RAISE EXCEPTION 'Publishing an unpublished outbox row requires incrementing attempts and keeping archived_at NULL'
                USING ERRCODE = '23514';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_clearledger_outbox_guard ON clearledger.outbox;
CREATE TRIGGER trg_clearledger_outbox_guard
    BEFORE INSERT OR UPDATE OR DELETE ON clearledger.outbox
    FOR EACH ROW
    EXECUTE FUNCTION clearledger.fn_guard_outbox_mutation();

CREATE INDEX IF NOT EXISTS idx_clearledger_outbox_unpublished
    ON clearledger.outbox (seq)
    WHERE published_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_clearledger_outbox_unarchived
    ON clearledger.outbox (seq)
    WHERE published_at IS NOT NULL AND archived_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_clearledger_events_settlement_version
    ON clearledger.events (settlement_id, aggregate_version);
SQL

SERVICE_URL="$(jq -r '.service_url' "${MANIFEST_FILE}")"
READY_URL="${SERVICE_URL%/}/health/ready"

READY_OK=0
for attempt in $(seq 1 90); do
  if curl -fsS --max-time 5 "${READY_URL}" >/dev/null 2>&1; then
    READY_OK=1
    break
  fi
  if [[ "${attempt}" -eq 15 || "${attempt}" -eq 40 ]]; then
    /opt/venv/bin/python3 - <<'PY' || true
import json
import boto3

with open("/workspace/config/config.json", encoding="utf-8") as f:
    cfg = json.load(f)
with open("/workspace/submission/manifest.json", encoding="utf-8") as f:
    m = json.load(f)

kw = {
    "region_name": cfg["region"],
    "endpoint_url": cfg["aws_endpoint_url"],
    "aws_access_key_id": "test",
    "aws_secret_access_key": "test",
}
ecs = boto3.client("ecs", **kw)
elbv2 = boto3.client("elbv2", **kw)
cluster = m["compute"]["cluster_arn"]
service = m["compute"]["service_name"]
tg_arn = m["load_balancer"]["target_group_arn"]

task_arns = ecs.list_tasks(cluster=cluster, serviceName=service).get("taskArns", [])
running_ips = []
if task_arns:
    tasks = ecs.describe_tasks(cluster=cluster, tasks=task_arns).get("tasks", [])
    for t in tasks:
        if t.get("lastStatus") == "RUNNING":
            for att in t.get("attachments", []):
                for d in att.get("details", []):
                    if d.get("name") == "privateIPv4Address" and d.get("value"):
                        running_ips.append(d["value"])
            for c in t.get("containers", []):
                for ni in c.get("networkInterfaces", []):
                    if ni.get("privateIpv4Address"):
                        running_ips.append(ni["privateIpv4Address"])

if len(task_arns) < 2:
    ecs.update_service(cluster=cluster, service=service, desiredCount=2, forceNewDeployment=True)
elif running_ips:
    th = elbv2.describe_target_health(TargetGroupArn=tg_arn).get("TargetHealthDescriptions", [])
    reg_ips = {d.get("Target", {}).get("Id") for d in th}
    missing = [ip for ip in set(running_ips) if ip not in reg_ips]
    if missing:
        elbv2.register_targets(
            TargetGroupArn=tg_arn,
            Targets=[{"Id": ip, "Port": 8080} for ip in missing],
        )
PY
  fi
  sleep 2
done

if [[ "${READY_OK}" -ne 1 ]]; then
  echo "Service did not become ready at ${READY_URL}" >&2
  curl -i -sS --max-time 5 "${READY_URL}" >&2 || true
  exit 1
fi

/opt/venv/bin/python3 - <<'PY'
import hashlib
import json
import time
from urllib.parse import urlparse

import boto3
import psycopg
import redis

with open("/workspace/config/config.json", encoding="utf-8") as f:
    cfg = json.load(f)
with open("/workspace/submission/manifest.json", encoding="utf-8") as f:
    m = json.load(f)

endpoint_url = cfg["aws_endpoint_url"]
region = cfg["region"]
parsed_ep = urlparse(endpoint_url)
floci_host = parsed_ep.hostname or "aws"


def resolve_host(raw_host: str) -> str:
    h = raw_host.split(":")[0]
    if h in {"localhost", "127.0.0.1"} or h.endswith(".amazonaws.com") or h.endswith(".local"):
        return floci_host
    return h


boto_kwargs = {
    "region_name": region,
    "endpoint_url": endpoint_url,
    "aws_access_key_id": "test",
    "aws_secret_access_key": "test",
}
lam = boto3.client("lambda", **boto_kwargs)
ddb = boto3.client("dynamodb", **boto_kwargs)
s3 = boto3.client("s3", **boto_kwargs)

db = m["database"]
pg_conninfo = (
    f"host={resolve_host(str(db['endpoint']))} port={db['port']} "
    f"dbname={db['db_name']} user={db['username']} password={cfg['db_password']} connect_timeout=5"
)
rclient = redis.Redis(
    host=resolve_host(str(m["cache"]["endpoint"])),
    port=int(m["cache"]["port"]),
    decode_responses=True,
    socket_connect_timeout=5,
    socket_timeout=5,
)

relay_fn = m["workers"]["outbox_relay"]["function_name"]
projector_fn = m["workers"]["projector"]["function_name"]
archiver_fn = m["workers"]["audit_archiver"]["function_name"]
table_name = m["projections"]["table_name"]
audit_bucket = m["audit"]["bucket_name"]
audit_prefix = str(m["audit"]["prefix"])

with psycopg.connect(pg_conninfo) as conn:
    with conn.cursor() as cur:
        # 1. Drain unpublished outbox backlog via outbox_relay
        for _ in range(20):
            cur.execute("SELECT COUNT(*) FROM clearledger.outbox WHERE published_at IS NULL")
            unpub = cur.fetchone()[0]
            if unpub == 0:
                break
            lam.invoke(FunctionName=relay_fn, InvocationType="RequestResponse", Payload=b"{}")
            time.sleep(0.3)

        # 2. Load authoritative PostgreSQL settlements and events
        cur.execute(
            """
            SELECT settlement_id::text, account_id, reference, debit_party, credit_party,
                   current_status, current_stage, version, entry_count,
                   last_entry_id::text, last_memo
            FROM clearledger.settlements
            """
        )
        pg_settlements = {row[0]: row[1:] for row in cur.fetchall()}

        # 3. Purge orphan DynamoDB partitions and Valkey keys not present in PostgreSQL
        scan_kwargs = {"TableName": table_name, "ConsistentRead": True}
        while True:
            scan_resp = ddb.scan(**scan_kwargs)
            for item in scan_resp.get("Items", []):
                pk_val = (item.get("PK") or {}).get("S", "")
                sk_val = (item.get("SK") or {}).get("S", "")
                if pk_val.startswith("SETTLEMENT#"):
                    sid_candidate = pk_val.split("SETTLEMENT#", 1)[1]
                    if sid_candidate not in pg_settlements:
                        ddb.delete_item(
                            TableName=table_name,
                            Key={"PK": {"S": pk_val}, "SK": {"S": sk_val}},
                        )
            if "LastEvaluatedKey" not in scan_resp:
                break
            scan_kwargs["ExclusiveStartKey"] = scan_resp["LastEvaluatedKey"]

        for rkey in rclient.keys("clearledger:settlement:*"):
            sid_candidate = rkey.split("clearledger:settlement:", 1)[-1]
            if sid_candidate not in pg_settlements:
                rclient.delete(rkey)

        # 4. Reconcile each PostgreSQL settlement's DynamoDB STATE + EVENT#* items and Valkey cache
        for sid, (acct, ref, debit, credit, status, stage, pg_ver, pg_ec, pg_last_entry, pg_last_memo) in pg_settlements.items():
            pk = f"SETTLEMENT#{sid}"
            cur.execute(
                """
                SELECT aggregate_version, event_id::text, event_type, payload
                FROM clearledger.events
                WHERE settlement_id = %s
                ORDER BY aggregate_version ASC
                """,
                (sid,),
            )
            pg_events = cur.fetchall()

            expected_ddb_last_memo = pg_last_memo
            for _, _, _, ev_payload in pg_events:
                ev_obj = json.loads(ev_payload) if isinstance(ev_payload, str) else ev_payload
                ev_memo = (ev_obj.get("data") or {}).get("memo")
                if ev_memo is not None:
                    expected_ddb_last_memo = ev_memo

            q_items = ddb.query(
                TableName=table_name,
                ConsistentRead=True,
                KeyConditionExpression="PK = :pk",
                ExpressionAttributeValues={":pk": {"S": pk}},
            ).get("Items", [])

            state_item = None
            event_items_by_sk = {}
            for it in q_items:
                sk_val = (it.get("SK") or {}).get("S", "")
                if sk_val == "STATE":
                    state_item = it
                elif sk_val.startswith("EVENT#"):
                    event_items_by_sk[sk_val] = it

            state_ok = False
            if state_item is not None and len(q_items) == 1 + len(pg_events):
                try:
                    state_ok = (
                        (state_item.get("settlement_id") or {}).get("S") == sid
                        and int((state_item.get("version") or {}).get("N", -1)) == pg_ver
                        and int((state_item.get("entry_count") or {}).get("N", -1)) == pg_ec
                        and (state_item.get("status") or {}).get("S") == status
                        and (state_item.get("clearing_stage") or {}).get("S") == stage
                        and (state_item.get("account_id") or {}).get("S") == acct
                        and (state_item.get("reference") or {}).get("S") == ref
                        and (state_item.get("debit_party") or {}).get("S") == debit
                        and (state_item.get("credit_party") or {}).get("S") == credit
                        and (state_item.get("last_entry_id") or {}).get("S") == pg_last_entry
                        and (state_item.get("last_memo") or {}).get("S") == expected_ddb_last_memo
                        and (state_item.get("GSI1PK") or {}).get("S") == f"ACCOUNT#{acct}"
                        and (state_item.get("GSI1SK") or {}).get("S") == f"SETTLEMENT#{sid}"
                    )
                except Exception:
                    state_ok = False

            events_ok = len(event_items_by_sk) == len(pg_events) and len(q_items) == 1 + len(pg_events)
            if events_ok:
                for ev_ver, ev_id, ev_type, ev_payload in pg_events:
                    expected_sk = f"EVENT#{ev_ver:08d}"
                    ddb_ev = event_items_by_sk.get(expected_sk)
                    if ddb_ev is None:
                        events_ok = False
                        break
                    ev_obj = json.loads(ev_payload) if isinstance(ev_payload, str) else ev_payload
                    ev_data = ev_obj.get("data") or {}
                    ddb_env_raw = (ddb_ev.get("envelope") or {}).get("S")
                    ddb_env_ok = False
                    if ddb_env_raw:
                        try:
                            ddb_env_ok = json.loads(ddb_env_raw) == ev_obj
                        except Exception:
                            ddb_env_ok = False
                    if (
                        (ddb_ev.get("settlement_id") or {}).get("S") != sid
                        or int((ddb_ev.get("version") or {}).get("N", -1)) != ev_ver
                        or (ddb_ev.get("event_id") or {}).get("S") != ev_id
                        or (ddb_ev.get("event_type") or {}).get("S") != ev_type
                        or (ddb_ev.get("status") or {}).get("S") != ev_data.get("status")
                        or (ddb_ev.get("clearing_stage") or {}).get("S") != ev_data.get("clearingStage")
                        or (ddb_ev.get("entry_id") or {}).get("S") != ev_data.get("entryId")
                        or (ddb_ev.get("memo") or {}).get("S") != ev_data.get("memo")
                        or (ddb_ev.get("correlation_id") or {}).get("S") != ev_obj.get("correlationId")
                        or not ddb_env_ok
                    ):
                        events_ok = False
                        break

            if not (state_ok and events_ok):
                for it in q_items:
                    ddb.delete_item(
                        TableName=table_name,
                        Key={"PK": it["PK"], "SK": it["SK"]},
                    )
                records = []
                for idx, (_, _, _, ev_payload) in enumerate(pg_events, start=1):
                    body = ev_payload if isinstance(ev_payload, str) else json.dumps(ev_payload)
                    records.append({"messageId": f"reconcile-{sid}-{idx}", "body": body})
                if records:
                    lam.invoke(
                        FunctionName=projector_fn,
                        InvocationType="RequestResponse",
                        Payload=json.dumps({"Records": records}).encode("utf-8"),
                    )
                rclient.delete(f"clearledger:settlement:{sid}")
            else:
                rkey = f"clearledger:settlement:{sid}"
                cached_raw = rclient.get(rkey)
                if cached_raw:
                    try:
                        ttl_val = int(rclient.ttl(rkey))
                        cached_obj = json.loads(cached_raw)
                        if (
                            not (0 < ttl_val <= 90)
                            or cached_obj.get("settlementId") != sid
                            or int(cached_obj.get("version", -1)) != pg_ver
                            or int(cached_obj.get("entryCount", -1)) != pg_ec
                            or cached_obj.get("status") != status
                            or cached_obj.get("clearingStage") != stage
                            or cached_obj.get("accountId") != acct
                            or cached_obj.get("reference") != ref
                            or cached_obj.get("debitParty") != debit
                            or cached_obj.get("creditParty") != credit
                            or cached_obj.get("lastEntryId") != pg_last_entry
                            or cached_obj.get("lastMemo") != expected_ddb_last_memo
                        ):
                            rclient.delete(rkey)
                    except Exception:
                        rclient.delete(rkey)

        # 5. Reconcile S3 audit archive objects 1-to-1 against clearledger.outbox
        cur.execute("SELECT seq, event_id::text, archived_at, payload FROM clearledger.outbox ORDER BY seq ASC")
        pg_outbox = {}
        for seq, ev_id, arch_at, payload in cur.fetchall():
            pay_obj = json.loads(payload) if isinstance(payload, str) else payload
            pg_outbox[ev_id] = (seq, arch_at, pay_obj)

        all_s3_objs = s3.list_objects_v2(Bucket=audit_bucket).get("Contents", [])
        seen_s3_event_ids: set[str] = set()
        for obj in sorted(all_s3_objs, key=lambda o: o["Key"]):
            key = obj["Key"]
            if not key.startswith(audit_prefix):
                s3.delete_object(Bucket=audit_bucket, Key=key)
                continue
            try:
                raw_bytes = s3.get_object(Bucket=audit_bucket, Key=key)["Body"].read()
                raw_body = raw_bytes.decode("utf-8")
                lines = [ln for ln in raw_body.splitlines() if ln.strip()]
                if not lines:
                    raise ValueError("Empty S3 audit batch")
                batch_ids: list[str] = []
                batch_seqs: list[int] = []
                batch_seen: set[str] = set()
                for line in lines:
                    parsed_line = json.loads(line)
                    ev_id = str(parsed_line.get("eventId") or "")
                    if not ev_id or ev_id not in pg_outbox:
                        raise ValueError(f"Orphan eventId {ev_id} in S3 audit batch")
                    if ev_id in seen_s3_event_ids or ev_id in batch_seen:
                        raise ValueError(f"Duplicate eventId {ev_id} in S3 audit batch")
                    row_seq, arch_at, authoritative_payload = pg_outbox[ev_id]
                    if arch_at is None:
                        raise ValueError(f"Outbox row {ev_id} is marked unarchived in PostgreSQL")
                    if parsed_line != authoritative_payload:
                        raise ValueError(f"Tampered S3 audit record for {ev_id}")
                    batch_seen.add(ev_id)
                    batch_ids.append(ev_id)
                    batch_seqs.append(int(row_seq))
                if batch_seqs != sorted(batch_seqs):
                    raise ValueError("S3 audit batch records are not in ascending outbox.seq order")
                digest_hex = hashlib.sha256(raw_bytes).hexdigest()[:16]
                expected_key = (
                    f"{audit_prefix}batch-{batch_seqs[0]:08d}-{batch_seqs[-1]:08d}-{digest_hex}.ndjson"
                )
                if key != expected_key:
                    raise ValueError(f"S3 audit batch key {key} does not match canonical {expected_key}")
                seen_s3_event_ids.update(batch_ids)
            except Exception:
                s3.delete_object(Bucket=audit_bucket, Key=key)

        missing_seqs = [
            seq
            for ev_id, (seq, arch_at, _) in pg_outbox.items()
            if arch_at is not None and ev_id not in seen_s3_event_ids
        ]
        if missing_seqs:
            cur.execute(
                "UPDATE clearledger.outbox SET archived_at = NULL WHERE seq = ANY(%s)",
                (missing_seqs,),
            )
            conn.commit()

        for _ in range(20):
            cur.execute(
                "SELECT COUNT(*) FROM clearledger.outbox WHERE published_at IS NOT NULL AND archived_at IS NULL"
            )
            unarch = cur.fetchone()[0]
            if unarch == 0:
                break
            lam.invoke(FunctionName=archiver_fn, InvocationType="RequestResponse", Payload=b"{}")
            time.sleep(0.3)
PY

echo "ClearLedger deployment ready at ${SERVICE_URL}"
exit 0
