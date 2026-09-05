#!/bin/sh
set -eu
umask 077

: "${SYMPHONY_CONTROLLER_REPO_ROOT:?SYMPHONY_CONTROLLER_REPO_ROOT is required}"
: "${SYMPHONY_PREFLIGHT_EVIDENCE_ROOT:?SYMPHONY_PREFLIGHT_EVIDENCE_ROOT is required}"
: "${SYMPHONY_PYTHON3:?SYMPHONY_PYTHON3 is required}"
: "${SYMPHONY_REAL_GH:?SYMPHONY_REAL_GH is required}"
: "${SYMPHONY_SECURITY:?SYMPHONY_SECURITY is required}"

workspace=$(pwd -P)
issue_identifier=$(basename "$workspace")
issue_number=${issue_identifier#GH-}
case "$issue_identifier" in
  GH-*) ;;
  *)
    echo "Symphony workspace does not identify a GitHub issue: $issue_identifier" >&2
    exit 1
    ;;
esac
case "$issue_number" in
  ''|*[!0-9]*)
    echo "Symphony workspace does not identify a GitHub issue: $issue_identifier" >&2
    exit 1
    ;;
esac
if [ ! -f "$workspace/.symphony/handoff.json" ]; then
  exit 0
fi

# Worker evidence is advisory. Never execute worker tests or its Python runtime
# here: isolated GitHub CI is the authoritative recheck before human handoff.
cd "$SYMPHONY_CONTROLLER_REPO_ROOT"

controller_token=$("$SYMPHONY_SECURITY" find-generic-password \
  -a symphony-agent \
  -s com.autotranscribe.symphony.agent-github-token \
  -w 2>/dev/null || true)
trap 'unset controller_token GH_TOKEN' EXIT HUP INT TERM
if [ -z "$controller_token" ]; then
  echo "Symphony controller GitHub credential is required in macOS Keychain." >&2
  exit 1
fi

GH_TOKEN=$controller_token "$SYMPHONY_PYTHON3" \
  "$SYMPHONY_CONTROLLER_REPO_ROOT/scripts/symphony_delivery_controller.py" \
  --preflight-root "$SYMPHONY_PREFLIGHT_EVIDENCE_ROOT" \
  --gh "$SYMPHONY_REAL_GH" \
  after-run \
  --workspace "$workspace"
