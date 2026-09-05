#!/bin/sh
set -eu
umask 077

: "${SYMPHONY_CONTROLLER_REPO_ROOT:?SYMPHONY_CONTROLLER_REPO_ROOT is required}"
: "${SYMPHONY_PREFLIGHT_EVIDENCE_ROOT:?SYMPHONY_PREFLIGHT_EVIDENCE_ROOT is required}"
: "${SYMPHONY_PYTHON3:?SYMPHONY_PYTHON3 is required}"
: "${SYMPHONY_REAL_GH:?SYMPHONY_REAL_GH is required}"
: "${SYMPHONY_SECURITY:?SYMPHONY_SECURITY is required}"
unset GH_TOKEN SYMPHONY_AGENT_GITHUB_TOKEN

if [ "$#" -eq 1 ] && [ "$1" = --blocked-sweep ]; then
  : "${SYMPHONY_WORKSPACE_ROOT:?SYMPHONY_WORKSPACE_ROOT is required}"
  cd "$SYMPHONY_CONTROLLER_REPO_ROOT"
  pending_status=0
  "$SYMPHONY_PYTHON3" \
    "$SYMPHONY_CONTROLLER_REPO_ROOT/scripts/symphony_delivery_controller.py" \
    --preflight-root "$SYMPHONY_PREFLIGHT_EVIDENCE_ROOT" \
    --gh "$SYMPHONY_REAL_GH" \
    blocked-pending --workspace-root "$SYMPHONY_WORKSPACE_ROOT" || pending_status=$?
  case "$pending_status" in
    0) ;;
    3) exit 0 ;;
    *) exit "$pending_status" ;;
  esac
  set -- blocked-sweep --workspace-root "$SYMPHONY_WORKSPACE_ROOT"
elif [ "$#" -eq 0 ]; then
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
  set -- after-run --workspace "$workspace"
else
  echo "Usage: symphony_after_run.sh [--blocked-sweep]" >&2
  exit 2
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
  "$@"
