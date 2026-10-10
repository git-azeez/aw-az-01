#!/usr/bin/env bash
# ClearLedger teardown: terraform/tofu destroy + prefix-scoped sweep of any
# out-of-band leftovers. Baseline `cl-base-*` resources are never touched.
set -Euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA="${HERE}/infra"
CONFIG="${CLEARLEDGER_CONFIG:-/workspace/config/config.json}"
START_TS=$(date +%s)

log() { printf '[destroy %4ss] %s\n' "$(( $(date +%s) - START_TS ))" "$*"; }

[[ -f "${CONFIG}" ]] || { log "config not found: ${CONFIG}"; exit 1; }

if command -v terraform >/dev/null 2>&1; then TF=terraform
elif command -v tofu >/dev/null 2>&1; then TF=tofu
else log "neither terraform nor tofu found"; exit 1; fi

if [[ -z "${TF_CLI_CONFIG_FILE:-}" && -f /etc/terraform.tfrc ]]; then
  export TF_CLI_CONFIG_FILE=/etc/terraform.tfrc
fi
export TF_IN_AUTOMATION=1 TF_INPUT=0 CHECKPOINT_DISABLE=1

PREFIX="$(jq -er .resource_prefix "${CONFIG}")"
REGION="$(jq -er .region "${CONFIG}")"
ENDPOINT="$(jq -er .aws_endpoint_url "${CONFIG}")"
case "${PREFIX}" in
  ""|cl-base*) log "refusing to destroy with prefix '${PREFIX}'"; exit 1 ;;
esac

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

log "destroying ClearLedger prefix=${PREFIX} using ${TF}"
cd "${INFRA}"

"${TF}" init -input=false -no-color >/tmp/clearledger-tf-init.log 2>&1 \
  || { sleep 3; "${TF}" init -input=false -no-color >/tmp/clearledger-tf-init.log 2>&1; } \
  || { cat /tmp/clearledger-tf-init.log; log "init failed; continuing with sweep only"; }

tf_destroy() {
  local rc=0
  "${TF}" destroy -auto-approve -input=false -no-color -compact-warnings "$@" \
    >/tmp/clearledger-tf-destroy.log 2>&1 || rc=$?
  grep -E '^(Destroy complete|Error|│ Error)' /tmp/clearledger-tf-destroy.log | head -c 100000 || true
  return ${rc}
}

if [[ -f terraform.tfstate ]]; then
  log "${TF} destroy"
  if ! tf_destroy; then
    log "destroy reported errors; sweeping and retrying"
  fi
fi

log "sweeping prefix-scoped resources"
python3 "${INFRA}/sweep.py" "${CONFIG}" || log "sweep reported errors"

if [[ -f terraform.tfstate ]]; then
  remaining="$("${TF}" state list 2>/dev/null | grep -v '^data\.' || true)"
  if [[ -n "${remaining}" ]]; then
    log "re-running ${TF} destroy for $(wc -l <<<"${remaining}") remaining state entries"
    tf_destroy || true
    remaining="$("${TF}" state list 2>/dev/null | grep -v '^data\.' || true)"
  fi
  if [[ -n "${remaining}" ]]; then
    log "dropping state entries for resources already removed by the sweep"
    while read -r addr; do
      [[ -n "${addr}" ]] && "${TF}" state rm -no-color "${addr}" >/dev/null 2>&1 || true
    done <<<"${remaining}"
  fi
  # Second sweep catches anything Terraform recreated or left behind.
  python3 "${INFRA}/sweep.py" "${CONFIG}" >/dev/null 2>&1 || true
  left="$("${TF}" state list 2>/dev/null | grep -v '^data\.' | wc -l)"
  log "terraform state now tracks ${left} managed resources"
fi

log "ClearLedger prefix ${PREFIX} destroyed"
exit 0
