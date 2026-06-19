#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/macos/InsightKitApp"
APP_NAME="InsightKit"
APP_BUNDLE_NAME="${APP_NAME}.app"
EXECUTABLE_NAME="InsightKitApp"
BUNDLE_ID="com.yannjy.insightkit"
ICON_FILE="InsightKit.icns"
ICON_SOURCE="$PACKAGE_DIR/Resources/$ICON_FILE"

CONFIGURATION="release"
OUTPUT_DIR="$ROOT_DIR/dist/macos"
INSTALL_DIR=""
VERSION="${INSIGHTKIT_VERSION:-0.1.0}"
SIGN_IDENTITY="${INSIGHTKIT_SIGN_IDENTITY:-}"
SIGN_IDENTITY_FILE="$ROOT_DIR/.ops/signing_identity.txt"
ENTITLEMENTS_PATH="${INSIGHTKIT_ENTITLEMENTS_PATH:-}"
CLEAN_BUILD=0
EXPLICIT_SIGN_IDENTITY=0
DISTRIBUTION_MODE="${INSIGHTKIT_DISTRIBUTION:-local}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --debug                      Build Debug instead of Release
  --output-dir <path>          App bundle output directory (default: dist/macos)
  --install-dir <path>         Copy built .app into this directory
  --version <semver>           Set CFBundleShortVersionString (default: $VERSION)
  --clean                      Clean Swift package build artifacts before build
  --no-clean                   Disable pre-build clean (default)
  --sign-identity <name>       Code signing identity (default: auto-detect Apple Development)
  --entitlements <path>        Embed a code-signing entitlements plist
  --adhoc-sign                 Force ad-hoc signing (not recommended; may trigger repeated permission prompts)
  --distribution <mode>        Signing mode: local or developer-id (default: $DISTRIBUTION_MODE)
  --developer-id               Shortcut for --distribution developer-id
  -h, --help                   Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug)
      CONFIGURATION="debug"
      shift
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --install-dir)
      INSTALL_DIR="${2:-}"
      shift 2
      ;;
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --clean)
      CLEAN_BUILD=1
      shift
      ;;
    --no-clean)
      CLEAN_BUILD=0
      shift
      ;;
    --sign-identity)
      SIGN_IDENTITY="${2:-}"
      EXPLICIT_SIGN_IDENTITY=1
      shift 2
      ;;
    --entitlements)
      ENTITLEMENTS_PATH="${2:-}"
      shift 2
      ;;
    --adhoc-sign)
      SIGN_IDENTITY="-"
      EXPLICIT_SIGN_IDENTITY=1
      shift
      ;;
    --distribution)
      DISTRIBUTION_MODE="${2:-}"
      shift 2
      ;;
    --developer-id)
      DISTRIBUTION_MODE="developer-id"
      shift
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

if [[ ! -d "$PACKAGE_DIR" ]]; then
  echo "Package directory not found: $PACKAGE_DIR" >&2
  exit 1
fi

case "$DISTRIBUTION_MODE" in
  local|developer-id) ;;
  *)
    echo "Unknown distribution mode: $DISTRIBUTION_MODE" >&2
    usage
    exit 1
    ;;
esac

GIT_REVISION="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if git -C "$ROOT_DIR" diff --quiet --ignore-submodules HEAD -- \
    && git -C "$ROOT_DIR" diff --cached --quiet --ignore-submodules --; then
    BUILD_SOURCE="local-workspace-clean"
  else
    BUILD_SOURCE="local-workspace-dirty"
  fi
else
  BUILD_SOURCE="local-workspace-nongit"
fi

if [[ -z "${SIGN_IDENTITY}" && -f "$SIGN_IDENTITY_FILE" ]]; then
  SIGN_IDENTITY="$(cat "$SIGN_IDENTITY_FILE" 2>/dev/null || true)"
fi

if [[ "$DISTRIBUTION_MODE" == "developer-id"
      && "$EXPLICIT_SIGN_IDENTITY" -eq 0
      && -z "${INSIGHTKIT_SIGN_IDENTITY:-}"
      && "${SIGN_IDENTITY}" != Developer\ ID\ Application:* ]]; then
  SIGN_IDENTITY=""
fi

is_valid_sign_identity() {
  local identity="$1"
  [[ "$identity" == "-" ]] && return 0
  command -v security >/dev/null 2>&1 || return 1
  security find-identity -v -p codesigning 2>/dev/null \
    | /usr/bin/grep -F "\"${identity}\"" >/dev/null
}

if [[ -n "${SIGN_IDENTITY}" && "${SIGN_IDENTITY}" != "-" ]] && ! is_valid_sign_identity "$SIGN_IDENTITY"; then
  if [[ "$EXPLICIT_SIGN_IDENTITY" -eq 1 || -n "${INSIGHTKIT_SIGN_IDENTITY:-}" ]]; then
    echo "Configured signing identity is not valid for codesigning: $SIGN_IDENTITY" >&2
    exit 1
  fi
  echo "Warning: cached signing identity is no longer valid; falling back to auto-detect/ad-hoc signing: $SIGN_IDENTITY" >&2
  SIGN_IDENTITY=""
fi

if [[ -z "${SIGN_IDENTITY}" ]]; then
  if command -v security >/dev/null 2>&1; then
    SIGN_IDENTITY="$(
      security find-identity -v -p codesigning 2>/dev/null \
      | awk -F'"' '/Developer ID Application:/ {print $2; exit}'
    )"
    if [[ -z "${SIGN_IDENTITY}" && "$DISTRIBUTION_MODE" == "local" ]]; then
      SIGN_IDENTITY="$(
        security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Apple Development:/ {print $2; exit}'
      )"
    fi
  fi
fi

if [[ -z "${SIGN_IDENTITY}" ]]; then
  SIGN_IDENTITY="-"
fi

if [[ "$DISTRIBUTION_MODE" == "developer-id" ]]; then
  if [[ "$SIGN_IDENTITY" == "-" || "${SIGN_IDENTITY}" != Developer\ ID\ Application:* ]]; then
    echo "Developer ID distribution requires a valid 'Developer ID Application' signing identity." >&2
    echo "Current signing identity: $SIGN_IDENTITY" >&2
    echo "Install a Developer ID Application certificate, or use the default local distribution mode for machine-local validation." >&2
    exit 1
  fi
fi

if [[ "$SIGN_IDENTITY" != "-" ]]; then
  mkdir -p "$(dirname "$SIGN_IDENTITY_FILE")"
  printf '%s\n' "$SIGN_IDENTITY" > "$SIGN_IDENTITY_FILE"
fi

if [[ -n "$ENTITLEMENTS_PATH" ]]; then
  if [[ "$ENTITLEMENTS_PATH" != /* ]]; then
    ENTITLEMENTS_PATH="$ROOT_DIR/$ENTITLEMENTS_PATH"
  fi
  if [[ ! -f "$ENTITLEMENTS_PATH" ]]; then
    echo "Entitlements file not found: $ENTITLEMENTS_PATH" >&2
    exit 1
  fi
fi

if [[ "$CLEAN_BUILD" -eq 1 ]]; then
  swift package --package-path "$PACKAGE_DIR" clean
fi

swift build --package-path "$PACKAGE_DIR" -c "$CONFIGURATION"

arch_name="$(uname -m)"
bin_path="$PACKAGE_DIR/.build/${arch_name}-apple-macosx/${CONFIGURATION}/${EXECUTABLE_NAME}"
if [[ ! -x "$bin_path" ]]; then
  bin_path="$(find "$PACKAGE_DIR/.build" -type f -name "$EXECUTABLE_NAME" -path "*/${CONFIGURATION}/*" -print | head -n 1)"
fi
if [[ -z "$bin_path" || ! -x "$bin_path" ]]; then
  echo "Cannot find built executable: $EXECUTABLE_NAME" >&2
  exit 1
fi

app_root="$OUTPUT_DIR/$APP_BUNDLE_NAME"
contents_dir="$app_root/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"
runtime_root="$resources_dir/insightkit_runtime"

rm -rf "$app_root"
mkdir -p "$macos_dir" "$resources_dir"

cp "$bin_path" "$macos_dir/$EXECUTABLE_NAME"
chmod +x "$macos_dir/$EXECUTABLE_NAME"

if [[ -f "$ICON_SOURCE" ]]; then
  cp "$ICON_SOURCE" "$resources_dir/$ICON_FILE"
else
  echo "Warning: app icon missing at $ICON_SOURCE" >&2
fi

mkdir -p "$runtime_root"
cp -R "$ROOT_DIR/scripts" "$runtime_root/"
cp -R "$ROOT_DIR/insightkit" "$runtime_root/"
find "$runtime_root" -name "__pycache__" -type d -prune -exec rm -rf {} +
find "$runtime_root" -name "*.pyc" -type f -delete
find "$runtime_root" -name ".DS_Store" -type f -delete

sanitize_for_codesign() {
  local target="$1"
  find "$target" -name ".DS_Store" -type f -delete
  if command -v dot_clean >/dev/null 2>&1; then
    dot_clean -m "$target" >/dev/null 2>&1 || true
  fi
  if command -v xattr >/dev/null 2>&1; then
    xattr -cr "$target" || true
    while IFS= read -r -d '' item; do
      xattr -d 'com.apple.fileprovider.fpfs#P' "$item" >/dev/null 2>&1 || true
      xattr -d com.apple.FinderInfo "$item" >/dev/null 2>&1 || true
      xattr -d com.apple.macl "$item" >/dev/null 2>&1 || true
      xattr -d com.apple.provenance "$item" >/dev/null 2>&1 || true
    done < <(find "$target" -print0)
    xattr -d 'com.apple.fileprovider.fpfs#P' "$target" >/dev/null 2>&1 || true
    xattr -d com.apple.FinderInfo "$target" >/dev/null 2>&1 || true
    xattr -d com.apple.macl "$target" >/dev/null 2>&1 || true
    xattr -d com.apple.provenance "$target" >/dev/null 2>&1 || true
    xattr -c "$target" >/dev/null 2>&1 || true
  fi
}

strip_bundle_root_detritus() {
  local target="$1"
  if command -v xattr >/dev/null 2>&1; then
    xattr -d 'com.apple.fileprovider.fpfs#P' "$target" >/dev/null 2>&1 || true
    xattr -d com.apple.FinderInfo "$target" >/dev/null 2>&1 || true
    xattr -d com.apple.macl "$target" >/dev/null 2>&1 || true
    xattr -d com.apple.provenance "$target" >/dev/null 2>&1 || true
    xattr -c "$target" >/dev/null 2>&1 || true
  fi
}

verify_embedded_entitlements() {
  local app="$1"
  local expected="$2"
  local embedded="/tmp/insightkit-embedded-entitlements.$$.$RANDOM.plist"
  local err="/tmp/insightkit-embedded-entitlements.$$.$RANDOM.err"
  local combined="/tmp/insightkit-embedded-entitlements.$$.$RANDOM.combined"
  codesign -d --xml --entitlements - "$app" 2>&1 | tee "$combined" >/dev/null || true
  if grep -qi 'invalid entitlements blob' "$combined"; then
    echo "Embedded entitlements verification failed: codesign reported an invalid entitlements blob." >&2
    cat "$combined" >&2
    rm -f "$embedded" "$err" "$combined"
    exit 1
  fi
  codesign -d --xml --entitlements - "$app" >"$embedded" 2>"$err" || true
  if grep -qi 'invalid entitlements blob' "$err"; then
    echo "Embedded entitlements verification failed: codesign reported an invalid entitlements blob." >&2
    cat "$err" >&2
    rm -f "$embedded" "$err" "$combined"
    exit 1
  fi
  if ! /usr/libexec/PlistBuddy -c Print "$embedded" >/dev/null 2>&1; then
    echo "Embedded entitlements verification failed: codesign did not emit a valid entitlements plist." >&2
    if [[ -s "$err" ]]; then
      cat "$err" >&2
    fi
    rm -f "$embedded" "$err" "$combined"
    exit 1
  fi
  local keys=(
    "com.apple.security.app-sandbox"
    "com.apple.security.device.audio-input"
    "com.apple.security.device.camera"
    "com.apple.security.files.bookmarks.app-scope"
    "com.apple.security.files.user-selected.read-write"
    "com.apple.security.network.client"
  )
  local key
  for key in "${keys[@]}"; do
    local expected_value
    expected_value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$expected" 2>/dev/null || true)"
    [[ "$expected_value" == "true" ]] || continue
    local embedded_value
    embedded_value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$embedded" 2>/dev/null || true)"
    if [[ "$embedded_value" != "true" ]]; then
      echo "Embedded entitlements verification failed for $key" >&2
      if [[ -s "$err" ]]; then
        cat "$err" >&2
      fi
      rm -f "$embedded" "$err" "$combined"
      exit 1
    fi
  done
  rm -f "$embedded" "$err" "$combined"
}

server_file="$runtime_root/insightkit/ipc/server.py"
required_caps=(
  "\"transcription.status\""
  "\"asr.runtime.status\""
  "\"asr.runtime.bootstrap\""
  "\"diagnostics.quick_check\""
)
for cap in "${required_caps[@]}"; do
  if ! /usr/bin/grep -q "$cap" "$server_file"; then
    echo "Packaged runtime missing capability: $cap" >&2
    exit 1
  fi
done

build_number="$(date +%Y%m%d%H%M%S)"
cat > "$contents_dir/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleExecutable</key>
  <string>${EXECUTABLE_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleIconFile</key>
  <string>${ICON_FILE}</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>com.yannjy.insightkit.import</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>insightkit</string>
      </array>
    </dict>
  </array>
  <key>CFBundleVersion</key>
  <string>${build_number}</string>
  <key>InsightKitGitRevision</key>
  <string>${GIT_REVISION}</string>
  <key>InsightKitBuildSource</key>
  <string>${BUILD_SOURCE}</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>InsightKit 需要麦克风权限用于会议录音和实时转写。</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>InsightKit 需要屏幕录制权限用于系统音频采集与实时洞察。</string>
  <key>NSCameraUsageDescription</key>
  <string>InsightKit 需要摄像头权限用于视频捕获。</string>
</dict>
</plist>
EOF

if command -v codesign >/dev/null 2>&1; then
  sanitize_for_codesign "$app_root"
  CODESIGN_COMMON=(--force --deep)
  if [[ "$DISTRIBUTION_MODE" == "developer-id" ]]; then
    CODESIGN_COMMON+=(--options runtime --timestamp)
  else
    CODESIGN_COMMON+=(--timestamp=none)
  fi
  if [[ -n "$ENTITLEMENTS_PATH" ]]; then
    CODESIGN_COMMON+=(--entitlements "$ENTITLEMENTS_PATH")
  fi
  if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "Warning: using ad-hoc signing. macOS privacy permissions may re-prompt after updates." >&2
    if ! sign_output="$(codesign "${CODESIGN_COMMON[@]}" --sign - "$app_root" 2>&1)"; then
      if echo "$sign_output" | grep -Eqi "resource fork|Finder information|detritus"; then
        echo "Detected extended-attribute detritus under output dir; retry ad-hoc signing in /tmp staging."
        stage_dir="$(mktemp -d /tmp/insightkit-sign.XXXXXX)"
        stage_app="$stage_dir/$APP_BUNDLE_NAME"
        ditto "$app_root" "$stage_app"
        sanitize_for_codesign "$stage_app"
        codesign "${CODESIGN_COMMON[@]}" --sign - "$stage_app"
        rm -rf "$app_root"
        ditto "$stage_app" "$app_root"
        sanitize_for_codesign "$app_root"
        rm -rf "$stage_dir"
      else
        echo "$sign_output" >&2
        exit 1
      fi
    fi
  else
    echo "Signing with identity: $SIGN_IDENTITY"
    if ! sign_output="$(codesign "${CODESIGN_COMMON[@]}" --sign "$SIGN_IDENTITY" "$app_root" 2>&1)"; then
      if echo "$sign_output" | grep -Eqi "resource fork|Finder information|detritus"; then
        echo "Detected extended-attribute detritus under output dir; retry signing in /tmp staging."
        stage_dir="$(mktemp -d /tmp/insightkit-sign.XXXXXX)"
        stage_app="$stage_dir/$APP_BUNDLE_NAME"
        ditto "$app_root" "$stage_app"
        sanitize_for_codesign "$stage_app"
        codesign "${CODESIGN_COMMON[@]}" --sign "$SIGN_IDENTITY" "$stage_app"
        rm -rf "$app_root"
        ditto "$stage_app" "$app_root"
        sanitize_for_codesign "$app_root"
        rm -rf "$stage_dir"
      else
        echo "$sign_output" >&2
        exit 1
      fi
    fi
  fi
  strip_bundle_root_detritus "$app_root"
  if ! verify_output="$(codesign --verify --deep --strict "$app_root" 2>&1)"; then
    if echo "$verify_output" | grep -Eqi "resource fork|Finder information|detritus"; then
      echo "Detected extended-attribute detritus during verification; retry signing in /tmp staging."
      stage_dir="$(mktemp -d /tmp/insightkit-verify.XXXXXX)"
      stage_app="$stage_dir/$APP_BUNDLE_NAME"
      ditto "$app_root" "$stage_app"
      sanitize_for_codesign "$stage_app"
      codesign "${CODESIGN_COMMON[@]}" --sign "$SIGN_IDENTITY" "$stage_app"
      rm -rf "$app_root"
      ditto "$stage_app" "$app_root"
      sanitize_for_codesign "$app_root"
      rm -rf "$stage_dir"
      codesign --verify --deep --strict "$app_root"
    else
      echo "$verify_output" >&2
      exit 1
    fi
  fi
  if [[ -n "$ENTITLEMENTS_PATH" ]]; then
    verify_embedded_entitlements "$app_root" "$ENTITLEMENTS_PATH"
  fi
fi

if [[ -n "$INSTALL_DIR" ]]; then
  mkdir -p "$INSTALL_DIR"
  rm -rf "$INSTALL_DIR/$APP_BUNDLE_NAME"
  ditto "$app_root" "$INSTALL_DIR/$APP_BUNDLE_NAME"
  sanitize_for_codesign "$INSTALL_DIR/$APP_BUNDLE_NAME"
  echo "Installed: $INSTALL_DIR/$APP_BUNDLE_NAME"
fi

echo "Built app bundle: $app_root"
echo "Open with: open \"$app_root\""
echo "Distribution mode: $DISTRIBUTION_MODE"
echo "Code signing identity: $SIGN_IDENTITY"
if [[ -n "$ENTITLEMENTS_PATH" ]]; then
  echo "Entitlements: $ENTITLEMENTS_PATH"
fi
echo "Git revision: $GIT_REVISION ($BUILD_SOURCE)"
