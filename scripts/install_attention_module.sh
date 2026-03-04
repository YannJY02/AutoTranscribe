#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODULE_DIST="${ROOT_DIR}/dist/attentionos-insightkit-module"
APP_MODULE_DIR="$HOME/Library/Application Support/AttentionOS/modules/insightkit-meeting-module"
RSS_DEV_PLUGIN_DIR="/Users/yann.jy/Desktop/AI/RSS/plugins/generated/insightkit-meeting-module"

python3 "${ROOT_DIR}/scripts/export_attention_module.py" --output "$MODULE_DIST"

mkdir -p "$APP_MODULE_DIR"
cp -R "$MODULE_DIST"/* "$APP_MODULE_DIR"/

echo "installed to: $APP_MODULE_DIR"

if [ -d "/Users/yann.jy/Desktop/AI/RSS/plugins/generated" ]; then
  mkdir -p "$RSS_DEV_PLUGIN_DIR"
  cp -R "$MODULE_DIST"/* "$RSS_DEV_PLUGIN_DIR"/
  echo "synced to RSS dev plugin dir: $RSS_DEV_PLUGIN_DIR"
fi
