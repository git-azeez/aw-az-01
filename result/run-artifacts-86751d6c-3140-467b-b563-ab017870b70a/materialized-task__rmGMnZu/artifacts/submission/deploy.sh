#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT="$(dirname "$(readlink -f "$0")")"
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_EC2_METADATA_DISABLED=true
export AWS_REGION="$(jq -r .region /workspace/config/config.json)"
export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_ENDPOINT_URL="$(jq -r .aws_endpoint_url /workspace/config/config.json)"
exec 9>"$ROOT/.lifecycle.lock"
flock -w 30 9
python3 "$ROOT/operations.py" dependencies
terraform -chdir="$ROOT/infra" init -input=false -no-color
python3 "$ROOT/operations.py" policies
# A saved plan lets us refuse accidental replacement of authoritative stores.
terraform -chdir="$ROOT/infra" plan -input=false -no-color -out=deploy.tfplan
python3 "$ROOT/operations.py" protect
terraform -chdir="$ROOT/infra" apply -input=false -no-color deploy.tfplan
python3 "$ROOT/operations.py" manifest
python3 "$ROOT/operations.py" guardrails
python3 "$ROOT/operations.py" migrate
python3 "$ROOT/operations.py" ready
python3 "$ROOT/operations.py" reconcile
python3 "$ROOT/operations.py" ready
