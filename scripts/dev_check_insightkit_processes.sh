#!/usr/bin/env bash
set -euo pipefail

SIDECAR_SOCKET="${INSIGHTKIT_SOCKET:-/tmp/insightkit-app-$(id -u).sock}"
APP_PROCESS_NAME="${INSIGHTKIT_PROCESS_NAME:-InsightKitApp}"
SIDECAR_PROCESS_PATTERN="${INSIGHTKIT_SIDECAR_PROCESS_PATTERN:-insightkit_runtime/scripts/insight_sidecar.py|/scripts/insight_sidecar.py}"

print_processes() {
  local pids
  pids="$1"
  if [[ -z "${pids//[$'\n'[:space:]]/}" ]]; then
    return 0
  fi

  local pid_csv
  pid_csv="$(echo "$pids" | paste -sd, -)"
  ps -o pid=,ppid=,comm=,args= -p "$pid_csv" || true
}

echo "==> InsightKitApp processes"
print_processes "$(pgrep -x "$APP_PROCESS_NAME" 2>/dev/null || true)"

echo "==> InsightKit sidecar processes"
print_processes "$(pgrep -f "$SIDECAR_PROCESS_PATTERN" 2>/dev/null || true)"

echo "==> Sidecar socket"
if [[ -S "$SIDECAR_SOCKET" ]]; then
  ls -l "$SIDECAR_SOCKET"
else
  echo "No socket: $SIDECAR_SOCKET"
fi
