#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
unset OPENAI_API_KEY

for required_command in symphony codex gh python3.11; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "Required command not found: $required_command" >&2
    exit 1
  fi
done

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
