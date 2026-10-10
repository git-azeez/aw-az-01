#!/usr/bin/env bash
# Shared helpers for deploy.sh / destroy.sh (sourced, not executed).

SUB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="$SUB_DIR/infra"
CONFIG_FILE="${CLEARLEDGER_CONFIG:-/workspace/config/config.json}"
MANIFEST_FILE="$SUB_DIR/manifest.json"
STATE_FILE="$INFRA_DIR/terraform.tfstate"
PROXY_PID=""

ts() { date -u +%H:%M:%S; }
log() { echo "[$(ts)] $*"; }
die() { echo "[$(ts)] ERROR: $*" >&2; exit 1; }

cfg() { jq -er --arg k "$1" '.[$k]' "$CONFIG_FILE"; }

load_config() {
  [ -r "$CONFIG_FILE" ] || die "config file $CONFIG_FILE not readable"
  RESOURCE_PREFIX="$(cfg resource_prefix)"
  REGION="$(cfg region)"
  AWS_ENDPOINT="$(cfg aws_endpoint_url)"
  DB_NAME="$(cfg db_name)"
  DB_USER="$(cfg db_username)"
  DB_PASSWORD="$(cfg db_password)"
  export AWS_ENDPOINT_URL="$AWS_ENDPOINT"
  export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"
  export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
  export AWS_EC2_METADATA_DISABLED=true
  export TF_IN_AUTOMATION=1 TF_INPUT=0
  export TF_VAR_config_file="$CONFIG_FILE"
  if [ -z "${TF_CLI_CONFIG_FILE:-}" ] && [ -r /etc/terraform.tfrc ]; then
    export TF_CLI_CONFIG_FILE=/etc/terraform.tfrc
  fi
  case ",${NO_PROXY:-}," in
    *",aws,"*) : ;;
    *) export NO_PROXY="${NO_PROXY:+$NO_PROXY,}aws,localhost,127.0.0.1" no_proxy="${NO_PROXY:+$NO_PROXY,}aws,localhost,127.0.0.1" ;;
  esac
}

pick_tool() {
  if command -v terraform >/dev/null 2>&1; then TF="terraform"
  elif command -v tofu >/dev/null 2>&1; then TF="tofu"
  else die "neither terraform nor tofu is installed"; fi
}

# The AWS provider reaches S3 Control through "<account>.<endpoint-host>", which
# does not resolve here. A small local relay serves that virtual host.
start_proxy() {
  local port
  port="$(python3 - <<'PY'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PY
)"
  setsid nohup python3 "$SUB_DIR/scripts/aws_proxy.py" "$port" "$AWS_ENDPOINT" >/dev/null 2>&1 </dev/null &
  PROXY_PID=$!
  local i
  for i in $(seq 1 50); do
    if python3 -c "import socket,sys; socket.create_connection(('127.0.0.1',$port),0.2).close()" 2>/dev/null; then
      export TF_VAR_aws_proxy="http://127.0.0.1:$port"
      return 0
    fi
    sleep 0.1
  done
  die "local AWS relay failed to start"
}

stop_proxy() {
  if [ -n "$PROXY_PID" ]; then
    kill "$PROXY_PID" >/dev/null 2>&1 || true
    PROXY_PID=""
  fi
}

tf() { "$TF" -chdir="$INFRA_DIR" "$@"; }

tf_init() {
  tf init -input=false -no-color -upgrade=false >/dev/null || tf init -input=false -no-color
}

# terraform apply with one retry: the control plane is occasionally slow to settle
tf_apply() {
  local attempt
  for attempt in 1 2 3; do
    if tf apply -input=false -auto-approve -no-color -lock-timeout=60s "$@"; then return 0; fi
    log "terraform apply attempt $attempt failed; retrying"
    sleep 5
  done
  return 1
}
