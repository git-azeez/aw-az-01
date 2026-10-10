#!/usr/bin/env bash
# Shared helpers for deploy.sh / destroy.sh.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA="$ROOT/infra"
CONFIG_FILE="${CLEARLEDGER_CONFIG:-/workspace/config/config.json}"
SCRIPT_START=$(date +%s)

log() { printf '[%s +%03ds] %s\n' "$(date -u +%H:%M:%S)" "$(( $(date +%s) - SCRIPT_START ))" "$*"; }
die() { log "ERROR: $*"; exit 1; }

cfg() { jq -er --arg k "$1" '.[$k]' "$CONFIG_FILE"; }

load_config() {
  [ -r "$CONFIG_FILE" ] || die "config file $CONFIG_FILE not readable"
  PREFIX="$(cfg resource_prefix)"
  REGION="$(cfg region)"
  ENDPOINT="$(cfg aws_endpoint_url)"
  DB_NAME="$(cfg db_name)"
  DB_USER="$(cfg db_username)"
  DB_PASS="$(cfg db_password)"
  export AWS_ENDPOINT_URL="$ENDPOINT"
  export AWS_DEFAULT_REGION="$REGION" AWS_REGION="$REGION"
  export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
  export AWS_PAGER=""
  export CLEARLEDGER_CONFIG="$CONFIG_FILE"
  export TF_IN_AUTOMATION=1 TF_INPUT=0
  export TF_VAR_config_path="$CONFIG_FILE"
  # never route control-plane traffic through the egress proxy
  local host
  host="$(printf '%s' "$ENDPOINT" | sed -E 's#^[a-z]+://([^:/]+).*#\1#')"
  export NO_PROXY="${NO_PROXY:-},$host,localhost,127.0.0.1,.localhost"
  export no_proxy="$NO_PROXY"
}

pick_tf() {
  if command -v terraform >/dev/null 2>&1; then TF=terraform
  elif command -v tofu >/dev/null 2>&1; then TF=tofu
  else die "neither terraform nor tofu is installed"; fi
}

# The AWS provider's S3 Control client prefixes the account id to the endpoint
# host; loopback ("*.localhost") is the only name that always resolves, so a tiny
# forwarder fronts the control plane for it.
FORWARDER_PID=""
start_forwarder() {
  local portfile host port
  portfile="$(mktemp)"
  host="$(printf '%s' "$ENDPOINT" | sed -E 's#^[a-z]+://([^:/]+).*#\1#')"
  port="$(printf '%s' "$ENDPOINT" | sed -nE 's#^[a-z]+://[^:/]+:([0-9]+).*#\1#p')"
  port="${port:-4566}"
  python3 "$ROOT/scripts/tcp_forward.py" 0 "$host" "$port" >"$portfile" 2>/dev/null &
  FORWARDER_PID=$!
  local i
  for i in $(seq 1 50); do
    [ -s "$portfile" ] && break
    sleep 0.1
  done
  [ -s "$portfile" ] || die "control-plane forwarder did not start"
  export TF_VAR_s3control_endpoint="http://localhost:$(head -n1 "$portfile")"
  rm -f "$portfile"
}
stop_forwarder() { [ -n "$FORWARDER_PID" ] && kill "$FORWARDER_PID" 2>/dev/null || true; }

tf() { "$TF" -chdir="$INFRA" "$@"; }

tf_init() {
  tf init -input=false -no-color >/dev/null || tf init -input=false -no-color -reconfigure
}
