#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT="$(dirname "$(readlink -f "$0")")"
exec 9>"$ROOT/.lifecycle.lock"
flock -w 860 9
exec timeout --foreground 890 python3 "$ROOT/ops.py" destroy
