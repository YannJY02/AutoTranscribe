#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${INSIGHTKIT_APP_NAME:-InsightKit}"
APP_BUNDLE_ID="${INSIGHTKIT_BUNDLE_ID:-com.yannjy.insightkit}"
PROCESS_NAME="${INSIGHTKIT_PROCESS_NAME:-InsightKitApp}"
QUIT_TIMEOUT_SEC="${INSIGHTKIT_QUIT_TIMEOUT_SEC:-3}"
TERM_TIMEOUT_SEC="${INSIGHTKIT_TERM_TIMEOUT_SEC:-2}"
SIDECAR_SOCKET="${INSIGHTKIT_SOCKET:-/tmp/insightkit-app-$(id -u).sock}"
SIDECAR_TIMEOUT_SEC="${INSIGHTKIT_SIDECAR_QUIT_TIMEOUT_SEC:-2}"
SIDECAR_PROCESS_PATTERN="${INSIGHTKIT_SIDECAR_PROCESS_PATTERN:-insightkit_runtime/scripts/insight_sidecar.py|/scripts/insight_sidecar.py}"

sidecar_pids() {
  pgrep -f "$SIDECAR_PROCESS_PATTERN" 2>/dev/null || true
}

remove_stale_sidecar_socket_if_needed() {
  if [[ ! -S "$SIDECAR_SOCKET" ]]; then
    return 0
  fi
  if [[ -n "$(sidecar_pids)" ]]; then
    return 0
  fi
  rm -f "$SIDECAR_SOCKET" 2>/dev/null || true
}

request_sidecar_shutdown() {
  if [[ ! -S "$SIDECAR_SOCKET" ]]; then
    return 0
  fi

  python3 -c '
import json
import socket
import sys

sock_path = sys.argv[1]
client = socket.socket(socket.AF_UNIX)
client.settimeout(1)
client.connect(sock_path)
client.sendall((json.dumps({"id": 1, "method": "sidecar.shutdown", "params": {}}) + "\n").encode())
try:
    client.recv(4096)
except socket.timeout:
    pass
' "$SIDECAR_SOCKET" >/dev/null 2>&1 || true
}

stop_sidecar_if_needed() {
  local pids
  pids="$(sidecar_pids | tr '\n' ' ')"
  if [[ -z "${pids// }" ]]; then
    remove_stale_sidecar_socket_if_needed
    return 0
  fi

  request_sidecar_shutdown
  local deadline=$((SECONDS + SIDECAR_TIMEOUT_SEC))
  while [[ -n "$(sidecar_pids)" ]]; do
    if (( SECONDS >= deadline )); then
      break
    fi
    sleep 0.2
  done

  pids="$(sidecar_pids | tr '\n' ' ')"
  if [[ -z "${pids// }" ]]; then
    remove_stale_sidecar_socket_if_needed
    return 0
  fi

  echo "InsightKit sidecar did not quit within ${SIDECAR_TIMEOUT_SEC}s; sending TERM to: ${pids}"
  kill $pids 2>/dev/null || true

  deadline=$((SECONDS + TERM_TIMEOUT_SEC))
  while [[ -n "$(sidecar_pids)" ]]; do
    if (( SECONDS >= deadline )); then
      break
    fi
    sleep 0.2
  done

  pids="$(sidecar_pids | tr '\n' ' ')"
  if [[ -z "${pids// }" ]]; then
    remove_stale_sidecar_socket_if_needed
    return 0
  fi

  echo "InsightKit sidecar ignored TERM; sending KILL to: ${pids}"
  kill -9 $pids 2>/dev/null || true
  remove_stale_sidecar_socket_if_needed
}

if ! pgrep -x "$PROCESS_NAME" >/dev/null 2>&1; then
  stop_sidecar_if_needed
  echo "InsightKit is not running; sidecar checked."
  exit 0
fi

if osascript -e "with timeout of ${QUIT_TIMEOUT_SEC} seconds" \
  -e "tell application id \"${APP_BUNDLE_ID}\" to quit" \
  -e "end timeout" >/dev/null 2>&1 \
  || osascript -e "with timeout of ${QUIT_TIMEOUT_SEC} seconds" \
    -e "tell application \"${APP_NAME}\" to quit" \
    -e "end timeout" >/dev/null 2>&1; then
  deadline=$((SECONDS + QUIT_TIMEOUT_SEC))
  while pgrep -x "$PROCESS_NAME" >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      break
    fi
    sleep 0.2
  done
fi

if ! pgrep -x "$PROCESS_NAME" >/dev/null 2>&1; then
  stop_sidecar_if_needed
  echo "InsightKit quit cleanly."
  exit 0
fi

pids="$(pgrep -x "$PROCESS_NAME" | tr '\n' ' ')"
echo "InsightKit did not quit within ${QUIT_TIMEOUT_SEC}s; sending TERM to: ${pids}"
kill $pids 2>/dev/null || true

deadline=$((SECONDS + TERM_TIMEOUT_SEC))
while pgrep -x "$PROCESS_NAME" >/dev/null 2>&1; do
  if (( SECONDS >= deadline )); then
    break
  fi
  sleep 0.2
done

if ! pgrep -x "$PROCESS_NAME" >/dev/null 2>&1; then
  stop_sidecar_if_needed
  echo "InsightKit stopped after TERM."
  exit 0
fi

pids="$(pgrep -x "$PROCESS_NAME" | tr '\n' ' ')"
echo "InsightKit ignored TERM; sending KILL to: ${pids}"
kill -9 $pids 2>/dev/null || true

if pgrep -x "$PROCESS_NAME" >/dev/null 2>&1; then
  echo "InsightKit is still running after KILL." >&2
  exit 1
fi

stop_sidecar_if_needed
echo "InsightKit stopped after KILL."
