#!/bin/bash
# 停止自动转录服务
PLIST="$HOME/Library/LaunchAgents/com.yann.autotranscribe.plist"

if [ ! -f "$PLIST" ]; then
    echo "❌ 未找到 LaunchAgent"
    exit 1
fi

launchctl unload "$PLIST" 2>/dev/null
echo "🛑 自动转录服务已停止"
