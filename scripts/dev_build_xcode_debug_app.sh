#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/macos/InsightKitApp"
XCODEPROJ="$PROJECT_DIR/InsightKitUITestHost.xcodeproj"
SCHEME="${INSIGHTKIT_XCODE_SCHEME:-InsightKitApp}"
CONFIGURATION="${INSIGHTKIT_XCODE_CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="${INSIGHTKIT_XCODE_DERIVED_DATA:-/private/tmp/insightkit-xcode-dev}"
DESTINATION="${INSIGHTKIT_XCODE_DESTINATION:-platform=macOS}"
XCODEBUILD="${INSIGHTKIT_XCODEBUILD:-/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild}"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/InsightKitApp.app"
VERIFY_CODESIGN="${INSIGHTKIT_DEV_VERIFY_CODESIGN:-1}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Build the InsightKit XcodeGen Debug app without installing or packaging it.

Options:
  --derived-data PATH   DerivedData output path (default: $DERIVED_DATA_PATH)
  --configuration NAME  Xcode configuration (default: $CONFIGURATION)
  --scheme NAME         Xcode scheme (default: $SCHEME)
  --no-codesign-check   Skip strict codesign verification after build
  -h, --help            Show this help

Output app:
  $APP_PATH
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --derived-data)
      DERIVED_DATA_PATH="${2:?missing path after --derived-data}"
      shift 2
      ;;
    --configuration)
      CONFIGURATION="${2:?missing name after --configuration}"
      shift 2
      ;;
    --scheme)
      SCHEME="${2:?missing name after --scheme}"
      shift 2
      ;;
    --no-codesign-check)
      VERIFY_CODESIGN=0
      shift
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

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required. Install it before running this development build." >&2
  exit 1
fi

if [[ ! -x "$XCODEBUILD" ]]; then
  XCODEBUILD="$(command -v xcodebuild || true)"
fi

if [[ -z "$XCODEBUILD" || ! -x "$XCODEBUILD" ]]; then
  echo "xcodebuild was not found. Set INSIGHTKIT_XCODEBUILD or install Xcode." >&2
  exit 1
fi

APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/InsightKitApp.app"

echo "==> Generating Xcode project"
(cd "$PROJECT_DIR" && xcodegen generate)

echo "==> Building $SCHEME ($CONFIGURATION)"
"$XCODEBUILD" \
  -project "$XCODEPROJ" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -destination "$DESTINATION" \
  build

if [[ ! -d "$APP_PATH" ]]; then
  echo "Expected debug app was not created: $APP_PATH" >&2
  exit 1
fi

if [[ "$VERIFY_CODESIGN" == "1" ]]; then
  echo "==> Verifying codesign"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
fi

echo "Debug app: $APP_PATH"
