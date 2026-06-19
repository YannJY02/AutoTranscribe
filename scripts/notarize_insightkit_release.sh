#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFLIGHT_SCRIPT="$ROOT_DIR/scripts/release_preflight.sh"
APP_PATH="/private/tmp/insightkit-package/InsightKit.app"
RELEASES_DIR="$ROOT_DIR/dist/releases"
VERSION=""
KEYCHAIN_PROFILE="${INSIGHTKIT_NOTARY_PROFILE:-}"
APPLE_ID="${INSIGHTKIT_NOTARY_APPLE_ID:-}"
TEAM_ID="${INSIGHTKIT_NOTARY_TEAM_ID:-}"
APP_PASSWORD="${INSIGHTKIT_NOTARY_PASSWORD:-}"
BUILD_STAMP="$(date +%Y%m%d%H%M%S)"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Submit a Developer ID signed InsightKit.app to Apple's notary service, staple
the accepted ticket to the app, validate the staple, and create a public zip.

Options:
  --app <path>                 Developer ID signed InsightKit.app
                               (default: $APP_PATH)
  --version <semver>           Release version. Defaults to CFBundleShortVersionString.
  --output-dir <path>          Final zip/log output directory (default: dist/releases)
  --keychain-profile <name>    notarytool keychain profile. Can also use INSIGHTKIT_NOTARY_PROFILE.
  --apple-id <email>           Apple ID for notarytool. Can also use INSIGHTKIT_NOTARY_APPLE_ID.
  --team-id <id>               Team ID for notarytool. Can also use INSIGHTKIT_NOTARY_TEAM_ID.
  --password <secret>          App-specific password. Prefer INSIGHTKIT_NOTARY_PASSWORD or keychain profile.
  -h, --help                   Show help

The script fails before contacting Apple unless the app passes:
  scripts/release_preflight.sh --developer-id <app>

Preferred credential setup:
  xcrun notarytool store-credentials insightkit-notary
  ./scripts/notarize_insightkit_release.sh --app <DeveloperID-signed.app> --keychain-profile insightkit-notary
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      APP_PATH="${2:-}"
      shift 2
      ;;
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --output-dir)
      RELEASES_DIR="${2:-}"
      shift 2
      ;;
    --keychain-profile)
      KEYCHAIN_PROFILE="${2:-}"
      shift 2
      ;;
    --apple-id)
      APPLE_ID="${2:-}"
      shift 2
      ;;
    --team-id)
      TEAM_ID="${2:-}"
      shift 2
      ;;
    --password)
      APP_PASSWORD="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 1
fi

for tool in xcrun ditto codesign spctl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Required tool not found: $tool" >&2
    exit 1
  fi
done

if ! xcrun notarytool --version >/dev/null 2>&1; then
  echo "xcrun notarytool is unavailable." >&2
  exit 1
fi
stapler_output="$(xcrun stapler 2>&1 || true)"
if ! printf '%s\n' "$stapler_output" | grep -q 'Usage'; then
  echo "xcrun stapler is unavailable." >&2
  exit 1
fi

if [[ -z "$VERSION" ]]; then
  plist_path="$APP_PATH/Contents/Info.plist"
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist_path" 2>/dev/null || true)"
fi
if [[ -z "$VERSION" ]]; then
  echo "Unable to determine version; pass --version." >&2
  exit 1
fi

mkdir -p "$RELEASES_DIR"

echo "==> [notarize] Developer ID preflight..."
"$PREFLIGHT_SCRIPT" --developer-id "$APP_PATH"

auth_args=()
if [[ -n "$KEYCHAIN_PROFILE" ]]; then
  auth_args=(--keychain-profile "$KEYCHAIN_PROFILE")
elif [[ -n "$APPLE_ID" && -n "$TEAM_ID" && -n "$APP_PASSWORD" ]]; then
  auth_args=(--apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD")
else
  cat >&2 <<EOF
Missing notarytool credentials.

Provide either:
  --keychain-profile <name>
or all of:
  --apple-id <email> --team-id <id> --password <app-specific-password>

Recommended:
  xcrun notarytool store-credentials insightkit-notary
  ./scripts/notarize_insightkit_release.sh --app "$APP_PATH" --keychain-profile insightkit-notary
EOF
  exit 1
fi

STAGING_DIR="$(mktemp -d "/private/tmp/insightkit-notary-${VERSION}.XXXXXX")"
SUBMISSION_ZIP="$STAGING_DIR/InsightKit-${VERSION}-notary-submission.zip"
FINAL_ZIP="$RELEASES_DIR/InsightKit-${VERSION}-macos-developer-id-notarized-stapled-${BUILD_STAMP}.zip"
NOTARY_LOG="$RELEASES_DIR/InsightKit-${VERSION}-notary-${BUILD_STAMP}.log"
STAPLER_LOG="$RELEASES_DIR/InsightKit-${VERSION}-stapler-${BUILD_STAMP}.log"

if [[ -e "$FINAL_ZIP" ]]; then
  echo "Final archive already exists: $FINAL_ZIP" >&2
  exit 1
fi

echo "==> [notarize] Creating notary submission zip..."
COPYFILE_DISABLE=1 ditto -c -k --keepParent "$APP_PATH" "$SUBMISSION_ZIP"
if unzip -Z1 "$SUBMISSION_ZIP" | grep -E '(^|/)__MACOSX(/|$)|(^|/)\._' >/dev/null; then
  echo "Notary submission zip contains __MACOSX or AppleDouble entries: $SUBMISSION_ZIP" >&2
  exit 1
fi

echo "==> [notarize] Submitting to Apple notary service..."
xcrun notarytool submit "$SUBMISSION_ZIP" --wait "${auth_args[@]}" 2>&1 | tee "$NOTARY_LOG"

echo "==> [notarize] Stapling ticket to app..."
xcrun stapler staple "$APP_PATH" 2>&1 | tee "$STAPLER_LOG"
xcrun stapler validate "$APP_PATH" 2>&1 | tee -a "$STAPLER_LOG"

echo "==> [notarize] Validating final app..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl -a -vv "$APP_PATH"
"$PREFLIGHT_SCRIPT" --developer-id "$APP_PATH"

echo "==> [notarize] Creating final notarized zip..."
COPYFILE_DISABLE=1 ditto -c -k --keepParent "$APP_PATH" "$FINAL_ZIP"
if unzip -Z1 "$FINAL_ZIP" | grep -E '(^|/)__MACOSX(/|$)|(^|/)\._' >/dev/null; then
  echo "Final release zip contains __MACOSX or AppleDouble entries: $FINAL_ZIP" >&2
  exit 1
fi

ZIP_SIZE="$(du -sh "$FINAL_ZIP" | cut -f1)"
echo ""
echo "✓ Notarized release archive ready"
echo "  App: ${APP_PATH}"
echo "  Submission zip: ${SUBMISSION_ZIP}"
echo "  Final zip: ${FINAL_ZIP} (${ZIP_SIZE})"
echo "  Notary log: ${NOTARY_LOG}"
echo "  Stapler log: ${STAPLER_LOG}"
