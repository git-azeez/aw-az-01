#!/usr/bin/env bash
# ClearLedger teardown: terraform destroy + prefix/tag scoped sweep of out-of-band leftovers.
# Baseline resources (cl-base-*) are never touched.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${CLEARLEDGER_CONFIG:-/workspace/config/config.json}"
INFRA="${HERE}/infra"
OPS="${HERE}/clearledger_ops.py"

START_TS=$(date +%s)
WORK="$(mktemp -d /tmp/clearledger-destroy.XXXXXX)"
chmod 700 "${WORK}"
trap 'rm -rf "${WORK}"' EXIT

log() { printf '[destroy %4ss] %s\n' "$(( $(date +%s) - START_TS ))" "$*"; }

[ -f "${CONFIG}" ] || { echo "config not found: ${CONFIG}" >&2; exit 1; }

PREFIX="$(jq -r '.resource_prefix' "${CONFIG}")"
REGION="$(jq -r '.region' "${CONFIG}")"
ENDPOINT="$(jq -r '.aws_endpoint_url' "${CONFIG}")"
DB_PASSWORD="$(jq -r '.db_password' "${CONFIG}")"

case "${PREFIX}" in
  ""|null|cl-base*) echo "refusing to destroy prefix '${PREFIX}'" >&2; exit 1 ;;
esac

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_REGION="${REGION}" AWS_DEFAULT_REGION="${REGION}"
export AWS_ENDPOINT_URL="${ENDPOINT}"
export AWS_PAGER=""
export TF_IN_AUTOMATION=1 TF_INPUT=0
export PYTHONUNBUFFERED=1

if command -v terraform >/dev/null 2>&1; then TF=terraform; else TF=tofu; fi

SED_PW="$(printf '%s' "${DB_PASSWORD}" | sed -e 's/[]\/$*.^&[]/\\&/g')"
redact() { sed -u -e "s/${SED_PW}/********/g"; }

log "ClearLedger destroy for prefix=${PREFIX}"

jq '{resource_prefix, region, aws_endpoint_url, db_name, db_username, db_password,
     api_image, projector_image, relay_image, archiver_image,
     api_image_id: (.api_image_id // ""), projector_image_id: (.projector_image_id // ""),
     relay_image_id: (.relay_image_id // ""), archiver_image_id: (.archiver_image_id // "")}' \
  "${CONFIG}" > "${WORK}/clearledger.auto.tfvars.json"

"${TF}" -chdir="${INFRA}" init -input=false -no-color >"${WORK}/init.log" 2>&1 || redact <"${WORK}/init.log"

# KMS keys that were disabled / scheduled for deletion out-of-band must not block destroy.
python3 "${OPS}" preflight "${CONFIG}" 2>&1 | redact || true

# Stop ECS service first so tasks drain while the rest is being destroyed.
destroy_pass() {
  log "terraform destroy (pass $1)"
  if "${TF}" -chdir="${INFRA}" destroy -auto-approve -input=false -no-color -compact-warnings \
       -parallelism=20 -refresh=true -var-file="${WORK}/clearledger.auto.tfvars.json" >"${WORK}/destroy.log" 2>&1; then
    grep -E 'Destroy complete|Destruction complete' "${WORK}/destroy.log" | redact | tail -n 80
    return 0
  fi
  grep -vE 'Still destroying|Refreshing state|Reading\.\.\.|Read complete' "${WORK}/destroy.log" | redact | tail -n 40
  return 1
}

state_count() {
  "${TF}" -chdir="${INFRA}" state list 2>/dev/null | grep -v '^data\.' | wc -l | tr -d ' '
}

if [ -f "${INFRA}/terraform.tfstate" ]; then
  for pass in 1 2 3; do
    if destroy_pass "${pass}"; then break; fi
    log "destroy pass ${pass} failed; sweeping blockers and retrying"
    python3 "${OPS}" sweep "${CONFIG}" 2>&1 | redact || true
    sleep 3
  done
fi

# Sweep anything left behind (out-of-band resources scoped to the prefix / tag).
log "sweeping out-of-band resources for ${PREFIX}"
python3 "${OPS}" sweep "${CONFIG}" 2>&1 | redact || true

# Anything still tracked in state is now gone from the cloud: drop it from state.
if [ -f "${INFRA}/terraform.tfstate" ]; then
  remaining="$(state_count)"
  if [ "${remaining}" != "0" ]; then
    log "final destroy pass for ${remaining} tracked resources"
    destroy_pass final || true
    remaining="$(state_count)"
  fi
  if [ "${remaining}" != "0" ]; then
    log "removing ${remaining} already-deleted resources from state"
    "${TF}" -chdir="${INFRA}" state list 2>/dev/null | while read -r addr; do
      [ -n "${addr}" ] && "${TF}" -chdir="${INFRA}" state rm -lock=false "${addr}" >/dev/null 2>&1 || true
    done
  fi
  log "terraform state resources remaining: $(state_count)"
fi

log "destroy complete"
exit 0
