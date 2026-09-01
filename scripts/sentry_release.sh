#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <version> <build> <path-to-dSYM>" >&2
  exit 64
fi

: "${SENTRY_AUTH_TOKEN:?SENTRY_AUTH_TOKEN must be supplied outside the repository}"
: "${SENTRY_ORG:?SENTRY_ORG must be supplied}"
: "${SENTRY_PROJECT:?SENTRY_PROJECT must be supplied}"
command -v sentry-cli >/dev/null || { echo "sentry-cli is required" >&2; exit 69; }

version="$1"
build="$2"
dsym_path="$3"
release="com.yannjy.insightkit@${version}+${build}"

[[ "$version" =~ ^[0-9]{1,4}\.[0-9]{1,4}(\.[0-9]{1,4})?$ ]] || { echo "invalid version" >&2; exit 64; }
[[ "$build" =~ ^[0-9]{1,14}$ ]] || { echo "invalid build" >&2; exit 64; }
[[ -d "$dsym_path" ]] || { echo "dSYM directory not found" >&2; exit 66; }

sentry-cli releases new "$release" 2>/dev/null || sentry-cli releases info "$release" >/dev/null
sentry-cli debug-files upload "$dsym_path"
sentry-cli releases finalize "$release"
