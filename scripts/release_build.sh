#!/usr/bin/env bash
# release_build.sh — 生成可审计的 macOS release/QA zip 产物
#
# 默认产物是 local/internal QA 包，不是公开分发包。公开直分发必须先具备
# Developer ID Application 证书、hardened runtime、notarization 与 stapling 证据。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_SCRIPT="$ROOT_DIR/scripts/package_insightkit_app.sh"
PREFLIGHT_SCRIPT="$ROOT_DIR/scripts/release_preflight.sh"
RELEASES_DIR="$ROOT_DIR/dist/releases"
DISTRIBUTION_MODE="${INSIGHTKIT_DISTRIBUTION:-local}"

# 从 git tag 自动提取版本号（如 v0.2.0 → 0.2.0）
GIT_TAG="$(git -C "$ROOT_DIR" describe --tags --exact-match 2>/dev/null || true)"
if [[ -n "$GIT_TAG" ]]; then
  VERSION="${GIT_TAG#v}"
else
  VERSION=""
fi

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

构建 InsightKit macOS .app，并打包为 .zip。

默认模式为 local：用于本机/内部 QA 验证，不承诺 Gatekeeper 公开分发。
Developer ID 模式会要求本机存在 Developer ID Application 证书；当前脚本仍不执行 notarization/stapling。

Options:
  --version <semver>        版本号（如 0.2.0）。未指定时从 git tag 自动提取。
  --distribution <mode>     local 或 developer-id（默认：$DISTRIBUTION_MODE）
  --developer-id            等同于 --distribution developer-id
  --output-dir <path>       zip 输出目录（默认：dist/releases）
  -h, --help                显示帮助

示例：
  # 先打 git tag，再构建本地 QA 包
  git tag v0.2.0
  ./scripts/release_build.sh

  # 或手动指定版本号，构建本地 QA 包
  ./scripts/release_build.sh --version 0.2.0

  # 尝试 Developer ID 签名包；没有 Developer ID 证书时会失败
  ./scripts/release_build.sh --version 0.2.0 --developer-id

产出文件：
  local:        dist/releases/InsightKit-{version}-macos-local-{timestamp}.zip
  developer-id: dist/releases/InsightKit-{version}-macos-developer-id-unnotarized-{timestamp}.zip

公开发布前额外 gate：
  1. Developer ID Application 签名
  2. Hardened runtime
  3. notarytool notarization 成功
  4. staple ticket 成功
  5. 干净机器 Gatekeeper / spctl 验证通过
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --distribution) DISTRIBUTION_MODE="${2:-}"; shift 2 ;;
    --developer-id) DISTRIBUTION_MODE="developer-id"; shift ;;
    --output-dir) RELEASES_DIR="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

case "$DISTRIBUTION_MODE" in
  local|developer-id) ;;
  *)
    echo "错误：未知 distribution mode：$DISTRIBUTION_MODE" >&2
    usage
    exit 1
    ;;
esac

if [[ -z "$VERSION" ]]; then
  echo "错误：未指定版本号，且当前 commit 没有对应的 git tag。" >&2
  echo "请运行：git tag v0.x.x && ./scripts/release_build.sh" >&2
  echo "或运行：./scripts/release_build.sh --version 0.x.x" >&2
  exit 1
fi

BUILD_STAMP="$(date +%Y%m%d%H%M%S)"
if [[ "$DISTRIBUTION_MODE" == "developer-id" ]]; then
  ZIP_NAME="InsightKit-${VERSION}-macos-developer-id-unnotarized-${BUILD_STAMP}.zip"
else
  ZIP_NAME="InsightKit-${VERSION}-macos-local-${BUILD_STAMP}.zip"
fi
ZIP_PATH="$RELEASES_DIR/$ZIP_NAME"
STAGING_DIR="$(mktemp -d "/private/tmp/insightkit-release-${VERSION}-${DISTRIBUTION_MODE}.XXXXXX")"
STAGING_OUTPUT="$STAGING_DIR/app"
APP_BUNDLE="$STAGING_OUTPUT/InsightKit.app"
PREFLIGHT_LOG="$RELEASES_DIR/InsightKit-${VERSION}-${DISTRIBUTION_MODE}-${BUILD_STAMP}-preflight.txt"

echo "==> [release_build] 版本：$VERSION"
echo "==> [release_build] distribution：$DISTRIBUTION_MODE"
echo "==> [release_build] staging：$STAGING_DIR"
echo "==> [release_build] 构建 app bundle（--clean）..."
mkdir -p "$RELEASES_DIR"
RELEASES_DIR="$(cd "$RELEASES_DIR" && pwd)"
ZIP_PATH="$RELEASES_DIR/$ZIP_NAME"
PREFLIGHT_LOG="$RELEASES_DIR/InsightKit-${VERSION}-${DISTRIBUTION_MODE}-${BUILD_STAMP}-preflight.txt"

"$PACKAGE_SCRIPT" --clean --version "$VERSION" --distribution "$DISTRIBUTION_MODE" --output-dir "$STAGING_OUTPUT"

echo "==> [release_build] 运行 release preflight..."
if [[ "$DISTRIBUTION_MODE" == "developer-id" ]]; then
  "$PREFLIGHT_SCRIPT" --developer-id "$APP_BUNDLE" | tee "$PREFLIGHT_LOG"
else
  "$PREFLIGHT_SCRIPT" "$APP_BUNDLE" | tee "$PREFLIGHT_LOG"
fi

echo "==> [release_build] 打包为 .zip..."
if [[ -e "$ZIP_PATH" ]]; then
  echo "错误：产物已存在，未覆盖：$ZIP_PATH" >&2
  exit 1
fi

# 使用 zip 保留 app 目录和可执行权限，但不复制 com.apple.provenance 等扩展属性。
# ditto 会把这些 xattr 转成 AppleDouble 条目，导致 zip 出现 __MACOSX/._*。
APP_PARENT="$(dirname "$APP_BUNDLE")"
APP_BASENAME="$(basename "$APP_BUNDLE")"
(cd "$APP_PARENT" && COPYFILE_DISABLE=1 /usr/bin/zip -qry --symlinks "$ZIP_PATH" "$APP_BASENAME")

if unzip -Z1 "$ZIP_PATH" | grep -E '(^|/)__MACOSX(/|$)|(^|/)\._' >/dev/null; then
  echo "错误：zip 包含 __MACOSX 或 AppleDouble 条目，请清理扩展属性后重新打包：$ZIP_PATH" >&2
  exit 1
fi

ZIP_SIZE="$(du -sh "$ZIP_PATH" | cut -f1)"
GIT_REV="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")"

echo ""
echo "✓ Release 构建完成"
echo "  版本：$VERSION"
echo "  Distribution：$DISTRIBUTION_MODE"
echo "  Git revision：$GIT_REV"
echo "  产物：${ZIP_PATH} (${ZIP_SIZE})"
echo "  App staging：${APP_BUNDLE}"
echo "  Preflight：${PREFLIGHT_LOG}"
echo ""
if [[ "$DISTRIBUTION_MODE" == "developer-id" ]]; then
  echo "注意：该产物仅证明 Developer ID 签名打包成功；文件名包含 unnotarized，因为本脚本未执行 notarization/stapling。"
  echo "公开分发前仍需运行 notarytool、stapler，并在干净机器上做 Gatekeeper 验证。"
else
  echo "注意：这是 local/internal QA 包，不是公开分发包。不要上传为面向普通用户的 GitHub Release。"
fi
