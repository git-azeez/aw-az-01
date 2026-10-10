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
LOG="$ROOT/infra/destroy.log"
python3 "$ROOT/operations.py" active-prefix
terraform -chdir="$ROOT/infra" init -input=false -no-color >"$LOG" 2>&1
python3 "$ROOT/operations.py" policies
python3 "$ROOT/teardown.py" extras
printf 'Destroying ClearLedger infrastructure.\n'
if ! python3 "$ROOT/terraform_runner.py" "$LOG" destroy -auto-approve -input=false -no-color; then
  printf 'Terraform destroy failed; see %s\n' "$LOG" >&2
  exit 1
fi
python3 "$ROOT/teardown.py" all
python3 "$ROOT/teardown.py" verify
rm -f "$ROOT/infra/deploy.plan" "$ROOT/infra/deploy.plan.json"
printf 'ClearLedger teardown complete; managed state is empty.\n'
