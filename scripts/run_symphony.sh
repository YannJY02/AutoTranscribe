#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
unset OPENAI_API_KEY
symphony_preflight_timeout_seconds=${SYMPHONY_PREFLIGHT_TIMEOUT_SECONDS:-60}
case "$symphony_preflight_timeout_seconds" in
  ''|*[!0-9]*)
    echo "SYMPHONY_PREFLIGHT_TIMEOUT_SECONDS must be a positive integer." >&2
    exit 1
    ;;
esac
if [ "$symphony_preflight_timeout_seconds" -eq 0 ]; then
  echo "SYMPHONY_PREFLIGHT_TIMEOUT_SECONDS must be a positive integer." >&2
  exit 1
fi
run_with_preflight_timeout() {
  python3.11 - "$symphony_preflight_timeout_seconds" "$@" <<'PY'
import os
import signal
import subprocess
import sys
import time

process = subprocess.Popen(sys.argv[2:], start_new_session=True)
try:
    raise SystemExit(process.wait(timeout=int(sys.argv[1])))
except subprocess.TimeoutExpired:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    time.sleep(1)
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()
    raise SystemExit(124)
PY
}

operator_codex_home=${CODEX_HOME:-"$HOME/.codex"}
if [ -n "${SYMPHONY_CODEX_HOME:-}" ]; then
  symphony_codex_home=$SYMPHONY_CODEX_HOME
else
  symphony_codex_home="$HOME/Library/Application Support/InsightKit/SymphonyCodex"
  mkdir -p "$symphony_codex_home"
  chmod 700 "$symphony_codex_home"
  symphony_auth="$symphony_codex_home/auth.json"
  operator_auth="$operator_codex_home/auth.json"
  if [ -L "$symphony_auth" ] && [ "$(readlink "$symphony_auth")" != "$operator_auth" ]; then
    echo "Symphony Codex auth must link to: $operator_auth" >&2
    exit 1
  fi
  if [ -e "$symphony_auth" ] && [ ! -L "$symphony_auth" ]; then
    echo "Symphony Codex auth must be a link, not a copied file: $symphony_auth" >&2
    exit 1
  fi
  if [ ! -L "$symphony_auth" ]; then
    if [ ! -r "$operator_auth" ]; then
      echo "Codex ChatGPT login is required at: $operator_auth" >&2
      exit 1
    fi
    ln -s "$operator_auth" "$symphony_auth"
  fi
  runtime_config="$symphony_codex_home/config.toml"
  if [ -d "$runtime_config" ]; then
    echo "Symphony Codex config path is a directory: $runtime_config" >&2
    exit 1
  fi
  runtime_config_tmp="$runtime_config.tmp.$$"
  cp "$repo_root/.codex/symphony.config.toml" "$runtime_config_tmp"
  mv -f "$runtime_config_tmp" "$runtime_config"
fi

if [ ! -r "$symphony_codex_home/auth.json" ]; then
  echo "Symphony Codex home has no readable ChatGPT login: $symphony_codex_home/auth.json" >&2
  exit 1
fi
CODEX_HOME=$symphony_codex_home
export CODEX_HOME

for required_command in symphony codex curl gh python3.11; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "Required command not found: $required_command" >&2
    exit 1
  fi
done
symphony_real_codex=$(command -v codex)
SYMPHONY_REAL_CODEX=$symphony_real_codex
export SYMPHONY_REAL_CODEX
SYMPHONY_REAL_GH=${SYMPHONY_REAL_GH:-$(command -v gh)}
SYMPHONY_PYTHON3=${SYMPHONY_PYTHON3:-$(command -v python3.11)}
SYMPHONY_CONTROLLER_REPO_ROOT=$repo_root
export SYMPHONY_REAL_GH SYMPHONY_PYTHON3 SYMPHONY_CONTROLLER_REPO_ROOT

if ! codex_login_status=$(run_with_preflight_timeout codex login status 2>&1); then
  echo "Symphony Codex home does not contain a valid ChatGPT login: $symphony_codex_home/auth.json" >&2
  exit 1
fi
case "$codex_login_status" in
  *"Logged in using ChatGPT"*) ;;
  *)
    echo "Symphony requires ChatGPT login; API-key authentication is not allowed." >&2
    exit 1
    ;;
esac
unset codex_login_status

eval "$(python3.11 "$repo_root/scripts/harness_maintenance.py" proxy-environment)"
if [ -z "${SSL_CERT_FILE:-}" ] && [ -r /etc/ssl/cert.pem ]; then
  SSL_CERT_FILE=/etc/ssl/cert.pem
  export SSL_CERT_FILE
fi

if [ -z "${SYMPHONY_GITHUB_TOKEN:-}" ] && command -v security >/dev/null 2>&1; then
  SYMPHONY_GITHUB_TOKEN=$(security find-generic-password \
    -a symphony \
    -s com.autotranscribe.symphony.github-token \
    -w 2>/dev/null || true)
fi

if [ -z "${SYMPHONY_GITHUB_TOKEN:-}" ]; then
  echo "SYMPHONY_GITHUB_TOKEN is required in the environment or macOS Keychain; use a dedicated fine-grained token with read-only Issues and metadata access." >&2
  exit 1
fi

symphony_agent_github_token=${SYMPHONY_AGENT_GITHUB_TOKEN:-}
if [ -z "$symphony_agent_github_token" ]; then
  symphony_agent_github_token=$(/usr/bin/security find-generic-password \
    -a symphony-agent \
    -s com.autotranscribe.symphony.agent-github-token \
    -w 2>/dev/null || true)
fi
if [ -z "$symphony_agent_github_token" ]; then
  echo "Symphony agent GitHub credential is required in macOS Keychain." >&2
  exit 1
fi
GH_TOKEN=$symphony_agent_github_token
export GH_TOKEN
unset SYMPHONY_AGENT_GITHUB_TOKEN symphony_agent_github_token

if ! run_with_preflight_timeout gh auth status >/dev/null 2>&1; then
  echo "Codex's GitHub CLI session is not authenticated. Run: gh auth login" >&2
  exit 1
fi

python3.11 "$repo_root/scripts/agent_harness.py" doctor --profile symphony

GITHUB_TOKEN=$SYMPHONY_GITHUB_TOKEN
export GITHUB_TOKEN
SYMPHONY_PREFLIGHT_EVIDENCE_ROOT=${SYMPHONY_PREFLIGHT_EVIDENCE_ROOT:-"$repo_root/logs/symphony/preflight"}
mkdir -p "$SYMPHONY_PREFLIGHT_EVIDENCE_ROOT"
chmod 700 "$SYMPHONY_PREFLIGHT_EVIDENCE_ROOT"
export SYMPHONY_PREFLIGHT_EVIDENCE_ROOT

symphony_port=${SYMPHONY_PORT:-4000}
symphony_health_startup_seconds=${SYMPHONY_HEALTH_STARTUP_SECONDS:-180}
symphony_health_interval_seconds=${SYMPHONY_HEALTH_INTERVAL_SECONDS:-60}
symphony_health_timeout_seconds=${SYMPHONY_HEALTH_TIMEOUT_SECONDS:-10}
symphony_health_failure_limit=${SYMPHONY_HEALTH_FAILURE_LIMIT:-3}
symphony_termination_grace_seconds=${SYMPHONY_TERMINATION_GRACE_SECONDS:-5}

case "$symphony_port" in
  ''|*[!0-9]*)
    echo "SYMPHONY_PORT must be an integer from 1 to 65535." >&2
    exit 1
    ;;
esac
if [ "$symphony_port" -lt 1 ] || [ "$symphony_port" -gt 65535 ]; then
  echo "SYMPHONY_PORT must be an integer from 1 to 65535." >&2
  exit 1
fi
case "$symphony_health_startup_seconds" in
  ''|.|*[!0-9.]*|*.*.*)
    echo "SYMPHONY_HEALTH_STARTUP_SECONDS must be a non-negative number." >&2
    exit 1
    ;;
esac
for positive_health_integer in \
  "$symphony_health_interval_seconds" \
  "$symphony_health_timeout_seconds"; do
  case "$positive_health_integer" in
    ''|*[!0-9]*)
      echo "Symphony health interval and timeout must be positive integers." >&2
      exit 1
      ;;
  esac
  if [ "$positive_health_integer" -eq 0 ]; then
    echo "Symphony health interval and timeout must be positive integers." >&2
    exit 1
  fi
done
case "$symphony_health_failure_limit" in
  ''|*[!0-9]*)
    echo "SYMPHONY_HEALTH_FAILURE_LIMIT must be a positive integer." >&2
    exit 1
    ;;
esac
if [ "$symphony_health_failure_limit" -eq 0 ]; then
  echo "SYMPHONY_HEALTH_FAILURE_LIMIT must be a positive integer." >&2
  exit 1
fi
case "$symphony_termination_grace_seconds" in
  ''|*[!0-9]*)
    echo "SYMPHONY_TERMINATION_GRACE_SECONDS must be a non-negative integer." >&2
    exit 1
    ;;
esac

symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --port "$symphony_port" \
  --logs-root "${SYMPHONY_LOGS_ROOT:-$repo_root/logs/symphony}" \
  "$repo_root/WORKFLOW.md" &
symphony_pid=$!

symphony_is_running() {
  symphony_state=$(ps -p "$symphony_pid" -o state= 2>/dev/null || true)
  case "$symphony_state" in
    ''|*[Zz]*) return 1 ;;
    *) return 0 ;;
  esac
}

cleanup_symphony() {
  if symphony_is_running; then
    kill "$symphony_pid" 2>/dev/null || true
    symphony_termination_waited=0
    while symphony_is_running && \
      [ "$symphony_termination_waited" -lt "$symphony_termination_grace_seconds" ]; do
      sleep 1
      symphony_termination_waited=$((symphony_termination_waited + 1))
    done
    if symphony_is_running; then
      kill -KILL "$symphony_pid" 2>/dev/null || true
    fi
  fi
  wait "$symphony_pid" 2>/dev/null || true
}
terminate_symphony() {
  trap - EXIT HUP INT TERM
  cleanup_symphony
  exit 143
}
trap cleanup_symphony EXIT
trap terminate_symphony HUP INT TERM

sleep "$symphony_health_startup_seconds"
symphony_health_failures=0
# ponytail: process-wide restart; use a control-plane probe if Symphony exposes one.
while symphony_is_running; do
  if curl \
    --silent \
    --show-error \
    --fail \
    --max-time "$symphony_health_timeout_seconds" \
    "http://127.0.0.1:$symphony_port/api/v1/state" \
    >/dev/null; then
    symphony_health_failures=0
  else
    symphony_health_failures=$((symphony_health_failures + 1))
    if [ "$symphony_health_failures" -ge "$symphony_health_failure_limit" ]; then
      echo "Symphony health probe failed $symphony_health_failures consecutive times; stopping child for LaunchAgent restart." >&2
      exit 1
    fi
  fi
  sleep "$symphony_health_interval_seconds"
done

set +e
wait "$symphony_pid"
symphony_status=$?
set -e
trap - EXIT HUP INT TERM
exit "$symphony_status"
