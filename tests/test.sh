#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="/opt/venv/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_ENDPOINT_URL="${AWS_ENDPOINT_URL:-http://aws:4566}"
export TF_CLI_CONFIG_FILE="${TF_CLI_CONFIG_FILE:-/etc/terraform.tfrc}"

mkdir -p /logs/verifier /workspace/evidence
chmod -R a+rwX /workspace/submission /workspace/evidence /logs/verifier 2>/dev/null || true
chmod +x /workspace/submission/deploy.sh /workspace/submission/destroy.sh 2>/dev/null || true

echo "0" >/logs/verifier/reward.txt
echo '{"reward":0.0,"score":0}' >/logs/verifier/reward.json

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

if [[ -s /logs/verifier/reward.json ]] && jq -e '(.reward | type) == "number" and (.score | type) == "number"' /logs/verifier/reward.json >/dev/null 2>&1; then
  exit 0
fi

exit "${PYTEST_RC}"
