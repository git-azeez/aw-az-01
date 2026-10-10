#!/usr/bin/env bash
# ClearLedger deployment: Terraform/OpenTofu apply + PostgreSQL schema + data-plane convergence.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${CLEARLEDGER_CONFIG:-/workspace/config/config.json}"
INFRA="${HERE}/infra"
MANIFEST="${HERE}/manifest.json"
SCHEMA_SQL="${HERE}/schema.sql"
OPS="${HERE}/clearledger_ops.py"
SCHEMA_JSON="${CLEARLEDGER_MANIFEST_SCHEMA:-/workspace/contracts/schemas/manifest.schema.json}"

START_TS=$(date +%s)
WORK="$(mktemp -d /tmp/clearledger-deploy.XXXXXX)"
chmod 700 "${WORK}"
trap 'rm -rf "${WORK}"' EXIT

log() { printf '[deploy %4ss] %s\n' "$(( $(date +%s) - START_TS ))" "$*"; }

[ -f "${CONFIG}" ] || { echo "config not found: ${CONFIG}" >&2; exit 1; }

PREFIX="$(jq -r '.resource_prefix' "${CONFIG}")"
REGION="$(jq -r '.region' "${CONFIG}")"
ENDPOINT="$(jq -r '.aws_endpoint_url' "${CONFIG}")"
DB_PASSWORD="$(jq -r '.db_password' "${CONFIG}")"

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_REGION="${REGION}" AWS_DEFAULT_REGION="${REGION}"
export AWS_ENDPOINT_URL="${ENDPOINT}"
export AWS_PAGER=""
export TF_IN_AUTOMATION=1 TF_INPUT=0
export PYTHONUNBUFFERED=1

if command -v terraform >/dev/null 2>&1; then TF=terraform; else TF=tofu; fi

# Secrets never reach stdout/stderr.
SED_PW="$(printf '%s' "${DB_PASSWORD}" | sed -e 's/[]\/$*.^&[]/\\&/g')"
redact() { sed -u -e "s/${SED_PW}/********/g"; }

log "ClearLedger deploy for prefix=${PREFIX} region=${REGION} endpoint=${ENDPOINT} (${TF})"

# ---------------------------------------------------------------------------
# 1. Terraform / OpenTofu inputs (read dynamically from config.json)
# ---------------------------------------------------------------------------
jq '{resource_prefix, region, aws_endpoint_url, db_name, db_username, db_password,
     api_image, projector_image, relay_image, archiver_image,
     api_image_id: (.api_image_id // ""), projector_image_id: (.projector_image_id // ""),
     relay_image_id: (.relay_image_id // ""), archiver_image_id: (.archiver_image_id // "")}' \
  "${CONFIG}" > "${WORK}/clearledger.auto.tfvars.json"

# ---------------------------------------------------------------------------
# 2. Control-plane preflight repairs Terraform cannot perform by itself
#    (KMS keys scheduled for deletion / disabled out-of-band).
# ---------------------------------------------------------------------------
log "preflight: KMS key state"
python3 "${OPS}" preflight "${CONFIG}" 2>&1 | redact || log "preflight reported a problem (continuing)"

# ---------------------------------------------------------------------------
# 3. Apply infrastructure (local state in infra/terraform.tfstate)
# ---------------------------------------------------------------------------
log "terraform init"
"${TF}" -chdir="${INFRA}" init -input=false -no-color >"${WORK}/init.log" 2>&1 || {
  redact <"${WORK}/init.log"; exit 1; }

tf_apply() {
  local n=$1
  log "terraform apply (pass ${n})"
  if "${TF}" -chdir="${INFRA}" apply -auto-approve -input=false -no-color -compact-warnings \
       -parallelism=20 -var-file="${WORK}/clearledger.auto.tfvars.json" >"${WORK}/apply.log" 2>&1; then
    grep -E '^(Apply complete|.*: (Creating|Modifying|Destroying)\.\.\.|.*: (Creation|Modifications|Destruction) complete)' \
      "${WORK}/apply.log" | redact | tail -n 80 || true
    return 0
  fi
  grep -vE 'Still (creating|modifying|destroying)|Refreshing state|Reading\.\.\.|Read complete' "${WORK}/apply.log" \
    | redact | tail -n 60
  return 1
}

ok=0
for attempt in 1 2 3 4; do
  if tf_apply "${attempt}"; then ok=1; break; fi
  log "apply attempt ${attempt} failed; retrying"
  python3 "${OPS}" preflight "${CONFIG}" 2>&1 | redact || true
  sleep 5
done
[ "${ok}" = 1 ] || { log "terraform apply failed"; exit 1; }

# A second converging pass catches attributes the emulator settles asynchronously
# (e.g. default security-group egress, cache security groups).
tf_apply "converge" || tf_apply "converge-retry" || { log "terraform converge apply failed"; exit 1; }

"${TF}" -chdir="${INFRA}" output -json manifest >"${WORK}/out.json"

write_manifest() {
  jq '.' "${WORK}/out.json" >"${MANIFEST}.tmp"
  mv "${MANIFEST}.tmp" "${MANIFEST}"
  chmod 600 "${MANIFEST}" || true
  if [ -f "${SCHEMA_JSON}" ]; then
    python3 - "${MANIFEST}" "${SCHEMA_JSON}" <<'PY' || log "WARNING: manifest schema validation failed"
import json, sys
try:
    import jsonschema
except ImportError:
    sys.exit(0)
jsonschema.validate(json.load(open(sys.argv[1])), json.load(open(sys.argv[2])))
PY
  fi
}
write_manifest
log "manifest written to ${MANIFEST}"

SERVICE_URL="$(jq -r '.service_url' "${WORK}/out.json")"
DB_HOST="$(jq -r '.database.endpoint' "${WORK}/out.json")"
DB_PORT="$(jq -r '.database.port' "${WORK}/out.json")"
DB_NAME="$(jq -r '.db_name' "${CONFIG}")"
DB_USER="$(jq -r '.db_username' "${CONFIG}")"

# ---------------------------------------------------------------------------
# 4. IAM: remove out-of-band inline / managed policies
# ---------------------------------------------------------------------------
log "iam: enforcing canonical role policies"
python3 "${OPS}" iam "${CONFIG}" "${WORK}/out.json" 2>&1 | redact || log "iam cleanup reported a problem (continuing)"

# ---------------------------------------------------------------------------
# 5. PostgreSQL schema, constraints, triggers, indexes (idempotent)
# ---------------------------------------------------------------------------
log "postgres: waiting for ${DB_HOST}:${DB_PORT}"
python3 "${OPS}" schema-wait "${CONFIG}" "${WORK}/out.json" 2>&1 | redact

export PGPASSWORD="${DB_PASSWORD}" PGCONNECT_TIMEOUT=10
schema_ok=0
for attempt in 1 2 3 4 5; do
  log "postgres: applying clearledger schema (attempt ${attempt})"
  if psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -X -q \
       -v ON_ERROR_STOP=1 --single-transaction -f "${SCHEMA_SQL}" 2>&1 | redact; then
    schema_ok=1; break
  fi
  sleep 5
done
[ "${schema_ok}" = 1 ] || { log "schema application failed"; exit 1; }

# ---------------------------------------------------------------------------
# 6. Wait for the API to report ready through the load balancer
# ---------------------------------------------------------------------------
wait_ready() {
  local deadline=$(( $(date +%s) + $1 )) code
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "${SERVICE_URL}/health/ready" || true)"
    if [ "${code}" = "200" ]; then return 0; fi
    sleep 3
  done
  return 1
}
log "waiting for ${SERVICE_URL}/health/ready"
wait_ready 300 || { log "API did not become ready"; curl -s -m 5 "${SERVICE_URL}/health/ready" || true; exit 1; }
log "API ready"

# ---------------------------------------------------------------------------
# 7. Data-plane convergence: outbox -> SQS -> DynamoDB, S3 archive, Valkey
# ---------------------------------------------------------------------------
log "reconciling derived stores against PostgreSQL"
python3 "${OPS}" reconcile "${CONFIG}" "${WORK}/out.json" 2>&1 | redact || { log "reconciliation failed"; exit 1; }

write_manifest
wait_ready 120 || { log "API not ready after reconciliation"; exit 1; }
log "deploy complete: ${SERVICE_URL}"
