#!/bin/bash
# 启动自动转录服务
PLIST="$HOME/Library/LaunchAgents/com.yann.autotranscribe.plist"

if [ ! -f "$PLIST" ]; then
    echo "❌ 未找到 LaunchAgent，请先运行 install.sh"
    exit 1
fi

# 检查是否已运行
if launchctl list | grep -q "com.yann.autotranscribe"; then
    echo "⚠️  服务已在运行中"
    echo "💡 使用 bash stop.sh 先停止服务"
    exit 0
fi

launchctl load "$PLIST"
echo "✅ 自动转录服务已启动"
echo "💡 查看日志: tail -f $(dirname "$0")/logs/transcribe.log"
