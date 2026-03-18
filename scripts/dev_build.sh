#!/usr/bin/env bash
# dev_build.sh — 开发迭代快速构建并打开 app
# 用法：./scripts/dev_build.sh [--no-open] [--clean]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_SCRIPT="$ROOT_DIR/scripts/package_insightkit_app.sh"
INSTALL_DIR="$HOME/Applications"
AUTO_OPEN=1
CLEAN_FLAG="--no-clean"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

快速构建 debug bundle 并安装到 ~/Applications，然后打开 app。

Options:
  --no-open    构建后不自动打开 app
  --clean      构建前清理 Swift 缓存（较慢，首次或遇到奇怪错误时使用）
  -h, --help   显示帮助
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-open) AUTO_OPEN=0; shift ;;
    --clean)   CLEAN_FLAG="--clean"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

echo "==> [dev_build] 构建 debug bundle..."
"$PACKAGE_SCRIPT" --debug $CLEAN_FLAG --install-dir "$INSTALL_DIR"

APP_PATH="$INSTALL_DIR/InsightKit.app"

if [[ "$AUTO_OPEN" -eq 1 ]]; then
  echo "==> [dev_build] 打开 app: $APP_PATH"
  open "$APP_PATH"
fi

echo ""
echo "✓ 开发构建完成：$APP_PATH"
echo "  如需手动打开：open \"$APP_PATH\""
