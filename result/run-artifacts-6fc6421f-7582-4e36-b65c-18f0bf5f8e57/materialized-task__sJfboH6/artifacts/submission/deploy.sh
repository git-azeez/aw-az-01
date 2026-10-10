#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ROOT="$(dirname "$(readlink -f "$0")")"
export CLEARLEDGER_CONFIG="${CLEARLEDGER_CONFIG:-/workspace/config/config.json}"
export TF_VAR_config_path="$CLEARLEDGER_CONFIG"
export AWS_ENDPOINT_URL="$(jq -er .aws_endpoint_url "$CLEARLEDGER_CONFIG")"
export AWS_DEFAULT_REGION="$(jq -er .region "$CLEARLEDGER_CONFIG")"
export AWS_REGION="$AWS_DEFAULT_REGION" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_EC2_METADATA_DISABLED=true
exec 9>"$ROOT/.lifecycle.lock"
flock -w 30 9
python3 "$ROOT/operations.py" preflight
terraform -chdir="$ROOT/infra" init -input=false -no-color
trap 'rm -f "$ROOT/infra/deployment.tfplan" "$ROOT/infra/deployment.plan.json"' EXIT
terraform -chdir="$ROOT/infra" plan -input=false -no-color -out=deployment.tfplan
terraform -chdir="$ROOT/infra" show -json deployment.tfplan > "$ROOT/infra/deployment.plan.json"
python3 "$ROOT/operations.py" preserve
terraform -chdir="$ROOT/infra" apply -input=false -auto-approve -no-color deployment.tfplan
terraform -chdir="$ROOT/infra" output -json manifest > "$ROOT/manifest.json.tmp"
python3 "$ROOT/operations.py" manifest "$ROOT/manifest.json.tmp"
mv "$ROOT/manifest.json.tmp" "$ROOT/manifest.json"
python3 "$ROOT/operations.py" network-hygiene
python3 "$ROOT/operations.py" schema
python3 "$ROOT/operations.py" ready
python3 "$ROOT/operations.py" reconcile
python3 "$ROOT/operations.py" ready
