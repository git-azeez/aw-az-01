#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT="$(dirname "$(readlink -f "$0")")"
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_PAGER=""
export AWS_ENDPOINT_URL="$(jq -r .aws_endpoint_url /workspace/config/config.json)"
export AWS_DEFAULT_REGION="$(jq -r .region /workspace/config/config.json)"
exec 9>"$ROOT/.lifecycle.lock"
flock -w 650 9
python3 "$ROOT/lifecycle.py" prepare
terraform -chdir="$ROOT/infra" init -input=false -no-color
terraform -chdir="$ROOT/infra" plan -input=false -no-color -compact-warnings -var-file=/workspace/config/config.json -out="$ROOT/infra/deploy.tfplan"
python3 "$ROOT/lifecycle.py" checkplan
terraform -chdir="$ROOT/infra" apply -input=false -auto-approve -no-color -compact-warnings "$ROOT/infra/deploy.tfplan"
python3 "$ROOT/lifecycle.py" deploy
