#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
package_dir="$repo_root/macos/LiveDiarizationWorker"
configuration="${1:-release}"
case "$configuration" in
    debug|release) ;;
    *) printf 'Usage: %s [debug|release]\n' "$0" >&2; exit 2 ;;
esac

xcrun swift build --package-path "$package_dir" --configuration "$configuration" \
    --jobs 4 --product InsightKitLiveDiarization >&2
binary_dir="$(xcrun swift build --package-path "$package_dir" \
    --configuration "$configuration" --show-bin-path)"
printf '%s\n' "$binary_dir/InsightKitLiveDiarization"
