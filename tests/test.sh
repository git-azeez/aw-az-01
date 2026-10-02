#!/usr/bin/env bash
set -Eeuo pipefail

mkdir -p /logs/verifier
printf '{"reward":0,"score":0}\n' > /logs/verifier/reward.json
printf '0\n' > /logs/verifier/reward.txt
echo "Replace tests/test.sh with the task verifier." >&2
exit 1
