#!/usr/bin/env bash
# ClearLedger teardown: destroys every Terraform-managed resource for the active
# resource_prefix and sweeps any out-of-band <resource_prefix>-scoped leftovers
# (IAM attachments/versions, breakglass roles, versioned buckets, queues, tables,
# schedules, KMS keys/aliases, log groups). Baseline cl-base-* resources are never touched.
set -Eeuo pipefail

SUBMISSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${SUBMISSION_DIR}/infra"
CONFIG_FILE="${CLEARLEDGER_CONFIG:-/workspace/config/config.json}"
MANIFEST_FILE="${SUBMISSION_DIR}/manifest.json"
OPS="${INFRA_DIR}/scripts/clearledger_ops.py"
WORK_DIR="${INFRA_DIR}/.terraform/clearledger"

log() { printf '[destroy %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

[[ -f "${CONFIG_FILE}" ]] || die "config file ${CONFIG_FILE} not found"
cfg() { jq -r --arg k "$1" '.[$k] // empty' "${CONFIG_FILE}"; }

RESOURCE_PREFIX="$(cfg resource_prefix)"
REGION="$(cfg region)"; REGION="${REGION:-us-east-1}"
ENDPOINT="$(cfg aws_endpoint_url)"; ENDPOINT="${ENDPOINT:-http://aws:4566}"
[[ -n "${RESOURCE_PREFIX}" ]] || die "resource_prefix missing from config"
case "${RESOURCE_PREFIX}" in cl-base*) die "refusing to destroy baseline prefix ${RESOURCE_PREFIX}";; esac

export AWS_REGION="${REGION}" AWS_DEFAULT_REGION="${REGION}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_ENDPOINT_URL="${ENDPOINT}" AWS_EC2_METADATA_DISABLED=true AWS_PAGER=""
export CLEARLEDGER_CONFIG="${CONFIG_FILE}" CLEARLEDGER_MANIFEST="${MANIFEST_FILE}"
export TF_IN_AUTOMATION=1 TF_INPUT=0
export NO_PROXY="${NO_PROXY:-},aws,localhost,127.0.0.1" no_proxy="${no_proxy:-},aws,localhost,127.0.0.1"

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

log "initialising ${TF} (prefix ${RESOURCE_PREFIX})"
for i in 1 2 3; do
  if tfq init -input=false -no-color >"${WORK_DIR}/init.log" 2>&1; then break; fi
  [[ $i -eq 3 ]] && { tail -n 30 "${WORK_DIR}/init.log"; die "terraform init failed"; }
  sleep 3
done

log "pre-destroy sweep (out-of-band IAM attachments, versioned bucket contents)"
"${PY}" "${OPS}" destroy-sweep pre || log "WARNING: pre-destroy sweep reported errors"

state_count() {
  if [[ -f "${INFRA_DIR}/terraform.tfstate" ]]; then
    tfq state list 2>/dev/null | grep -vc '^data\.' || true
  else
    echo 0
  fi
}

destroyed=0
if [[ "$(state_count)" -gt 0 ]]; then
  for i in 1 2 3; do
    log "${TF} destroy (attempt ${i})"
    if tfq destroy -auto-approve -input=false -no-color -var-file="${VARS_FILE}" -parallelism=20 \
         >"${WORK_DIR}/destroy.log" 2>&1; then
      destroyed=1
      grep -E '^Destroy complete' "${WORK_DIR}/destroy.log" || true
      break
    fi
    log "destroy attempt ${i} failed:"
    grep -E 'Error:' -A3 "${WORK_DIR}/destroy.log" | grep -v -i -E 'password|secret' | head -n 30 || true
    "${PY}" "${OPS}" destroy-sweep pre >/dev/null 2>&1 || true
    sleep $((i * 5))
  done
else
  destroyed=1
  log "no Terraform-managed resources in state"
fi

log "post-destroy sweep of ${RESOURCE_PREFIX}-scoped resources"
"${PY}" "${OPS}" destroy-sweep post || log "WARNING: post-destroy sweep reported errors"

if [[ "$(state_count)" -gt 0 ]]; then
  log "state still tracks resources; refreshing destroy after sweep"
  tfq destroy -auto-approve -input=false -no-color -var-file="${VARS_FILE}" -parallelism=20 \
      >"${WORK_DIR}/destroy2.log" 2>&1 || true
  "${PY}" "${OPS}" destroy-sweep post >/dev/null 2>&1 || true
fi

if [[ "$(state_count)" -gt 0 ]]; then
  log "removing swept leftovers from state:"
  tfq state list 2>/dev/null | grep -v '^data\.' | while read -r addr; do
    log "  state rm ${addr}"
    tfq state rm "${addr}" >/dev/null 2>&1 || true
  done
fi

remaining="$(state_count)"
[[ "${remaining}" -eq 0 ]] || die "${remaining} resource(s) remain in terraform.tfstate"
log "teardown complete for ${RESOURCE_PREFIX} (terraform.tfstate has 0 managed resources)"
exit 0
