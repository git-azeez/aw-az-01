#!/usr/bin/env bash
# ClearLedger teardown: removes everything scoped to <resource_prefix> and leaves cl-base-* resources alone.
set -Eeuo pipefail

SUBMISSION="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA="$SUBMISSION/infra"
LIB="$SUBMISSION/lib"
CONFIG="${CLEARLEDGER_CONFIG:-/workspace/config/config.json}"
START=$(date +%s)

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }
cfg() { jq -er ".$1" "$CONFIG"; }

[ -r "$CONFIG" ] || die "config not found: $CONFIG"
export AWS_ENDPOINT_URL AWS_REGION AWS_DEFAULT_REGION AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test
AWS_ENDPOINT_URL="$(cfg aws_endpoint_url)"
AWS_REGION="$(cfg region)"
AWS_DEFAULT_REGION="$AWS_REGION"
PREFIX="$(cfg resource_prefix)"
case "$PREFIX" in cl-base*|"") die "refusing to destroy baseline/empty prefix '$PREFIX'";; esac
export TF_IN_AUTOMATION=1 TF_INPUT=0
[ -n "${TF_CLI_CONFIG_FILE:-}" ] || { [ -r /etc/terraform.tfrc ] && export TF_CLI_CONFIG_FILE=/etc/terraform.tfrc; } || true
export PYTHONPATH="$LIB${PYTHONPATH:+:$PYTHONPATH}"
export PYTHONUNBUFFERED=1
export no_proxy="${no_proxy:+$no_proxy,}aws,localhost,127.0.0.1" NO_PROXY="${NO_PROXY:+$NO_PROXY,}aws,localhost,127.0.0.1"

TF=terraform
tf() { (cd "$INFRA" && "$TF" "$@"); }

filtered() {
  local rc
  set +e
  "$@" 2>&1 | grep --line-buffered -v -E 'Still (creating|modifying|destroying)\.\.\.|^$'
  rc=${PIPESTATUS[0]}
  set -e
  return "$rc"
}

tf_destroy() {
  filtered bash -c 'cd "$1" && shift && exec timeout "$1" terraform destroy -auto-approve -input=false -no-color -compact-warnings -lock-timeout=60s -var-file="$2"' _ "$INFRA" "$1" "$CONFIG"
}

log "== 1/4 terraform init"
tf init -input=false -no-color -upgrade=false >/dev/null || die "terraform init failed"

log "== 2/4 pre-clean: non-empty versioned buckets and out-of-band IAM attachments on $PREFIX roles"
python3 "$LIB/sweep.py" pre || log "pre-clean reported errors (continuing)"

log "== 3/4 terraform destroy"
destroyed=0
for attempt in 1 2 3; do
  if tf_destroy 600; then destroyed=1; break; fi
  log "terraform destroy attempt $attempt failed; sweeping blockers and retrying"
  python3 "$LIB/sweep.py" pre || true
  sleep 5
done

log "== 4/4 post-clean: prefix-scoped out-of-band resources"
python3 "$LIB/sweep.py" post || log "post-clean reported errors"

if [ "$destroyed" -ne 1 ]; then
  # one more attempt now that out-of-band blockers are gone
  tf_destroy 300 || true
  python3 "$LIB/sweep.py" post || true
fi

remaining="$(tf state list 2>/dev/null | wc -l | tr -d ' ')"
[ "${remaining:-0}" -eq 0 ] || die "$remaining resource(s) still tracked in terraform.tfstate"
log "destroy complete after $(( $(date +%s) - START ))s"
exit 0
