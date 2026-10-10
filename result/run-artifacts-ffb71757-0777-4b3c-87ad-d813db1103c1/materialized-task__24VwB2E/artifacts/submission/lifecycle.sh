# Shared progress reporting for bounded, quiet Terraform operations.
run_logged() {
  local log="$1" label="$2" pid status=0
  shift 2
  "$@" >"$log" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    sleep 10
    if kill -0 "$pid" 2>/dev/null; then
      printf '%s is running; detailed output: %s\n' "$label" "$log"
    fi
  done
  wait "$pid" || status=$?
  if (( status != 0 )); then
    cat "$log"
  fi
  return "$status"
}
