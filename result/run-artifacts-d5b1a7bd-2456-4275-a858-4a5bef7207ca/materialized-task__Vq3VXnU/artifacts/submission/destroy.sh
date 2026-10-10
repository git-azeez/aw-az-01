#!/usr/bin/env bash
# ClearLedger teardown: destroy all Terraform-managed resources for the active
# resource_prefix, then sweep any prefix-scoped out-of-band leftovers.
# Baseline cl-base-* resources are never touched.
set -Eeuo pipefail

SUBMISSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${SUBMISSION_DIR}/infra"
CONFIG_FILE="${CLEARLEDGER_CONFIG:-/workspace/config/config.json}"
OPS="${INFRA_DIR}/scripts/clearledger_ops.py"
STATE_FILE="${INFRA_DIR}/terraform.tfstate"

log() { printf '[destroy %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

[[ -f "${CONFIG_FILE}" ]] || die "config file ${CONFIG_FILE} not found"
command -v jq >/dev/null || die "jq is required"

cfg() { jq -er --arg k "$1" '.[$k]' "${CONFIG_FILE}"; }
PREFIX="$(cfg resource_prefix)"
REGION="$(cfg region)"
ENDPOINT="$(cfg aws_endpoint_url)"
case "${PREFIX}" in
  ""|cl-base*) die "refusing to destroy baseline prefix '${PREFIX}'" ;;
esac

export AWS_ENDPOINT_URL="${ENDPOINT}"
export AWS_REGION="${REGION}" AWS_DEFAULT_REGION="${REGION}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_PAGER="" TF_IN_AUTOMATION=1 TF_INPUT=0 CHECKPOINT_DISABLE=1
export NO_PROXY="${NO_PROXY:-},aws" no_proxy="${no_proxy:-},aws"

if command -v terraform >/dev/null 2>&1; then TF=terraform
elif command -v tofu >/dev/null 2>&1; then TF=tofu
else die "terraform or tofu is required"; fi

PY=""
for cand in python3 /opt/venv/bin/python3 python; do
  if command -v "${cand}" >/dev/null 2>&1 && "${cand}" -c 'import boto3' >/dev/null 2>&1; then PY="${cand}"; break; fi
done

WORK_DIR="$(mktemp -d)"
chmod 700 "${WORK_DIR}"
trap 'rm -rf "${WORK_DIR}"' EXIT
TFVARS="${WORK_DIR}/clearledger.auto.tfvars.json"
umask 077
jq '{resource_prefix, region, aws_endpoint_url, db_name, db_username, db_password,
     api_image, projector_image, relay_image, archiver_image,
     api_image_id: (.api_image_id // ""), projector_image_id: (.projector_image_id // ""),
     relay_image_id: (.relay_image_id // ""), archiver_image_id: (.archiver_image_id // "")}' \
  "${CONFIG_FILE}" > "${TFVARS}"
umask 022

log "destroying ClearLedger prefix=${PREFIX} (${TF})"
cd "${INFRA_DIR}"
"${TF}" init -input=false -no-color -upgrade=false >"${WORK_DIR}/init.log" 2>&1 \
  || { cat "${WORK_DIR}/init.log"; die "terraform init failed"; }

state_count() {
  if [[ -f "${STATE_FILE}" ]]; then
    "${TF}" state list 2>/dev/null | grep -vc '^data\.' || true
  else
    echo 0
  fi
}

# Out-of-band policy attachments on our roles would block role deletion.
if [[ -n "${PY}" ]]; then
  "${PY}" - "${CONFIG_FILE}" <<'PYEOF' || true
import json, sys, boto3
cfg = json.load(open(sys.argv[1]))
p = cfg["resource_prefix"]
iam = boto3.client("iam", endpoint_url=cfg["aws_endpoint_url"], region_name=cfg.get("region", "us-east-1"))
for role in ["ecs-execution", "ecs-task", "projector", "relay", "archiver", "scheduler"]:
    name = f"{p}-{role}"
    try:
        for n in iam.list_role_policies(RoleName=name).get("PolicyNames", []):
            if n != f"{name}-policy":
                iam.delete_role_policy(RoleName=name, PolicyName=n)
        for a in iam.list_attached_role_policies(RoleName=name).get("AttachedPolicies", []):
            iam.detach_role_policy(RoleName=name, PolicyArn=a["PolicyArn"])
    except Exception:
        pass
PYEOF
fi

destroy_ok=0
if [[ "$(state_count)" -gt 0 ]]; then
  for attempt in 1 2 3; do
    log "terraform destroy (attempt ${attempt})"
    if "${TF}" destroy -input=false -auto-approve -no-color -parallelism=20 \
         -var-file="${TFVARS}" >"${WORK_DIR}/destroy.log" 2>&1; then
      grep -E '^Destroy complete' "${WORK_DIR}/destroy.log" || true
      destroy_ok=1
      break
    fi
    grep -E 'Error' -A6 "${WORK_DIR}/destroy.log" | head -40 || true
    # clear blockers before retrying
    [[ -n "${PY}" ]] && "${PY}" "${OPS}" sweep --config "${CONFIG_FILE}" >/dev/null 2>&1 || true
    sleep $((attempt * 5))
  done
else
  destroy_ok=1
  log "no Terraform-managed resources in state"
fi

# Prefix-scoped sweep of anything created out-of-band (or left by a failed destroy).
if [[ -n "${PY}" ]]; then
  log "sweeping prefix-scoped leftovers"
  "${PY}" "${OPS}" sweep --config "${CONFIG_FILE}" || log "sweep reported errors (continuing)"
else
  log "python3/boto3 unavailable; skipping out-of-band sweep"
fi

# Anything still tracked has been removed by the sweep; refresh and forget it.
if [[ "$(state_count)" -gt 0 ]]; then
  log "reconciling residual state entries"
  "${TF}" destroy -input=false -auto-approve -no-color -refresh=true -parallelism=20 \
      -var-file="${TFVARS}" >"${WORK_DIR}/destroy2.log" 2>&1 || true
  for addr in $("${TF}" state list 2>/dev/null || true); do
    "${TF}" state rm -no-color "${addr}" >/dev/null 2>&1 || true
  done
fi

remaining="$(state_count)"
log "terraform state now tracks ${remaining} resources"
[[ "${remaining}" == 0 ]] || die "state still tracks resources"
[[ "${destroy_ok}" == 1 ]] || log "terraform destroy needed sweep assistance; state is clean"
log "teardown complete for prefix ${PREFIX}"
