#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT="$(dirname "$(readlink -f "$0")")"
exec 9>"$ROOT/.lifecycle.lock"
flock -w 700 9
exec python3 "$ROOT/lifecycle.py" deploy
