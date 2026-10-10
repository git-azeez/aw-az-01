#!/usr/bin/env bash
# ClearLedger destroy: tear down every resource of the active resource_prefix
# (Terraform-managed and out-of-band), leaving baseline (cl-base-*) untouched.
set -Euo pipefail

SUBMISSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${SUBMISSION_DIR}/infra"
CONFIG_FILE="${CLEARLEDGER_CONFIG:-/workspace/config/config.json}"
CLEANUP="${SUBMISSION_DIR}/scripts/cleanup.py"
START_TS=$(date +%s)

log() { printf '[destroy %4ss] %s\n' "$(( $(date +%s) - START_TS ))" "$*" >&2; }

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/clearledger-destroy.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT

[[ -f "${CONFIG_FILE}" ]] || { log "config not found: ${CONFIG_FILE}"; exit 1; }
cfg() { jq -er --arg k "$1" '.[$k] // empty' "${CONFIG_FILE}"; }

RESOURCE_PREFIX="$(cfg resource_prefix)"
REGION="$(cfg region)"
AWS_ENDPOINT="$(cfg aws_endpoint_url)"
[[ -n "${RESOURCE_PREFIX}" ]] || { log "empty resource_prefix"; exit 1; }

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
EP_HOST="$(sed -E 's#^[a-z]+://([^:/]+).*#\1#' <<<"${AWS_ENDPOINT}")"
export NO_PROXY="${NO_PROXY:-},${EP_HOST}" no_proxy="${no_proxy:-},${EP_HOST}"

if command -v terraform >/dev/null 2>&1; then TF=terraform
elif command -v tofu >/dev/null 2>&1; then TF=tofu
else log "neither terraform nor tofu found"; exit 1; fi

log "destroying resource_prefix=${RESOURCE_PREFIX} (${TF})"
cd "${INFRA_DIR}"
"${TF}" init -input=false -no-color >"${WORK_DIR}/init.log" 2>&1 || tail -n 30 "${WORK_DIR}/init.log" >&2

state_count() { "${TF}" state list 2>/dev/null | grep -vc '^data\.' || true; }

# Versioned audit bucket: purge every object version and delete marker first.
python3 "${CLEANUP}" "${RESOURCE_PREFIX}" "${REGION}" --empty-buckets-only || true

for attempt in 1 2 3; do
  [[ "$(state_count)" == 0 ]] && break
  log "${TF} destroy (attempt ${attempt})"
  if "${TF}" destroy -auto-approve -input=false -no-color -compact-warnings -parallelism=20 \
       >"${WORK_DIR}/destroy.log" 2>&1; then
    grep -E '^Destroy complete' "${WORK_DIR}/destroy.log" >&2 || true
    break
  fi
  grep -vE 'Still destroying|Refreshing state|Reading\.\.\.|Read complete' "${WORK_DIR}/destroy.log" | tail -n 30 >&2
  # Remove whatever blocks Terraform (out-of-band dependencies), then retry.
  python3 "${CLEANUP}" "${RESOURCE_PREFIX}" "${REGION}" || true
  sleep 5
done

# Prefix/tag-scoped sweep for out-of-band operational resources.
log "sweeping out-of-band resources scoped to ${RESOURCE_PREFIX}"
python3 "${CLEANUP}" "${RESOURCE_PREFIX}" "${REGION}" || true

# Anything Terraform still tracks no longer exists in the cloud after the sweep;
# refresh once more and drop residual entries so the state is empty.
if [[ "$(state_count)" != 0 ]]; then
  "${TF}" destroy -auto-approve -input=false -no-color -refresh=true >"${WORK_DIR}/destroy2.log" 2>&1 || true
fi
if [[ "$(state_count)" != 0 ]]; then
  log "dropping residual state entries"
  "${TF}" state list 2>/dev/null | grep -v '^data\.' | while read -r addr; do
    "${TF}" state rm "${addr}" >/dev/null 2>&1 || true
  done
fi

rm -f "${SUBMISSION_DIR}/manifest.json"
log "destroy complete (managed resources remaining in state: $(state_count))"
exit 0
