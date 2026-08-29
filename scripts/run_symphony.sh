#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
unset OPENAI_API_KEY

operator_codex_home=${CODEX_HOME:-"$HOME/.codex"}
if [ -n "${SYMPHONY_CODEX_HOME:-}" ]; then
  symphony_codex_home=$SYMPHONY_CODEX_HOME
else
  symphony_codex_home="$HOME/Library/Application Support/InsightKit/SymphonyCodex"
  mkdir -p "$symphony_codex_home"
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

for required_command in symphony codex gh python3.11; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "Required command not found: $required_command" >&2
    exit 1
  fi
done

if ! codex_login_status=$(codex login status 2>/dev/null); then
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

if ! gh auth status >/dev/null 2>&1; then
  echo "Codex's GitHub CLI session is not authenticated. Run: gh auth login" >&2
  exit 1
fi

python3.11 "$repo_root/scripts/agent_harness.py" doctor --profile symphony

GITHUB_TOKEN=$SYMPHONY_GITHUB_TOKEN
export GITHUB_TOKEN

exec symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --port "${SYMPHONY_PORT:-4000}" \
  --logs-root "${SYMPHONY_LOGS_ROOT:-$repo_root/logs/symphony}" \
  "$repo_root/WORKFLOW.md"
