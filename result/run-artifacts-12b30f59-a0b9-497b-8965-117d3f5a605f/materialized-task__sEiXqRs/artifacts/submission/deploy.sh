#!/usr/bin/env bash
# ClearLedger deploy: provision/repair infrastructure, converge PostgreSQL schema,
# export manifest.json, wait for readiness and converge derived data stores.
set -Eeuo pipefail

SUBMISSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${SUBMISSION_DIR}/infra"
CONFIG_FILE="${CLEARLEDGER_CONFIG:-/workspace/config/config.json}"
MANIFEST_FILE="${SUBMISSION_DIR}/manifest.json"
SCHEMA_FILE="${SUBMISSION_DIR}/sql/schema.sql"
RECONCILE="${SUBMISSION_DIR}/scripts/reconcile.py"
SCHEMA_JSON="${CLEARLEDGER_MANIFEST_SCHEMA:-/workspace/contracts/schemas/manifest.schema.json}"
START_TS=$(date +%s)

log() { printf '[deploy %4ss] %s\n' "$(( $(date +%s) - START_TS ))" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/clearledger-deploy.XXXXXX")"
chmod 700 "${WORK_DIR}"
trap 'rm -rf "${WORK_DIR}"' EXIT

[[ -f "${CONFIG_FILE}" ]] || die "config not found: ${CONFIG_FILE}"
command -v jq >/dev/null || die "jq is required"

# ---------------------------------------------------------------------------
# Inputs (read dynamically from config.json)
# ---------------------------------------------------------------------------
cfg() { jq -er --arg k "$1" '.[$k] // empty' "${CONFIG_FILE}"; }

RESOURCE_PREFIX="$(cfg resource_prefix)"
REGION="$(cfg region)"
AWS_ENDPOINT="$(cfg aws_endpoint_url)"

export TF_VAR_resource_prefix="${RESOURCE_PREFIX}"
export TF_VAR_region="${REGION}"
export TF_VAR_aws_endpoint_url="${AWS_ENDPOINT}"
export TF_VAR_db_name="$(cfg db_name)"
export TF_VAR_db_username="$(cfg db_username)"
export TF_VAR_db_password="$(cfg db_password)"
for img in api projector relay archiver; do
  export "TF_VAR_${img}_image=$(cfg "${img}_image")"
  export "TF_VAR_${img}_image_id=$(jq -r --arg k "${img}_image_id" '.[$k] // ""' "${CONFIG_FILE}")"
done

export AWS_ENDPOINT_URL="${AWS_ENDPOINT}"
export AWS_REGION="${REGION}" AWS_DEFAULT_REGION="${REGION}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_EC2_METADATA_DISABLED=true
export TF_IN_AUTOMATION=1 TF_INPUT=0
# Never route emulator traffic through an HTTP proxy.
EP_HOST="$(sed -E 's#^[a-z]+://([^:/]+).*#\1#' <<<"${AWS_ENDPOINT}")"
export NO_PROXY="${NO_PROXY:-},${EP_HOST}" no_proxy="${no_proxy:-},${EP_HOST}"

if command -v terraform >/dev/null 2>&1; then TF=terraform
elif command -v tofu >/dev/null 2>&1; then TF=tofu
else die "neither terraform nor tofu found"; fi

log "deploying resource_prefix=${RESOURCE_PREFIX} region=${REGION} endpoint=${AWS_ENDPOINT} (${TF})"

# ---------------------------------------------------------------------------
# 1. Terraform / OpenTofu: init + apply (repairs drift, recreates deleted resources)
# ---------------------------------------------------------------------------
cd "${INFRA_DIR}"

tf_filter() { grep -vE 'Still (creating|destroying|modifying)|Refreshing state|Reading\.\.\.|Read complete' || true; }

log "${TF} init"
"${TF}" init -input=false -no-color >"${WORK_DIR}/init.log" 2>&1 || { tail -n 40 "${WORK_DIR}/init.log" >&2; die "${TF} init failed"; }

apply_ok=0
for attempt in 1 2 3; do
  log "${TF} apply (attempt ${attempt})"
  if "${TF}" apply -auto-approve -input=false -no-color -compact-warnings -parallelism=20 >"${WORK_DIR}/apply.log" 2>&1; then
    apply_ok=1
    grep -E '^(Apply complete|Plan:)' "${WORK_DIR}/apply.log" >&2 || true
    break
  fi
  tf_filter <"${WORK_DIR}/apply.log" | tail -n 40 >&2
  sleep $(( attempt * 5 ))
done
[[ "${apply_ok}" == 1 ]] || die "${TF} apply failed"

"${TF}" output -json manifest >"${WORK_DIR}/manifest.json"
"${TF}" output -json canonical_policies >"${WORK_DIR}/policies.json"

# ---------------------------------------------------------------------------
# 2. manifest.json (validated against the contract schema)
# ---------------------------------------------------------------------------
python3 - "${WORK_DIR}/manifest.json" "${MANIFEST_FILE}" "${SCHEMA_JSON}" <<'PY'
import json, os, sys
src, dst, schema_path = sys.argv[1:4]
manifest = json.load(open(src))
if os.path.exists(schema_path):
    try:
        import jsonschema
        jsonschema.validate(manifest, json.load(open(schema_path)))
    except ImportError:
        pass
tmp = dst + '.tmp'
with open(tmp, 'w') as fh:
    json.dump(manifest, fh, indent=2, sort_keys=False)
    fh.write('\n')
os.replace(tmp, dst)
PY
chmod 600 "${MANIFEST_FILE}" 2>/dev/null || true
log "manifest written: ${MANIFEST_FILE}"

SERVICE_URL="$(jq -r .service_url "${MANIFEST_FILE}")"
DB_HOST="$(jq -r .database.endpoint "${MANIFEST_FILE}")"
DB_PORT="$(jq -r .database.port "${MANIFEST_FILE}")"
DB_NAME="$(jq -r .database.db_name "${MANIFEST_FILE}")"
DB_USER="$(jq -r .database.username "${MANIFEST_FILE}")"

jq -n --arg pw "${TF_VAR_db_password}" --slurpfile pol "${WORK_DIR}/policies.json" \
  '{db_password: $pw, canonical_policies: $pol[0]}' >"${WORK_DIR}/extra.json"

# ---------------------------------------------------------------------------
# 3. PostgreSQL schema / constraints / triggers / indexes
# ---------------------------------------------------------------------------
export PGPASSWORD="${TF_VAR_db_password}" PGCONNECT_TIMEOUT=10
PG_CONN="host=${DB_HOST} port=${DB_PORT} dbname=${DB_NAME} user=${DB_USER} application_name=clearledger-deploy"

log "waiting for PostgreSQL at ${DB_HOST}:${DB_PORT}"
for i in $(seq 1 60); do
  psql "${PG_CONN}" -Atqc 'SELECT 1' >/dev/null 2>&1 && break
  [[ $i == 60 ]] && die "PostgreSQL not reachable"
  sleep 3
done

schema_ok=0
for attempt in 1 2 3 4 5 6; do
  if PGOPTIONS='-c lock_timeout=8000 -c statement_timeout=120000' \
       psql "${PG_CONN}" -X -q -v ON_ERROR_STOP=1 --single-transaction -o /dev/null \
       -f "${SCHEMA_FILE}" 2>"${WORK_DIR}/schema.err"; then
    schema_ok=1; break
  fi
  log "schema apply attempt ${attempt} failed: $(tail -n 3 "${WORK_DIR}/schema.err" | tr '\n' ' ')"
  sleep $(( attempt * 2 ))
done
[[ "${schema_ok}" == 1 ]] || die "schema apply failed"
log "clearledger schema converged"

# ---------------------------------------------------------------------------
# 4. Control-plane safety net (IAM policy drift, security-group drift)
# ---------------------------------------------------------------------------
python3 "${RECONCILE}" "${MANIFEST_FILE}" "${WORK_DIR}/extra.json" iam,sg

# ---------------------------------------------------------------------------
# 5. Wait for the API behind the ALB
# ---------------------------------------------------------------------------
log "waiting for ${SERVICE_URL}/health/ready"
ready=0
for i in $(seq 1 120); do
  code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "${SERVICE_URL}/health/ready" || true)"
  if [[ "${code}" == 200 ]]; then ready=1; break; fi
  (( i % 10 == 0 )) && log "  /health/ready -> ${code}"
  sleep 3
done
[[ "${ready}" == 1 ]] || die "API did not become ready"
log "API ready"

# ---------------------------------------------------------------------------
# 6. Data-plane convergence against PostgreSQL (outbox, DynamoDB, S3, Valkey)
# ---------------------------------------------------------------------------
python3 "${RECONCILE}" "${MANIFEST_FILE}" "${WORK_DIR}/extra.json" data

code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "${SERVICE_URL}/health/ready" || true)"
[[ "${code}" == 200 ]] || log "warning: final readiness probe returned ${code}"

log "deploy complete: ${SERVICE_URL}"
exit 0
