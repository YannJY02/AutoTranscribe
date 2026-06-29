#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_ENTITLEMENTS_PATH="$ROOT_DIR/macos/InsightKitApp/InsightKitApp.entitlements"
APP_STORE_ENTITLEMENTS_PATH="$ROOT_DIR/macos/InsightKitApp/InsightKitApp.AppStore.entitlements"
ENTITLEMENTS_PATH="${INSIGHTKIT_ENTITLEMENTS_PATH:-$LOCAL_ENTITLEMENTS_PATH}"
LEGACY_RELEASE_DOCS_DIR="$ROOT_DIR/docs/Legacy/matt-workflow-library/original-assets/docs/release"
PRIVACY_DOC_PATH="$LEGACY_RELEASE_DOCS_DIR/release-privacy-sandbox.md"
PRIVACY_POLICY_DRAFT_PATH="$LEGACY_RELEASE_DOCS_DIR/release-privacy-policy-draft.md"
APP_STORE_PRIVACY_ANSWERS_PATH="$LEGACY_RELEASE_DOCS_DIR/release-app-store-privacy-answers.md"
APP_PATH="/private/tmp/insightkit-package/InsightKit.app"
CHANNEL="local"
TMP_PREFIX="/tmp/insightkit-preflight.$$"
CODESIGN_VERIFY_LOG="${TMP_PREFIX}-codesign-verify.log"
CODESIGN_DETAIL_LOG="${TMP_PREFIX}-codesign-detail.log"
EMBEDDED_ENTITLEMENTS_PLIST="${TMP_PREFIX}-embedded-entitlements.plist"
EMBEDDED_ENTITLEMENTS_ERR="${TMP_PREFIX}-embedded-entitlements.err"
EMBEDDED_ENTITLEMENTS_COMBINED="${TMP_PREFIX}-embedded-entitlements.combined"
SPCTL_LOG="${TMP_PREFIX}-spctl.log"

status=0

pass() { printf 'PASS %s\n' "$1"; }
warn() { printf 'WARN %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; status=1; }

plist_bool() {
  local plist="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true
}

require_for_app_store_or_warn() {
  local message="$1"
  if [[ "$CHANNEL" == "app-store" ]]; then
    fail "$message"
  else
    warn "$message"
  fi
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] [app-path]

Validate an InsightKit macOS app bundle for local QA or distribution readiness.

Options:
  --channel <mode>       local, developer-id, or app-store (default: $CHANNEL)
  --developer-id         Shortcut for --channel developer-id
  --app-store            Shortcut for --channel app-store
  -h, --help             Show help

local mode keeps distribution-only issues as WARN.
developer-id/app-store modes turn their required release gates into FAIL.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel)
      CHANNEL="${2:-}"
      shift 2
      ;;
    --developer-id)
      CHANNEL="developer-id"
      shift
      ;;
    --app-store)
      CHANNEL="app-store"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      APP_PATH="$1"
      shift
      ;;
  esac
done

case "$CHANNEL" in
  local|developer-id|app-store) ;;
  *)
    echo "Unknown channel: $CHANNEL" >&2
    usage
    exit 1
    ;;
esac

if [[ -z "${INSIGHTKIT_ENTITLEMENTS_PATH:-}" && "$CHANNEL" == "app-store" && -f "$APP_STORE_ENTITLEMENTS_PATH" ]]; then
  ENTITLEMENTS_PATH="$APP_STORE_ENTITLEMENTS_PATH"
fi

pass "preflight channel: $CHANNEL"

if [[ -d "$APP_PATH" ]]; then
  pass "app exists: $APP_PATH"
else
  fail "app missing: $APP_PATH"
fi

info_plist="$APP_PATH/Contents/Info.plist"
if [[ -f "$info_plist" ]]; then
  required_usage_keys=(
    "NSMicrophoneUsageDescription"
    "NSSpeechRecognitionUsageDescription"
    "NSCameraUsageDescription"
    "NSScreenCaptureUsageDescription"
  )
  for key in "${required_usage_keys[@]}"; do
    value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$info_plist" 2>/dev/null || true)"
    if [[ -n "$value" ]]; then
      pass "Info.plist has $key"
    else
      fail "Info.plist missing $key"
    fi
  done
else
  fail "Info.plist missing: $info_plist"
fi

if command -v security >/dev/null 2>&1; then
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  if printf '%s\n' "$identities" | grep -q '"Developer ID Application:'; then
    pass "Developer ID Application identity is available"
  else
    if [[ "$CHANNEL" == "developer-id" ]]; then
      fail "Developer ID Application identity is missing; direct notarized distribution is blocked"
    else
      warn "Developer ID Application identity is missing; direct notarized distribution is blocked"
    fi
  fi
  if printf '%s\n' "$identities" | grep -q '"Apple Development:'; then
    pass "Apple Development identity is available for local validation"
  else
    warn "Apple Development identity is missing"
  fi
  if [[ "$CHANNEL" == "app-store" ]]; then
    if printf '%s\n' "$identities" | grep -Eq '"(Apple Distribution|3rd Party Mac Developer Application):'; then
      pass "Mac App Store distribution signing identity is available"
    else
      fail "Mac App Store distribution signing identity is missing; App Store submission requires an Apple Distribution or 3rd Party Mac Developer Application identity"
    fi
  fi
else
  warn "security command not available"
fi

if [[ -d "$APP_PATH" ]] && command -v codesign >/dev/null 2>&1; then
  if codesign --verify --deep --strict --verbose=2 "$APP_PATH" >"$CODESIGN_VERIFY_LOG" 2>&1; then
    pass "codesign strict verification passed"
  else
    fail "codesign strict verification failed; see $CODESIGN_VERIFY_LOG"
  fi

  codesign -dvvv "$APP_PATH" >"$CODESIGN_DETAIL_LOG" 2>&1 || true
  codesign -d --xml --entitlements - "$APP_PATH" 2>&1 | tee "$EMBEDDED_ENTITLEMENTS_COMBINED" >/dev/null || true
  codesign -d --xml --entitlements - "$APP_PATH" >"$EMBEDDED_ENTITLEMENTS_PLIST" 2>"$EMBEDDED_ENTITLEMENTS_ERR" || true
  if grep -q 'Authority=Developer ID Application:' "$CODESIGN_DETAIL_LOG"; then
    pass "app is signed with Developer ID Application"
  else
    if [[ "$CHANNEL" == "developer-id" ]]; then
      fail "app is not signed with Developer ID Application"
    else
      warn "app is not signed with Developer ID Application"
    fi
  fi
  if [[ "$CHANNEL" == "app-store" ]]; then
    if grep -Eq 'Authority=(Apple Distribution|3rd Party Mac Developer Application):' "$CODESIGN_DETAIL_LOG"; then
      pass "app is signed with a Mac App Store distribution identity"
    else
      fail "app is not signed with a Mac App Store distribution identity"
    fi
  fi
  if grep -q 'Runtime Version=' "$CODESIGN_DETAIL_LOG"; then
    pass "hardened runtime is present"
  else
    if [[ "$CHANNEL" == "developer-id" ]]; then
      fail "hardened runtime is not present; notarization will require Developer ID signing with --options runtime"
    else
      warn "hardened runtime is not present; notarization will require Developer ID signing with --options runtime"
    fi
  fi
fi

if [[ -d "$APP_PATH" ]] && command -v spctl >/dev/null 2>&1; then
  if spctl -a -vv "$APP_PATH" >"$SPCTL_LOG" 2>&1; then
    if grep -q 'override=security disabled' "$SPCTL_LOG"; then
      if [[ "$CHANNEL" == "developer-id" ]]; then
        fail "spctl accepted only with local security override; not a clean Gatekeeper distribution proof"
      else
        warn "spctl accepted only with local security override; not a clean Gatekeeper distribution proof"
      fi
    else
      pass "spctl accepted app"
    fi
  else
    if [[ "$CHANNEL" == "developer-id" ]]; then
      fail "spctl did not accept app; see $SPCTL_LOG"
    else
      warn "spctl did not accept app; see $SPCTL_LOG"
    fi
  fi
fi

if command -v xcrun >/dev/null 2>&1 && xcrun notarytool --version >/dev/null 2>&1; then
  pass "notarytool is available"
else
  if [[ "$CHANNEL" == "developer-id" ]]; then
    fail "notarytool is unavailable; notarization cannot be run on this machine yet"
  else
    warn "notarytool is unavailable; notarization cannot be run on this machine yet"
  fi
fi

if [[ -f "$ENTITLEMENTS_PATH" ]]; then
  pass "source entitlements file exists: $ENTITLEMENTS_PATH"
  sandbox_value="$(plist_bool "$ENTITLEMENTS_PATH" 'com.apple.security.app-sandbox')"
  if [[ "$sandbox_value" == "true" ]]; then
    pass "source App Sandbox entitlement is enabled"
  else
    if [[ "$CHANNEL" == "app-store" ]]; then
      fail "App Sandbox entitlement is disabled; Mac App Store submission requires a sandbox/file-access review"
    else
      warn "App Sandbox entitlement is disabled; Mac App Store submission requires a sandbox/file-access review"
    fi
  fi

  if [[ "$CHANNEL" == "app-store" ]]; then
    user_selected_rw="$(plist_bool "$ENTITLEMENTS_PATH" 'com.apple.security.files.user-selected.read-write')"
    bookmarks_scope="$(plist_bool "$ENTITLEMENTS_PATH" 'com.apple.security.files.bookmarks.app-scope')"
    network_client="$(plist_bool "$ENTITLEMENTS_PATH" 'com.apple.security.network.client')"
    if [[ "$user_selected_rw" == "true" ]]; then
      pass "source user-selected read/write file entitlement is enabled"
    else
      fail "User-selected read/write file entitlement is missing for sandboxed import/export"
    fi
    if [[ "$bookmarks_scope" == "true" ]]; then
      pass "source app-scoped security bookmark entitlement is enabled"
    else
      fail "App-scoped security bookmark entitlement is missing for persisted external file access"
    fi
    if [[ "$network_client" == "true" ]]; then
      pass "source network client entitlement is enabled for optional BYOK providers"
    else
      warn "source network client entitlement is missing; App Store build should be local-only or add network client entitlement"
    fi

    embedded_sandbox="$(plist_bool "$EMBEDDED_ENTITLEMENTS_PLIST" 'com.apple.security.app-sandbox')"
    embedded_user_selected_rw="$(plist_bool "$EMBEDDED_ENTITLEMENTS_PLIST" 'com.apple.security.files.user-selected.read-write')"
    embedded_bookmarks_scope="$(plist_bool "$EMBEDDED_ENTITLEMENTS_PLIST" 'com.apple.security.files.bookmarks.app-scope')"
    if grep -qi 'invalid entitlements blob' "$CODESIGN_DETAIL_LOG" "$EMBEDDED_ENTITLEMENTS_ERR" "$EMBEDDED_ENTITLEMENTS_COMBINED"; then
      fail "packaged app contains an invalid entitlements blob; macOS will ignore the embedded entitlements"
    fi
    if ! /usr/libexec/PlistBuddy -c Print "$EMBEDDED_ENTITLEMENTS_PLIST" >/dev/null 2>&1; then
      fail "packaged app does not expose a valid embedded entitlements plist"
    fi
    if [[ "$embedded_sandbox" == "true" ]]; then
      pass "packaged app embeds App Sandbox entitlement"
    else
      fail "packaged app does not embed App Sandbox entitlement"
    fi
    if [[ "$embedded_user_selected_rw" == "true" ]]; then
      pass "packaged app embeds user-selected read/write file entitlement"
    else
      fail "packaged app does not embed user-selected read/write file entitlement"
    fi
    if [[ "$embedded_bookmarks_scope" == "true" ]]; then
      pass "packaged app embeds app-scoped security bookmark entitlement"
    else
      fail "packaged app does not embed app-scoped security bookmark entitlement"
    fi
  fi
else
  if [[ "$CHANNEL" == "app-store" ]]; then
    fail "entitlements file missing: $ENTITLEMENTS_PATH"
  else
    warn "entitlements file missing: $ENTITLEMENTS_PATH"
  fi
fi

if [[ -f "$PRIVACY_DOC_PATH" ]]; then
  pass "privacy and sandbox release note exists"
else
  require_for_app_store_or_warn "privacy and sandbox release note is missing: $PRIVACY_DOC_PATH"
fi

if [[ -f "$PRIVACY_POLICY_DRAFT_PATH" ]]; then
  pass "privacy policy draft exists"
else
  require_for_app_store_or_warn "privacy policy draft is missing: $PRIVACY_POLICY_DRAFT_PATH"
fi

if [[ -f "$APP_STORE_PRIVACY_ANSWERS_PATH" ]]; then
  pass "App Store privacy answer draft exists"
else
  require_for_app_store_or_warn "App Store privacy answer draft is missing: $APP_STORE_PRIVACY_ANSWERS_PATH"
fi

if [[ -n "${INSIGHTKIT_PRIVACY_POLICY_URL:-}" ]]; then
  pass "privacy policy URL configured"
else
  require_for_app_store_or_warn "privacy policy URL is not configured; set INSIGHTKIT_PRIVACY_POLICY_URL for App Store readiness"
fi

exit "$status"
