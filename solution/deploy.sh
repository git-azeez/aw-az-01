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
    CONSTRAINT chk_settlements_distinct_parties CHECK (debit_party <> credit_party),
    CONSTRAINT chk_settlements_version_positive CHECK (version >= 1),
    CONSTRAINT chk_settlements_entry_count_version CHECK (entry_count >= 0 AND entry_count = version - 1),
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
    CONSTRAINT chk_events_version_positive CHECK (aggregate_version >= 1),
    CONSTRAINT chk_events_type_enum CHECK (
        event_type IN ('SettlementInitiated', 'LedgerEntryRecorded')
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
    CONSTRAINT chk_outbox_version_positive CHECK (aggregate_version >= 1),
    CONSTRAINT chk_outbox_attempts_nonnegative CHECK (attempts >= 0)
);

CREATE TABLE IF NOT EXISTS clearledger.idempotency_keys (
    scope TEXT NOT NULL,
    idempotency_key TEXT NOT NULL,
    request_hash TEXT NOT NULL,
    status_code INTEGER NOT NULL,
    response_body JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (scope, idempotency_key),
    CONSTRAINT chk_idempotency_status_code CHECK (status_code >= 100 AND status_code <= 599)
);

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
for _ in $(seq 1 90); do
  if curl -fsS --max-time 5 "${READY_URL}" >/dev/null 2>&1; then
    READY_OK=1
    break
  fi
  sleep 2
done

if [[ "${READY_OK}" -ne 1 ]]; then
  echo "Service did not become ready at ${READY_URL}" >&2
  exit 1
fi

/opt/venv/bin/python3 - <<'PY'
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


lam = boto3.client(
    "lambda",
    region_name=region,
    endpoint_url=endpoint_url,
    aws_access_key_id="test",
    aws_secret_access_key="test",
)
ddb = boto3.client(
    "dynamodb",
    region_name=region,
    endpoint_url=endpoint_url,
    aws_access_key_id="test",
    aws_secret_access_key="test",
)

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

        # 2. Reconcile DynamoDB projections and Valkey cache against PostgreSQL source of truth
        cur.execute("SELECT settlement_id::text, version FROM clearledger.settlements")
        settlements = cur.fetchall()
        for sid, pg_ver in settlements:
            pk = f"SETTLEMENT#{sid}"
            item = ddb.get_item(
                TableName=table_name,
                Key={"PK": {"S": pk}, "SK": {"S": "STATE"}},
                ConsistentRead=True,
            ).get("Item")
            ddb_ver = int(item["version"]["N"]) if item and "version" in item else 0
            if ddb_ver < pg_ver:
                cur.execute(
                    "SELECT payload FROM clearledger.events WHERE settlement_id = %s ORDER BY aggregate_version ASC",
                    (sid,),
                )
                records = []
                for idx, (payload,) in enumerate(cur.fetchall(), start=1):
                    body = payload if isinstance(payload, str) else json.dumps(payload)
                    records.append({"messageId": f"reconcile-{sid}-{idx}", "body": body})
                if records:
                    lam.invoke(
                        FunctionName=projector_fn,
                        InvocationType="RequestResponse",
                        Payload=json.dumps({"Records": records}).encode("utf-8"),
                    )
                rclient.delete(f"clearledger:settlement:{sid}")
            else:
                cached_raw = rclient.get(f"clearledger:settlement:{sid}")
                if cached_raw:
                    try:
                        cached_obj = json.loads(cached_raw)
                        if int(cached_obj.get("version", 0)) != pg_ver:
                            rclient.delete(f"clearledger:settlement:{sid}")
                    except Exception:
                        rclient.delete(f"clearledger:settlement:{sid}")

        # 3. Drain unarchived outbox rows via audit_archiver
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
