#!/bin/sh
set -eu
umask 077

: "${SYMPHONY_CONTROLLER_REPO_ROOT:?SYMPHONY_CONTROLLER_REPO_ROOT is required}"
: "${SYMPHONY_PREFLIGHT_EVIDENCE_ROOT:?SYMPHONY_PREFLIGHT_EVIDENCE_ROOT is required}"
: "${SYMPHONY_PYTHON3:?SYMPHONY_PYTHON3 is required}"
: "${SYMPHONY_REAL_GH:?SYMPHONY_REAL_GH is required}"

issue_identifier=$(basename "$PWD")
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

preflight_path="$SYMPHONY_PREFLIGHT_EVIDENCE_ROOT/$issue_identifier.json"
preflight_tmp="$preflight_path.tmp.$$"
claim_marker="$SYMPHONY_PREFLIGHT_EVIDENCE_ROOT/$issue_identifier.claimed"
claim_marker_tmp="$claim_marker.tmp.$$"
trap 'if [ -f "$preflight_tmp" ]; then unlink "$preflight_tmp"; fi; if [ -f "$claim_marker_tmp" ]; then unlink "$claim_marker_tmp"; fi' EXIT
PATH="$(dirname "$SYMPHONY_REAL_GH"):/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

set +e
if [ -f "$claim_marker" ]; then
  "$SYMPHONY_PYTHON3" "$SYMPHONY_CONTROLLER_REPO_ROOT/scripts/agent_harness.py" \
    issue-preflight --json --issue "$issue_identifier" --resume > "$preflight_tmp"
else
  "$SYMPHONY_PYTHON3" "$SYMPHONY_CONTROLLER_REPO_ROOT/scripts/agent_harness.py" \
    issue-preflight --json --issue "$issue_identifier" > "$preflight_tmp"
fi
preflight_status=$?
set -e
mv "$preflight_tmp" "$preflight_path"
if [ ! -s "$preflight_path" ] || ! "$SYMPHONY_PYTHON3" -c \
  'import json, sys; assert isinstance(json.load(open(sys.argv[1], encoding="utf-8")), dict)' \
  "$preflight_path" >/dev/null 2>&1; then
  printf '{"status":"failed","stage":"preflight","issue":"%s","exit_code":%s}\n' \
    "$issue_identifier" "$preflight_status" > "$preflight_tmp"
  mv "$preflight_tmp" "$preflight_path"
  if [ "$preflight_status" -eq 0 ]; then exit 1; fi
  exit "$preflight_status"
fi
if [ "$preflight_status" -ne 0 ]; then
  exit "$preflight_status"
fi

if [ ! -f "$claim_marker" ]; then
  printf 'pending\n' > "$claim_marker_tmp"
  mv "$claim_marker_tmp" "$claim_marker"
fi

if ! "$SYMPHONY_REAL_GH" issue edit "$issue_number" \
  --repo YannJY02/AutoTranscribe --add-assignee @me; then
  printf '{"status":"failed","stage":"assignment","issue":"%s"}\n' \
    "$issue_identifier" > "$preflight_tmp"
  mv "$preflight_tmp" "$preflight_path"
  exit 1
fi

printf 'claimed\n' > "$claim_marker_tmp"
mv "$claim_marker_tmp" "$claim_marker"
