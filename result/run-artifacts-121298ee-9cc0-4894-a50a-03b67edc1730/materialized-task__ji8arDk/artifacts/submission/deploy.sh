#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ROOT="$(dirname "$(readlink -f "$0")")"
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_EC2_METADATA_DISABLED=true
export AWS_ENDPOINT_URL="$(jq -r .aws_endpoint_url /workspace/config/config.json)"
export AWS_REGION="$(jq -r .region /workspace/config/config.json)" AWS_DEFAULT_REGION="$(jq -r .region /workspace/config/config.json)"
export TF_VAR_config="$(jq -c . /workspace/config/config.json)"
exec 9>"$ROOT/.lifecycle.lock"
flock -w 650 9
terraform -chdir="$ROOT/infra" init -input=false -no-color
python3 "$ROOT/ops.py" preflight
terraform -chdir="$ROOT/infra" plan -input=false -no-color -out="$ROOT/infra/deploy.tfplan" >"$ROOT/infra/plan.log"
python3 "$ROOT/ops.py" protect
terraform -chdir="$ROOT/infra" apply -input=false -no-color "$ROOT/infra/deploy.tfplan"
# Refresh once more: the local control plane adds default SG egress during creation.
# A second declarative pass removes those defaults before accepting traffic.
terraform -chdir="$ROOT/infra" plan -input=false -no-color -out="$ROOT/infra/deploy.tfplan" >"$ROOT/infra/plan.log"
python3 "$ROOT/ops.py" protect
terraform -chdir="$ROOT/infra" apply -input=false -no-color "$ROOT/infra/deploy.tfplan"
terraform -chdir="$ROOT/infra" output -json manifest >"$ROOT/manifest.json.tmp"
python3 "$ROOT/ops.py" manifest
mv "$ROOT/manifest.json.tmp" "$ROOT/manifest.json"
python3 "$ROOT/ops.py" converge
