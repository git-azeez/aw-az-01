#!/usr/bin/env bash
# ClearLedger teardown: destroys everything Terraform manages for the active resource_prefix and
# sweeps any out-of-band operational resources scoped to that prefix. Baseline cl-base-* resources
# are never touched.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA="$ROOT/infra"
LIB="$ROOT/lib"
CONFIG="${CLEARLEDGER_CONFIG:-/workspace/config/config.json}"
START_TS=$SECONDS

log() { printf '[destroy %3ss] %s\n' "$((SECONDS - START_TS))" "$*"; }
die() { log "ERROR: $*"; exit 1; }

[[ -r "$CONFIG" ]] || die "config file $CONFIG not found"
PREFIX="$(jq -er .resource_prefix "$CONFIG")"
REGION="$(jq -er .region "$CONFIG")"
ENDPOINT="$(jq -er .aws_endpoint_url "$CONFIG")"
[[ -n "$PREFIX" && "$PREFIX" != cl-base* ]] || die "refusing to destroy baseline or empty prefix '$PREFIX'"

export AWS_ENDPOINT_URL="$ENDPOINT"
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export CLEARLEDGER_CONFIG="$CONFIG"
export TF_IN_AUTOMATION=1 TF_INPUT=0
[[ -z "${TF_CLI_CONFIG_FILE:-}" && -r /etc/terraform.tfrc ]] && export TF_CLI_CONFIG_FILE=/etc/terraform.tfrc
export NO_PROXY="${NO_PROXY:-},aws,localhost,127.0.0.1" no_proxy="${no_proxy:-},aws,localhost,127.0.0.1"

TF="${TF_BIN:-terraform}"
command -v "$TF" >/dev/null || die "$TF not found"
TFVARS=(-var "config_path=$CONFIG")
mkdir -p "$INFRA"
cd "$INFRA"

state_count() { "$TF" state list 2>/dev/null | grep -c . || true; }

log "terraform init (prefix=$PREFIX)"
for i in 1 2 3; do "$TF" init -input=false -no-color >/dev/null 2>&1 && break || sleep 3; done

# 1. out-of-band attachments and non-empty versioned buckets would block the destroy
log "detaching out-of-band IAM policies and emptying buckets"
python3 "$LIB/cleanup.py" pre || log "pre-clean reported errors (continuing)"

# 2. terraform destroy (retried: dependent resources may need a moment to disappear)
for attempt in 1 2 3; do
  log "terraform destroy (attempt $attempt)"
  if "$TF" destroy -auto-approve -input=false -no-color -lock-timeout=60s "${TFVARS[@]}" >/tmp/clearledger-tf-destroy.log 2>&1; then
    grep -E "^Destroy complete" /tmp/clearledger-tf-destroy.log || true
    break
  fi
  tail -25 /tmp/clearledger-tf-destroy.log
  log "terraform destroy failed; sweeping blockers and retrying"
  python3 "$LIB/cleanup.py" sweep || true
  sleep 5
done

# 3. sweep everything else scoped to the prefix (out-of-band queues, schedules, roles, policies, keys, ...)
log "sweeping out-of-band resources scoped to $PREFIX"
python3 "$LIB/cleanup.py" sweep || log "sweep reported errors"

# 4. a final destroy pass makes sure that nothing is left in the state, then verify the inventory
if [[ "$(state_count)" != "0" ]]; then
  log "state still lists resources; running a final destroy"
  "$TF" destroy -auto-approve -input=false -no-color -lock-timeout=60s "${TFVARS[@]}" >/tmp/clearledger-tf-destroy2.log 2>&1 \
    || tail -25 /tmp/clearledger-tf-destroy2.log
fi

rc=0
if [[ "$(state_count)" != "0" ]]; then
  log "terraform state still tracks: $("$TF" state list | tr '\n' ' ')"
  rc=1
fi
if ! python3 "$LIB/cleanup.py" verify; then
  # one more sweep for asynchronously disappearing resources
  sleep 5
  python3 "$LIB/cleanup.py" sweep || true
  python3 "$LIB/cleanup.py" verify || rc=1
fi

if [[ $rc -eq 0 ]]; then
  log "destroy complete: no managed or prefix-scoped resources remain"
else
  log "destroy finished with leftovers"
fi
exit $rc
