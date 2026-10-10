#!/usr/bin/env bash
# ClearLedger deployment: provision / repair infrastructure, migrate the
# PostgreSQL schema, export manifest.json and converge derived data stores.
set -Eeuo pipefail

SUBMISSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${SUBMISSION_DIR}/infra"
CONFIG_FILE="${CLEARLEDGER_CONFIG:-/workspace/config/config.json}"
MANIFEST_FILE="${SUBMISSION_DIR}/manifest.json"
SCHEMA_FILE="${INFRA_DIR}/sql/schema.sql"
OPS="${INFRA_DIR}/scripts/clearledger_ops.py"
STATE_FILE="${INFRA_DIR}/terraform.tfstate"

log() { printf '[deploy %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*"; exit 1; }
trap 'log "failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

[[ -f "${CONFIG_FILE}" ]] || die "config file ${CONFIG_FILE} not found"
for bin in jq psql curl; do command -v "${bin}" >/dev/null || die "${bin} is required"; done

cfg() { jq -er --arg k "$1" '.[$k]' "${CONFIG_FILE}"; }
PREFIX="$(cfg resource_prefix)"
REGION="$(cfg region)"
ENDPOINT="$(cfg aws_endpoint_url)"
DB_NAME="$(cfg db_name)"
DB_USER="$(cfg db_username)"
DB_PASSWORD="$(cfg db_password)"

export AWS_ENDPOINT_URL="${ENDPOINT}"
export AWS_REGION="${REGION}" AWS_DEFAULT_REGION="${REGION}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_PAGER="" TF_IN_AUTOMATION=1 TF_INPUT=0 CHECKPOINT_DISABLE=1
export NO_PROXY="${NO_PROXY:-},aws" no_proxy="${no_proxy:-},aws"

# --- toolchain ---------------------------------------------------------------
if command -v terraform >/dev/null 2>&1; then TF=terraform
elif command -v tofu >/dev/null 2>&1; then TF=tofu
else die "terraform or tofu is required"; fi

PY=""
for cand in python3 /opt/venv/bin/python3 python; do
  if command -v "${cand}" >/dev/null 2>&1 && "${cand}" -c 'import boto3' >/dev/null 2>&1; then PY="${cand}"; break; fi
done
[[ -n "${PY}" ]] || die "python3 with boto3 is required"

WORK_DIR="$(mktemp -d)"
chmod 700 "${WORK_DIR}"
cleanup() { rm -rf "${WORK_DIR}"; }
trap cleanup EXIT

TFVARS="${WORK_DIR}/clearledger.auto.tfvars.json"
umask 077
jq '{resource_prefix, region, aws_endpoint_url, db_name, db_username, db_password,
     api_image, projector_image, relay_image, archiver_image,
     api_image_id: (.api_image_id // ""), projector_image_id: (.projector_image_id // ""),
     relay_image_id: (.relay_image_id // ""), archiver_image_id: (.archiver_image_id // "")}' \
  "${CONFIG_FILE}" > "${TFVARS}"
umask 022

log "deploying ClearLedger prefix=${PREFIX} region=${REGION} endpoint=${ENDPOINT} (${TF})"

# --- terraform ---------------------------------------------------------------
cd "${INFRA_DIR}"
log "terraform init"
"${TF}" init -input=false -no-color -upgrade=false >"${WORK_DIR}/init.log" 2>&1 \
  || { cat "${WORK_DIR}/init.log"; die "terraform init failed"; }

tf_apply() {
  "${TF}" apply -input=false -auto-approve -no-color -parallelism=20 \
    -var-file="${TFVARS}" "$@"
}

apply_ok=0
for attempt in 1 2 3; do
  log "terraform apply (attempt ${attempt})"
  if tf_apply >"${WORK_DIR}/apply.log" 2>&1; then
    grep -E '^(Apply complete|Plan:)' "${WORK_DIR}/apply.log" || true
    apply_ok=1
    break
  fi
  grep -E 'Error|error' -A6 "${WORK_DIR}/apply.log" | head -60 || true
  sleep $((attempt * 5))
done
[[ "${apply_ok}" == 1 ]] || die "terraform apply failed"

write_manifest() {
  "${TF}" output -no-color -json manifest > "${WORK_DIR}/manifest.json"
  "${PY}" - "${WORK_DIR}/manifest.json" "${SUBMISSION_DIR}/../contracts/schemas/manifest.schema.json" \
      /workspace/contracts/schemas/manifest.schema.json <<'PYEOF'
import json, os, sys
m = json.load(open(sys.argv[1]))
for path in sys.argv[2:]:
    if os.path.exists(path):
        try:
            import jsonschema
            jsonschema.validate(m, json.load(open(path)))
        except ImportError:
            pass
        break
PYEOF
  install -m 0644 "${WORK_DIR}/manifest.json" "${MANIFEST_FILE}"
}
write_manifest
log "manifest written to ${MANIFEST_FILE}"

# --- out-of-band IAM / security group guardrails -----------------------------
log "enforcing IAM and security-group guardrails"
"${PY}" "${OPS}" guard --config "${CONFIG_FILE}" --manifest "${MANIFEST_FILE}"

# Verify that terraform now sees no residual drift; re-apply once if it does.
if ! "${TF}" plan -input=false -no-color -detailed-exitcode \
      -var-file="${TFVARS}" >"${WORK_DIR}/plan.log" 2>&1; then
  log "residual drift detected; re-applying"
  tf_apply >"${WORK_DIR}/apply2.log" 2>&1 || { grep -E 'Error' -A6 "${WORK_DIR}/apply2.log" | head -40; die "re-apply failed"; }
  write_manifest
fi

# --- PostgreSQL schema -------------------------------------------------------
DB_HOST="$(jq -r .database.endpoint "${MANIFEST_FILE}")"
DB_PORT="$(jq -r .database.port "${MANIFEST_FILE}")"
export PGPASSWORD="${DB_PASSWORD}" PGCONNECT_TIMEOUT=5 PGTZ=UTC
PSQL=(psql -X -q -v ON_ERROR_STOP=1 -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}")

log "waiting for PostgreSQL at ${DB_HOST}:${DB_PORT}"
for i in $(seq 1 90); do
  if "${PSQL[@]}" -At -c 'SELECT 1' >/dev/null 2>&1; then break; fi
  [[ $i == 90 ]] && die "PostgreSQL not reachable"
  sleep 2
done

log "applying clearledger schema"
"${PSQL[@]}" -f "${SCHEMA_FILE}" >/dev/null

# --- readiness ---------------------------------------------------------------
SERVICE_URL="$(jq -r .service_url "${MANIFEST_FILE}")"
log "waiting for ${SERVICE_URL}/health/ready"
ready=0
for i in $(seq 1 150); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${SERVICE_URL}/health/ready" || true)"
  if [[ "${code}" == "200" ]]; then ready=1; break; fi
  sleep 2
done
[[ "${ready}" == 1 ]] || die "service never became ready (last HTTP ${code:-none})"
log "service ready"

# --- data-plane convergence --------------------------------------------------
log "reconciling outbox, projections, cache and audit archive"
"${PY}" "${OPS}" reconcile --config "${CONFIG_FILE}" --manifest "${MANIFEST_FILE}"

code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${SERVICE_URL}/health/ready" || true)"
[[ "${code}" == "200" ]] || die "service not ready after reconciliation (HTTP ${code})"

log "deployment complete: ${SERVICE_URL}"
