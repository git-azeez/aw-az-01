#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT="$(dirname "$(readlink -f "$0")")"
exec 9>"$ROOT/.lifecycle.lock"
flock -w 680 9
exec timeout --foreground 710 python3 "$ROOT/ops.py" deploy
