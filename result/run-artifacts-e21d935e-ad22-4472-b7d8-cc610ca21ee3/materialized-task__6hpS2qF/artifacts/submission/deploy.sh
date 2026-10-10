#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT="$(dirname "$(readlink -f "$0")")"
exec 9>"$ROOT/.lifecycle.lock"
flock -w 650 9
export TF_IN_AUTOMATION=1 TF_INPUT=0
export TF_VAR_config="$(jq -c . /workspace/config/config.json)"
export AWS_ENDPOINT_URL="$(jq -r .aws_endpoint_url /workspace/config/config.json)"
export AWS_DEFAULT_REGION="$(jq -r .region /workspace/config/config.json)"
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_EC2_METADATA_DISABLED=true
ENGINE="${TF_ENGINE:-terraform}"
python3 "$ROOT/ops.py" preflight
"$ENGINE" -chdir="$ROOT/infra" init -no-color
"$ENGINE" -chdir="$ROOT/infra" plan -out=deployment.plan -no-color -compact-warnings
"$ENGINE" -chdir="$ROOT/infra" show -json deployment.plan > "$ROOT/infra/deployment.plan.json"
python3 "$ROOT/ops.py" guard-plan
"$ENGINE" -chdir="$ROOT/infra" apply -auto-approve -no-color -compact-warnings deployment.plan
"$ENGINE" -chdir="$ROOT/infra" output -json manifest > "$ROOT/manifest.json.tmp"
python3 "$ROOT/ops.py" manifest
mv "$ROOT/manifest.json.tmp" "$ROOT/manifest.json"
python3 "$ROOT/ops.py" clean-plan
python3 "$ROOT/ops.py" schema
python3 "$ROOT/ops.py" reconcile
python3 "$ROOT/ops.py" ready
