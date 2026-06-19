#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SCRIPT="$ROOT_DIR/scripts/dev_build_xcode_debug_app.sh"
DERIVED_DATA_PATH="${INSIGHTKIT_XCODE_DERIVED_DATA:-/private/tmp/insightkit-xcode-dev}"
CONFIGURATION="${INSIGHTKIT_XCODE_CONFIGURATION:-Debug}"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/InsightKitApp.app"
SHOULD_BUILD=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Open the Xcode Debug app built by dev_build_xcode_debug_app.sh.

Options:
  --build              Build before opening
  --derived-data PATH  DerivedData path (default: $DERIVED_DATA_PATH)
  -h, --help           Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build)
      SHOULD_BUILD=1
      shift
      ;;
    --derived-data)
      DERIVED_DATA_PATH="${2:?missing path after --derived-data}"
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

APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/InsightKitApp.app"

if [[ "$SHOULD_BUILD" == "1" || ! -d "$APP_PATH" ]]; then
  "$BUILD_SCRIPT" --derived-data "$DERIVED_DATA_PATH"
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "Debug app not found: $APP_PATH" >&2
  exit 1
fi

echo "Opening debug app: $APP_PATH"
open "$APP_PATH"
