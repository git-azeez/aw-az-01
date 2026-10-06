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
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
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
    UNIQUE (settlement_id, aggregate_version)
);

CREATE TABLE IF NOT EXISTS clearledger.outbox (
    seq BIGSERIAL PRIMARY KEY,
    event_id UUID NOT NULL UNIQUE,
    settlement_id UUID NOT NULL,
    aggregate_version INTEGER NOT NULL,
    correlation_id TEXT NOT NULL,
    payload JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    published_at TIMESTAMPTZ NULL,
    archived_at TIMESTAMPTZ NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    last_error TEXT NULL
);

CREATE TABLE IF NOT EXISTS clearledger.idempotency_keys (
    scope TEXT NOT NULL,
    idempotency_key TEXT NOT NULL,
    request_hash TEXT NOT NULL,
    status_code INTEGER NOT NULL,
    response_body JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (scope, idempotency_key)
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

for _ in $(seq 1 90); do
  if curl -fsS --max-time 5 "${READY_URL}" >/dev/null 2>&1; then
    echo "ClearLedger deployment ready at ${SERVICE_URL}"
    exit 0
  fi
  sleep 2
done

echo "Service did not become ready at ${READY_URL}" >&2
exit 1
