#!/usr/bin/env bash
# ClearLedger teardown: Terraform/OpenTofu destroy plus prefix-scoped removal of
# anything created out-of-band. Baseline (cl-base-*) resources are never touched.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${CLEARLEDGER_CONFIG:-/workspace/config/config.json}"
INFRA="$ROOT/infra"
SWEEP="$ROOT/scripts/sweep.py"

log() { printf '[destroy %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

PREFIX="$(jq -er .resource_prefix "$CONFIG")"
REGION="$(jq -er .region "$CONFIG")"
ENDPOINT="$(jq -er .aws_endpoint_url "$CONFIG")"

export AWS_ENDPOINT_URL="$ENDPOINT"
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_EC2_METADATA_DISABLED=true
export TF_IN_AUTOMATION=1 TF_INPUT=0
ENDPOINT_HOST="$(printf '%s' "$ENDPOINT" | sed -E 's#^[a-z]+://([^:/]+).*#\1#')"
export NO_PROXY="${NO_PROXY:-},${ENDPOINT_HOST},localhost,127.0.0.1" no_proxy="${no_proxy:-},${ENDPOINT_HOST},localhost,127.0.0.1"

if command -v terraform >/dev/null 2>&1; then TF=terraform
elif command -v tofu >/dev/null 2>&1; then TF=tofu
else log "neither terraform nor tofu is installed"; exit 1; fi
tf() { "$TF" -chdir="$INFRA" "$@"; }

tf_destroy() {
  tf destroy -auto-approve -input=false -no-color -lock-timeout=120s -parallelism=20 \
     -var "config_path=$CONFIG" 2>&1 | grep -v -E '^(.*: (Refreshing state|Still (creating|modifying|destroying))\.\.\.|\s*$)'
}

log "destroying resource prefix $PREFIX"

# 1. remove what would block Terraform: foreign IAM attachments / policies and versioned bucket content
python3 "$SWEEP" pre --config "$CONFIG" || log "pre-clean reported problems (continuing)"

# 2. Terraform-managed resources
tf init -input=false -no-color >/dev/null 2>&1 || log "terraform init failed (continuing with sweep)"
destroyed=0
for attempt in 1 2 3; do
  log "terraform destroy (attempt $attempt)"
  if tf_destroy; then destroyed=1; break; fi
  log "destroy failed; sweeping blockers and retrying"
  python3 "$SWEEP" all --config "$CONFIG" || true
done

# 3. everything else scoped to the prefix (out-of-band resources, emulator leftovers)
log "sweeping remaining prefix-scoped resources"
python3 "$SWEEP" all --config "$CONFIG" || true

# 4. make sure the state file tracks nothing (refresh drops anything already gone)
if [ -f "$INFRA/terraform.tfstate" ] && [ -n "$(tf state list 2>/dev/null || true)" ]; then
  log "terraform state still tracks resources; destroying again"
  tf_destroy || { python3 "$SWEEP" all --config "$CONFIG" || true; tf_destroy || true; }
fi
if [ -n "$(tf state list 2>/dev/null || true)" ]; then
  log "state still lists resources:"; tf state list || true
  exit 1
fi

# 5. verification
for i in 1 2 3; do
  if python3 "$SWEEP" verify --config "$CONFIG"; then
    log "teardown complete: no resources remain for $PREFIX"
    exit 0
  fi
  sleep 5
  python3 "$SWEEP" all --config "$CONFIG" || true
done
log "some prefix-scoped resources could not be removed"
exit 1
