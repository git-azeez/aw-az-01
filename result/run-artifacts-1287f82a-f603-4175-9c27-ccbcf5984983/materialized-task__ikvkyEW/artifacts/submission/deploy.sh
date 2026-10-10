#!/usr/bin/env bash
# ClearLedger deploy / repair / re-apply.
#
#   1. terraform/tofu apply of ./infra (local state in infra/terraform.tfstate)
#   2. idempotent PostgreSQL schema (tables, constraints, triggers, indexes)
#   3. manifest.json export from Terraform outputs
#   4. wait for GET <service_url>/health/ready == 200
#   5. data-plane convergence (outbox drain, DynamoDB, Valkey, S3 archive)
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA="${HERE}/infra"
MANIFEST="${HERE}/manifest.json"
CONFIG="${CLEARLEDGER_CONFIG:-/workspace/config/config.json}"
START_TS=$(date +%s)

log() { printf '[deploy %4ss] %s\n' "$(( $(date +%s) - START_TS ))" "$*"; }
die() { log "ERROR: $*"; exit 1; }
trap 'log "failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

[[ -f "${CONFIG}" ]] || die "config not found: ${CONFIG}"
command -v jq >/dev/null || die "jq is required"
command -v psql >/dev/null || die "psql is required"

if command -v terraform >/dev/null 2>&1; then TF=terraform
elif command -v tofu >/dev/null 2>&1; then TF=tofu
else die "neither terraform nor tofu found"; fi

if [[ -z "${TF_CLI_CONFIG_FILE:-}" && -f /etc/terraform.tfrc ]]; then
  export TF_CLI_CONFIG_FILE=/etc/terraform.tfrc
fi
export TF_IN_AUTOMATION=1 TF_INPUT=0 CHECKPOINT_DISABLE=1

cfg() { jq -er --arg k "$1" '.[$k]' "${CONFIG}"; }

PREFIX="$(cfg resource_prefix)"
REGION="$(cfg region)"
ENDPOINT="$(cfg aws_endpoint_url)"
DB_NAME="$(cfg db_name)"
DB_USER="$(cfg db_username)"
DB_PASS="$(cfg db_password)"

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_REGION="${REGION}" AWS_DEFAULT_REGION="${REGION}" AWS_ENDPOINT_URL="${ENDPOINT}"
export AWS_EC2_METADATA_DISABLED=true AWS_PAGER=""

for k in resource_prefix region aws_endpoint_url db_name db_username db_password \
         api_image projector_image relay_image archiver_image \
         api_image_id projector_image_id relay_image_id archiver_image_id; do
  v="$(jq -r --arg k "$k" '.[$k] // empty' "${CONFIG}")"
  export "TF_VAR_${k}=${v}"
done

log "deploying ClearLedger prefix=${PREFIX} region=${REGION} endpoint=${ENDPOINT} using ${TF}"

# ---------------------------------------------------------------- apply ----
cd "${INFRA}"
tf_init() {
  "${TF}" init -input=false -no-color -upgrade=false >/tmp/clearledger-tf-init.log 2>&1 \
    || { cat /tmp/clearledger-tf-init.log; return 1; }
}
tf_init || { sleep 3; tf_init; } || die "${TF} init failed"

apply_ok=0
for attempt in 1 2 3; do
  log "${TF} apply (attempt ${attempt})"
  rc=0
  "${TF}" apply -auto-approve -input=false -no-color -compact-warnings \
    >/tmp/clearledger-tf-apply.log 2>&1 || rc=$?
  grep -E '^(  # |Apply complete|Plan:|Error|│)' /tmp/clearledger-tf-apply.log | head -c 200000 || true
  if [[ ${rc} -eq 0 ]]; then apply_ok=1; break; fi
  log "apply attempt ${attempt} failed (rc=${rc}); retrying"
  sleep $(( attempt * 5 ))
done
[[ ${apply_ok} -eq 1 ]] || die "${TF} apply failed"

write_manifest() {
  local tmp
  tmp="$(mktemp)"
  "${TF}" output -json manifest | jq -S '.' >"${tmp}"
  jq -e '.service_url and .database.endpoint' "${tmp}" >/dev/null || die "manifest output incomplete"
  mv "${tmp}" "${MANIFEST}"
  chmod 0644 "${MANIFEST}"
}
write_manifest
log "manifest written to ${MANIFEST}"

if python3 -c 'import jsonschema' 2>/dev/null && [[ -f "${HERE}/../contracts/schemas/manifest.schema.json" ]]; then
  python3 - "${MANIFEST}" "${HERE}/../contracts/schemas/manifest.schema.json" <<'PY' || die "manifest does not match schema"
import json, sys, jsonschema
jsonschema.validate(json.load(open(sys.argv[1])), json.load(open(sys.argv[2])))
PY
  log "manifest validated against manifest.schema.json"
fi

DB_HOST="$(jq -r .database.endpoint "${MANIFEST}")"
DB_PORT="$(jq -r .database.port "${MANIFEST}")"
SERVICE_URL="$(jq -r .service_url "${MANIFEST}")"
export PGPASSWORD="${DB_PASS}" PGCONNECT_TIMEOUT=5 PGTZ=UTC

# --------------------------------------------------------------- schema ----
log "waiting for PostgreSQL at ${DB_HOST}:${DB_PORT}"
for i in $(seq 1 90); do
  if psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -X -qAt -c 'SELECT 1' >/dev/null 2>&1; then
    break
  fi
  [[ $i -eq 90 ]] && die "PostgreSQL did not become reachable"
  sleep 2
done

log "applying clearledger schema"
schema_ok=0
for attempt in 1 2 3; do
  if psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -X -q \
       -v ON_ERROR_STOP=1 -o /dev/null -f "${INFRA}/schema.sql"; then
    schema_ok=1; break
  fi
  sleep 3
done
[[ ${schema_ok} -eq 1 ]] || die "schema migration failed"

# --------------------------------------------------------------- health ----
wait_ready() {
  local deadline=$(( $(date +%s) + $1 )) code
  while :; do
    code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "${SERVICE_URL}/health/ready" || true)"
    [[ "${code}" == "200" ]] && return 0
    [[ $(date +%s) -ge ${deadline} ]] && { log "last /health/ready status: ${code}"; return 1; }
    sleep 3
  done
}
log "waiting for ${SERVICE_URL}/health/ready"
wait_ready 300 || die "API never became ready"
log "API is ready"

# ------------------------------------------------- data-plane convergence ----
log "converging data plane against PostgreSQL"
python3 "${INFRA}/reconcile.py" "${MANIFEST}" "${CONFIG}" || {
  log "convergence failed once; retrying"
  sleep 5
  python3 "${INFRA}/reconcile.py" "${MANIFEST}" "${CONFIG}"
} || die "data-plane convergence failed"

write_manifest
wait_ready 120 || die "API not ready after convergence"
log "ClearLedger deployed: ${SERVICE_URL}"
