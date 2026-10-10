#!/usr/bin/env bash
# ClearLedger deployment / repair entrypoint.
#
#  1. strips out-of-band IAM drift from the six workload roles
#  2. terraform/tofu apply of ./infra (local state: infra/terraform.tfstate)
#  3. revokes out-of-band security-group egress drift
#  4. applies the idempotent clearledger PostgreSQL schema
#  5. writes manifest.json from the Terraform outputs
#  6. waits for GET <service_url>/health/ready == 200
#  7. converges the derived data stores (SQS/outbox, DynamoDB, Valkey, S3) with PostgreSQL
set -Eeuo pipefail

SUBMISSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${SUBMISSION_DIR}/infra"
CONFIG_FILE="${CLEARLEDGER_CONFIG:-/workspace/config/config.json}"
MANIFEST_FILE="${SUBMISSION_DIR}/manifest.json"
OPS="${INFRA_DIR}/scripts/clearledger_ops.py"
SCHEMA_SQL="${INFRA_DIR}/sql/schema.sql"
WORK_DIR="${INFRA_DIR}/.terraform/clearledger"

log() { printf '[deploy %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

[[ -f "${CONFIG_FILE}" ]] || die "config file ${CONFIG_FILE} not found"
command -v jq >/dev/null || die "jq is required"

cfg() { jq -r --arg k "$1" '.[$k] // empty' "${CONFIG_FILE}"; }

RESOURCE_PREFIX="$(cfg resource_prefix)"
REGION="$(cfg region)"; REGION="${REGION:-us-east-1}"
ENDPOINT="$(cfg aws_endpoint_url)"; ENDPOINT="${ENDPOINT:-http://aws:4566}"
DB_NAME="$(cfg db_name)"
DB_USER="$(cfg db_username)"
DB_PASSWORD="$(cfg db_password)"
[[ -n "${RESOURCE_PREFIX}" && -n "${DB_NAME}" && -n "${DB_USER}" && -n "${DB_PASSWORD}" ]] || die "incomplete config"

export AWS_REGION="${REGION}" AWS_DEFAULT_REGION="${REGION}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_ENDPOINT_URL="${ENDPOINT}" AWS_EC2_METADATA_DISABLED=true AWS_PAGER=""
export CLEARLEDGER_CONFIG="${CONFIG_FILE}" CLEARLEDGER_MANIFEST="${MANIFEST_FILE}"
export TF_IN_AUTOMATION=1 TF_INPUT=0
export NO_PROXY="${NO_PROXY:-},aws,localhost,127.0.0.1" no_proxy="${no_proxy:-},aws,localhost,127.0.0.1"

# --- tool discovery ---------------------------------------------------------
if command -v terraform >/dev/null 2>&1; then TF=terraform
elif command -v tofu >/dev/null 2>&1; then TF=tofu
else die "neither terraform nor tofu found"; fi

PY=""
for cand in /opt/venv/bin/python3 python3 /usr/bin/python3 python; do
  if command -v "${cand}" >/dev/null 2>&1 && "${cand}" -c 'import boto3' >/dev/null 2>&1; then PY="${cand}"; break; fi
done
[[ -n "${PY}" ]] || die "python3 with boto3 is required"

mkdir -p "${WORK_DIR}"
chmod 700 "${WORK_DIR}" || true
VARS_FILE="${WORK_DIR}/deploy.tfvars.json"
jq '{resource_prefix, region, aws_endpoint_url, db_name, db_username, db_password,
     api_image, projector_image, relay_image, archiver_image,
     api_image_id, projector_image_id, relay_image_id, archiver_image_id}
    | with_entries(select(.value != null))' "${CONFIG_FILE}" > "${VARS_FILE}"
chmod 600 "${VARS_FILE}" || true

tfq() { "${TF}" -chdir="${INFRA_DIR}" "$@"; }

# --- 1. terraform init ------------------------------------------------------
log "initialising ${TF} in ${INFRA_DIR} (prefix ${RESOURCE_PREFIX})"
for i in 1 2 3; do
  if tfq init -input=false -no-color >"${WORK_DIR}/init.log" 2>&1; then break; fi
  [[ $i -eq 3 ]] && { tail -n 30 "${WORK_DIR}/init.log"; die "terraform init failed"; }
  sleep 3
done

# --- 2. IAM drift (before apply so Terraform sees only canonical policies) ---
log "reconciling out-of-band IAM policy drift on workload roles"
"${PY}" "${OPS}" iam-drift || log "WARNING: IAM drift reconciliation reported errors"

# --- 3. terraform apply -----------------------------------------------------
APPLY_ARGS=(-auto-approve -input=false -no-color -var-file="${VARS_FILE}" -parallelism=20)
if [[ -f "${INFRA_DIR}/terraform.tfstate" ]]; then
  if [[ "$("${PY}" "${OPS}" esm-check "${INFRA_DIR}/terraform.tfstate" 2>/dev/null || true)" == *replace* ]]; then
    log "main queue was removed out-of-band; re-binding projector event source mapping"
    APPLY_ARGS+=(-replace=aws_lambda_event_source_mapping.projector)
  fi
fi

apply_ok=0
for i in 1 2 3; do
  log "${TF} apply (attempt ${i})"
  if tfq apply "${APPLY_ARGS[@]}" >"${WORK_DIR}/apply.log" 2>&1; then
    apply_ok=1
    grep -E '^(Apply complete|.*: (Creation|Modifications|Destruction) complete)' "${WORK_DIR}/apply.log" \
      | sed -E 's/\[id=[^]]*\]//' | tail -n 80 || true
    break
  fi
  log "apply attempt ${i} failed:"
  grep -E '^(Error|│ Error)|Error:' -A4 "${WORK_DIR}/apply.log" | grep -v -i -E 'password|secret' | head -n 40 || true
  sleep $((i * 5))
done
[[ ${apply_ok} -eq 1 ]] || die "terraform apply failed"

# --- 4. manifest ------------------------------------------------------------
log "writing ${MANIFEST_FILE}"
tfq output -json manifest > "${WORK_DIR}/manifest.json"
jq '.' "${WORK_DIR}/manifest.json" > "${MANIFEST_FILE}.tmp"
mv "${MANIFEST_FILE}.tmp" "${MANIFEST_FILE}"
"${PY}" - "${MANIFEST_FILE}" "${SUBMISSION_DIR}/../contracts/schemas/manifest.schema.json" /workspace/contracts/schemas/manifest.schema.json <<'PYEOF' || true
import json, os, sys
m = json.load(open(sys.argv[1]))
schema_path = next((p for p in sys.argv[2:] if os.path.exists(p)), None)
try:
    import jsonschema
except ImportError:
    jsonschema = None
if jsonschema and schema_path:
    jsonschema.validate(m, json.load(open(schema_path)))
    print("[deploy] manifest validated against manifest.schema.json")
PYEOF

SERVICE_URL="$(jq -r .service_url "${MANIFEST_FILE}")"
DB_HOST="$(jq -r .database.endpoint "${MANIFEST_FILE}")"
DB_PORT="$(jq -r .database.port "${MANIFEST_FILE}")"

# --- 5. security-group egress drift ----------------------------------------
log "reconciling security group egress drift"
"${PY}" "${OPS}" sg-drift || log "WARNING: security group drift reconciliation reported errors"

# --- 6. PostgreSQL schema ---------------------------------------------------
export PGPASSWORD="${DB_PASSWORD}" PGCONNECT_TIMEOUT=5
log "waiting for PostgreSQL at ${DB_HOST}:${DB_PORT}"
for i in $(seq 1 90); do
  if psql -X -q -At -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -c 'SELECT 1' >/dev/null 2>&1; then break; fi
  [[ $i -eq 90 ]] && die "PostgreSQL not reachable"
  sleep 2
done
log "applying clearledger schema, constraints, triggers and indexes"
for i in 1 2 3; do
  if psql -X -q -o /dev/null -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" \
       -v ON_ERROR_STOP=1 -c 'SET client_min_messages = warning' -f "${SCHEMA_SQL}" >"${WORK_DIR}/schema.log" 2>&1; then
    break
  fi
  [[ $i -eq 3 ]] && { cat "${WORK_DIR}/schema.log"; die "schema migration failed"; }
  sleep 3
done

# --- 7. wait for the API ----------------------------------------------------
wait_ready() {
  local deadline=$(( $(date +%s) + $1 ))
  while (( $(date +%s) < deadline )); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${SERVICE_URL}/health/ready" || true)"
    [[ "${code}" == "200" ]] && return 0
    sleep 3
  done
  return 1
}
log "waiting for ${SERVICE_URL}/health/ready"
if ! wait_ready 150; then
  log "API not ready yet; forcing a new ECS deployment"
  CLUSTER="$(jq -r .compute.cluster_name "${MANIFEST_FILE}")"
  SERVICE="$(jq -r .compute.service_name "${MANIFEST_FILE}")"
  aws --endpoint-url "${ENDPOINT}" ecs update-service --cluster "${CLUSTER}" --service "${SERVICE}" \
      --force-new-deployment >/dev/null 2>&1 || true
  wait_ready 200 || die "API never became ready"
fi
log "API ready"

# --- 8. data-plane convergence ---------------------------------------------
log "converging derived data stores with PostgreSQL"
"${PY}" "${OPS}" reconcile

wait_ready 60 || die "API not ready after reconciliation"
log "deployment complete: ${SERVICE_URL}"
exit 0
