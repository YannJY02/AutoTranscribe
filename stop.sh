#!/bin/bash
# 停止自动转录服务

set -u

LABEL="com.yann.autotranscribe"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
UID_NUM="$(id -u)"

service_line() {
    launchctl list 2>/dev/null | awk -v label="$LABEL" '$3 == label {print $0}'
}

is_loaded() {
    [ -n "$(service_line)" ]
}

if [ ! -f "$PLIST" ]; then
    echo "❌ 未找到 LaunchAgent: $PLIST"
    exit 1
fi

if ! is_loaded; then
    echo "ℹ️  服务未运行（已是停止状态）"
    exit 0
fi

if ! launchctl bootout "gui/${UID_NUM}/${LABEL}" >/tmp/autotranscribe_stop.err 2>&1; then
    # 兼容旧系统
    launchctl unload "$PLIST" >>/tmp/autotranscribe_stop.err 2>&1 || true
fi

sleep 1
if is_loaded; then
    echo "⚠️  停止请求已发送，但服务仍显示已加载"
    echo "────────────────────────────────────────"
    cat /tmp/autotranscribe_stop.err
    echo "────────────────────────────────────────"
    exit 1
fi

echo "🛑 自动转录服务已停止"
