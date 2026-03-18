#!/usr/bin/env bash
# release_build.sh — 生成可分发的 release 产物（.zip）
# 用法：./scripts/release_build.sh [--version v0.2.0]
#
# 产出：dist/releases/InsightKit-{version}-macos.zip
# 分发方式：上传到 GitHub Releases（手动或 gh release create）
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_SCRIPT="$ROOT_DIR/scripts/package_insightkit_app.sh"
RELEASES_DIR="$ROOT_DIR/dist/releases"

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

构建 release bundle 并打包为 .zip，用于 GitHub Releases 分发。

Options:
  --version <semver>   版本号（如 0.2.0）。未指定时从 git tag 自动提取。
  -h, --help           显示帮助

示例：
  # 先打 git tag，再构建（推荐）
  git tag v0.2.0
  ./scripts/release_build.sh

  # 或手动指定版本号
  ./scripts/release_build.sh --version 0.2.0

产出文件：
  dist/releases/InsightKit-{version}-macos.zip

GitHub 发布步骤：
  1. 运行本脚本生成 .zip
  2. 在 GitHub 创建 Release（对应 git tag）
  3. 上传 dist/releases/InsightKit-{version}-macos.zip
  4. 用户下载后解压，将 InsightKit.app 拖入 Applications 即可
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "错误：未指定版本号，且当前 commit 没有对应的 git tag。" >&2
  echo "请运行：git tag v0.x.x && ./scripts/release_build.sh" >&2
  echo "或运行：./scripts/release_build.sh --version 0.x.x" >&2
  exit 1
fi

ZIP_NAME="InsightKit-${VERSION}-macos.zip"
ZIP_PATH="$RELEASES_DIR/$ZIP_NAME"
STAGING_DIR="$RELEASES_DIR/staging-${VERSION}"
APP_BUNDLE="$ROOT_DIR/dist/macos/InsightKit.app"

echo "==> [release_build] 版本：$VERSION"
echo "==> [release_build] 构建 release bundle（--clean）..."
"$PACKAGE_SCRIPT" --clean --version "$VERSION"

echo "==> [release_build] 打包为 .zip..."
mkdir -p "$RELEASES_DIR"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

# 使用 ditto 保留 macOS 扩展属性和符号链接
ditto "$APP_BUNDLE" "$STAGING_DIR/InsightKit.app"

# 创建 zip（ditto 方式，保留 macOS 元数据）
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$STAGING_DIR/InsightKit.app" "$ZIP_PATH"
rm -rf "$STAGING_DIR"

ZIP_SIZE="$(du -sh "$ZIP_PATH" | cut -f1)"
GIT_REV="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")"

echo ""
echo "✓ Release 构建完成"
echo "  版本：$VERSION"
echo "  Git revision：$GIT_REV"
echo "  产物：$ZIP_PATH（$ZIP_SIZE）"
echo ""
echo "GitHub 发布步骤："
echo "  1. 前往 https://github.com/你的用户名/你的仓库/releases/new"
echo "  2. 选择 tag：v${VERSION}"
echo "  3. 上传文件：$ZIP_PATH"
echo "  4. 发布"
echo ""
echo "  或使用 gh CLI（需安装 GitHub CLI）："
echo "  gh release create v${VERSION} \"$ZIP_PATH\" --title \"InsightKit v${VERSION}\" --notes \"\""
