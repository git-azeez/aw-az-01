#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_ENDPOINT_URL="${AWS_ENDPOINT_URL:-http://aws:4566}"
export TF_CLI_CONFIG_FILE="${TF_CLI_CONFIG_FILE:-/etc/terraform.tfrc}"

mkdir -p /logs/verifier /workspace/evidence

echo "0" >/logs/verifier/reward.txt

pytest -q \
  "${SCRIPT_DIR}/suite/test_declared.py" \
  "${SCRIPT_DIR}/suite/test_live.py" \
  "${SCRIPT_DIR}/suite/test_behavior.py" \
  "${SCRIPT_DIR}/suite/test_lifecycle.py" \
  -o cache_dir=/tmp/pytest_cache \
  --junitxml=/logs/verifier/junit.xml
PYTEST_RC=$?

if [[ -f /logs/verifier/results.json ]]; then
  cp /logs/verifier/results.json /workspace/evidence/verifier_results.json || true
fi

exit "${PYTEST_RC}"
