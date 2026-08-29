#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${INSIGHTKIT_AGENT_PYTHON:-python3.11}"
CHECK_ONLY=0

if [[ "${1:-}" == "--check" ]]; then
  CHECK_ONLY=1
elif [[ $# -gt 0 ]]; then
  echo "Usage: $(basename "$0") [--check]" >&2
  exit 2
fi

for command in git "$PYTHON_BIN"; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required command not found: $command" >&2
    exit 1
  fi
done

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  [[ -x "$ROOT_DIR/.venv/bin/python" ]] || {
    echo "Agent environment missing: run ./scripts/agent_bootstrap.sh" >&2
    exit 1
  }
  "$ROOT_DIR/.venv/bin/python" -c 'import insightkit, pytest'
  echo "Agent bootstrap check passed."
  exit 0
fi

if [[ ! -x "$ROOT_DIR/.venv/bin/python" ]]; then
  "$PYTHON_BIN" -m venv "$ROOT_DIR/.venv"
fi

PIP_DISABLE_PIP_VERSION_CHECK=1 "$ROOT_DIR/.venv/bin/python" -m pip install -e "$ROOT_DIR[dev]"
"$ROOT_DIR/.venv/bin/python" -c 'import insightkit, pytest'
echo "Agent environment ready: $ROOT_DIR/.venv"
