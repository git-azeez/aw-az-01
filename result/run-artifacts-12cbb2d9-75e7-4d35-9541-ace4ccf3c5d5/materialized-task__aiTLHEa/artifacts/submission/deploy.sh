#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ROOT="$(dirname "$(readlink -f "$0")")"
export TF_VAR_config="$(jq -c . /workspace/config/config.json)"
export AWS_ENDPOINT_URL="$(jq -r .aws_endpoint_url /workspace/config/config.json)"
export AWS_DEFAULT_REGION="$(jq -r .region /workspace/config/config.json)"
export AWS_REGION="$AWS_DEFAULT_REGION" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test
export AWS_EC2_METADATA_DISABLED=true TF_IN_AUTOMATION=1
exec 9>"$ROOT/.lifecycle.lock"
flock -w 600 9
LOG="$ROOT/infra/deploy.log"
python3 "$ROOT/operations.py" active-prefix
terraform -chdir="$ROOT/infra" init -input=false -no-color >"$LOG" 2>&1
printf 'Planning and applying ClearLedger infrastructure.\n'
python3 "$ROOT/operations.py" policies
terraform -chdir="$ROOT/infra" plan -input=false -no-color -out="$ROOT/infra/deploy.plan" >>"$LOG" 2>&1
terraform -chdir="$ROOT/infra" show -json "$ROOT/infra/deploy.plan" >"$ROOT/infra/deploy.plan.json"
python3 "$ROOT/operations.py" protect
if ! python3 "$ROOT/terraform_runner.py" "$LOG" apply -input=false -no-color "$ROOT/infra/deploy.plan"; then
  printf 'Terraform apply failed; see %s\n' "$LOG" >&2
  exit 1
fi
rm -f "$ROOT/infra/deploy.plan" "$ROOT/infra/deploy.plan.json"
terraform -chdir="$ROOT/infra" output -json manifest >"$ROOT/manifest.json.tmp"
python3 "$ROOT/operations.py" validate "$ROOT/manifest.json.tmp"
mv "$ROOT/manifest.json.tmp" "$ROOT/manifest.json"
python3 "$ROOT/operations.py" schema
python3 "$ROOT/operations.py" reconcile
python3 "$ROOT/operations.py" ready
printf 'ClearLedger deployed and reconciled. Manifest: %s/manifest.json\n' "$ROOT"
