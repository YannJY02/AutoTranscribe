#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/macos/InsightKitApp"
APP_NAME="InsightKit"
APP_BUNDLE_NAME="${APP_NAME}.app"
EXECUTABLE_NAME="InsightKitApp"
BUNDLE_ID="com.yannjy.insightkit"

CONFIGURATION="release"
OUTPUT_DIR="$ROOT_DIR/dist/macos"
INSTALL_DIR=""
VERSION="${INSIGHTKIT_VERSION:-0.1.0}"
SIGN_IDENTITY="${INSIGHTKIT_SIGN_IDENTITY:-}"
SIGN_IDENTITY_FILE="$ROOT_DIR/.ops/signing_identity.txt"
CLEAN_BUILD=0

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
  --adhoc-sign                 Force ad-hoc signing (not recommended; may trigger repeated permission prompts)
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
      shift 2
      ;;
    --adhoc-sign)
      SIGN_IDENTITY="-"
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

if [[ -z "${SIGN_IDENTITY}" ]]; then
  if command -v security >/dev/null 2>&1; then
    SIGN_IDENTITY="$(
      security find-identity -v -p codesigning 2>/dev/null \
      | awk -F'"' '/Developer ID Application:/ {print $2; exit}'
    )"
    if [[ -z "${SIGN_IDENTITY}" ]]; then
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

if [[ "$SIGN_IDENTITY" != "-" ]]; then
  mkdir -p "$(dirname "$SIGN_IDENTITY_FILE")"
  printf '%s\n' "$SIGN_IDENTITY" > "$SIGN_IDENTITY_FILE"
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

mkdir -p "$runtime_root"
cp -R "$ROOT_DIR/scripts" "$runtime_root/"
cp -R "$ROOT_DIR/insightkit" "$runtime_root/"
find "$runtime_root" -name "__pycache__" -type d -prune -exec rm -rf {} +
find "$runtime_root" -name "*.pyc" -type f -delete

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
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
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
  <key>NSScreenCaptureUsageDescription</key>
  <string>InsightKit 需要屏幕录制权限用于系统音频采集与实时洞察。</string>
  <key>NSCameraUsageDescription</key>
  <string>InsightKit 需要摄像头权限用于视频捕获。</string>
</dict>
</plist>
EOF

if command -v codesign >/dev/null 2>&1; then
  if command -v xattr >/dev/null 2>&1; then
    xattr -cr "$app_root" || true
  fi
  if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "Warning: using ad-hoc signing. macOS privacy permissions may re-prompt after updates." >&2
    codesign --force --deep --sign - "$app_root" >/dev/null 2>&1 || true
  else
    echo "Signing with identity: $SIGN_IDENTITY"
    if ! sign_output="$(codesign --force --deep --timestamp=none --sign "$SIGN_IDENTITY" "$app_root" 2>&1)"; then
      if echo "$sign_output" | grep -Eqi "resource fork|Finder information|detritus"; then
        echo "Detected extended-attribute detritus under output dir; retry signing in /tmp staging."
        stage_dir="$(mktemp -d /tmp/insightkit-sign.XXXXXX)"
        stage_app="$stage_dir/$APP_BUNDLE_NAME"
        ditto "$app_root" "$stage_app"
        if command -v xattr >/dev/null 2>&1; then
          xattr -cr "$stage_app" || true
        fi
        codesign --force --deep --timestamp=none --sign "$SIGN_IDENTITY" "$stage_app"
        rm -rf "$app_root"
        ditto "$stage_app" "$app_root"
        rm -rf "$stage_dir"
      else
        echo "$sign_output" >&2
        exit 1
      fi
    fi
  fi
fi

if [[ -n "$INSTALL_DIR" ]]; then
  mkdir -p "$INSTALL_DIR"
  rm -rf "$INSTALL_DIR/$APP_BUNDLE_NAME"
  cp -R "$app_root" "$INSTALL_DIR/"
  echo "Installed: $INSTALL_DIR/$APP_BUNDLE_NAME"
fi

echo "Built app bundle: $app_root"
echo "Open with: open \"$app_root\""
echo "Code signing identity: $SIGN_IDENTITY"
echo "Git revision: $GIT_REVISION ($BUILD_SOURCE)"
