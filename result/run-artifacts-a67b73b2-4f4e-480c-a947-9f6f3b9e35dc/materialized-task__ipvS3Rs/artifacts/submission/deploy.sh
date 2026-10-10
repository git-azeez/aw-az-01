#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ROOT="$(dirname "$(readlink -f "$0")")"
export CLEARLEDGER_CONFIG="${CLEARLEDGER_CONFIG:-/workspace/config/config.json}"
export TF_VAR_config_path="$CLEARLEDGER_CONFIG"
export AWS_ENDPOINT_URL="$(jq -er .aws_endpoint_url "$CLEARLEDGER_CONFIG")"
export AWS_REGION="$(jq -er .region "$CLEARLEDGER_CONFIG")"
export AWS_DEFAULT_REGION="$AWS_REGION" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_EC2_METADATA_DISABLED=true
exec 9>"$ROOT/.lifecycle.lock"
flock -w 650 9
python3 "$ROOT/lifecycle.py" guard
terraform -chdir="$ROOT/infra" init -input=false -no-color
python3 "$ROOT/lifecycle.py" repair
terraform -chdir="$ROOT/infra" plan -input=false -no-color -out="$ROOT/infra/deploy.tfplan"
python3 "$ROOT/lifecycle.py" protect
terraform -chdir="$ROOT/infra" apply -input=false -no-color "$ROOT/infra/deploy.tfplan"
python3 "$ROOT/lifecycle.py" manifest
python3 "$ROOT/lifecycle.py" schema
python3 "$ROOT/lifecycle.py" ready
python3 "$ROOT/lifecycle.py" reconcile
python3 "$ROOT/lifecycle.py" ready
