#!/usr/bin/env bash
set -euo pipefail

LAST="${INSIGHTKIT_LOG_LAST:-10m}"
OUTPUT=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Capture recent InsightKit unified logs with a bounded query.

Options:
  --last DURATION  Time window for log show, for example 5m or 1h (default: $LAST)
  --output PATH    Write logs to PATH instead of stdout
  -h, --help       Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --last)
      LAST="${2:?missing duration after --last}"
      shift 2
      ;;
    --output)
      OUTPUT="${2:?missing path after --output}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

PREDICATE='process == "InsightKitApp" OR eventMessage CONTAINS "InsightKit" OR eventMessage CONTAINS "insight_sidecar"'

if [[ -n "$OUTPUT" ]]; then
  /usr/bin/log show --style compact --last "$LAST" --predicate "$PREDICATE" > "$OUTPUT"
  echo "Wrote logs: $OUTPUT"
else
  /usr/bin/log show --style compact --last "$LAST" --predicate "$PREDICATE"
fi
