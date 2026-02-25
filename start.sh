#!/bin/bash
# 启动自动转录服务

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.yann.autotranscribe"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
UID_NUM="$(id -u)"
LOG_PATH="${SCRIPT_DIR}/logs/transcribe.log"
LAUNCHD_LOG_DIR="$HOME/Library/Logs/AutoTranscribe"
LAUNCHD_STDOUT="${LAUNCHD_LOG_DIR}/launchd_stdout.log"
LAUNCHD_STDERR="${LAUNCHD_LOG_DIR}/launchd_stderr.log"

resolve_python_path() {
    if [ -x "$HOME/miniconda3/envs/transcribe/bin/python" ]; then
        echo "$HOME/miniconda3/envs/transcribe/bin/python"
        return 0
    fi
    if [ -x "$HOME/anaconda3/envs/transcribe/bin/python" ]; then
        echo "$HOME/anaconda3/envs/transcribe/bin/python"
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        command -v python3
        return 0
    fi
    echo "/usr/bin/python3"
}

PYTHON_PATH="$(resolve_python_path)"
PYTHON_DIR="$(dirname "$PYTHON_PATH")"

service_line() {
    launchctl list 2>/dev/null | awk -v label="$LABEL" '$3 == label {print $0}'
}

is_loaded() {
    [ -n "$(service_line)" ]
}

is_running() {
    local line pid
    line="$(service_line)"
    [ -z "$line" ] && return 1
    pid="$(echo "$line" | awk '{print $1}')"
    [ "$pid" != "-" ]
}

ensure_plist() {
    # Desktop 路径受 TCC 保护，launchd stdout/stderr 需写到 ~/Library/Logs
    mkdir -p "$LAUNCHD_LOG_DIR"

    # 自动修复旧版/损坏的 plist（例如错误 ProgramArguments 或旧日志路径）
    if [ ! -f "$PLIST" ] || \
       ! grep -Fq "${SCRIPT_DIR}/scripts/main.py" "$PLIST" || \
       ! grep -Fq "${LAUNCHD_STDOUT}" "$PLIST"; then
        cat > "$PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${PYTHON_PATH}</string>
        <string>${SCRIPT_DIR}/scripts/main.py</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${SCRIPT_DIR}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LAUNCHD_STDOUT}</string>
    <key>StandardErrorPath</key>
    <string>${LAUNCHD_STDERR}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>${PYTHON_DIR}:/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin</string>
    </dict>
</dict>
</plist>
EOF
    fi

    if ! plutil -lint "$PLIST" >/dev/null 2>&1; then
        echo "❌ LaunchAgent plist 格式无效: $PLIST"
        echo "💡 请执行: bash install.sh"
        exit 1
    fi
}

ensure_plist

if is_running; then
    echo "⚠️  服务已在运行中"
    echo "💡 使用 bash stop.sh 先停止服务"
    exit 0
fi

# 清理可能存在的僵尸定义（已加载但无进程）
launchctl bootout "gui/${UID_NUM}/${LABEL}" >/dev/null 2>&1 || true
launchctl unload "$PLIST" >/dev/null 2>&1 || true

if ! launchctl bootstrap "gui/${UID_NUM}" "$PLIST" >/tmp/autotranscribe_start.err 2>&1; then
    # 兼容旧系统
    if ! launchctl load "$PLIST" >>/tmp/autotranscribe_start.err 2>&1; then
        echo "❌ 启动失败（LaunchAgent 未加载）"
        echo "────────────────────────────────────────"
        cat /tmp/autotranscribe_start.err
        echo "────────────────────────────────────────"
        echo "💡 建议先执行: bash install.sh"
        exit 1
    fi
fi

running=0
for _ in 1 2 3 4 5 6 7 8; do
    if is_running; then
        running=1
        break
    fi
    sleep 1
done

if is_loaded; then
    if [ "$running" -eq 1 ]; then
        echo "✅ 自动转录服务已启动"
    else
        echo "⚠️  LaunchAgent 已加载，但进程未保持运行（可能启动后立即退出）"
        echo "💡 查看日志: tail -f ${LOG_PATH}"
        if [ -f "$LAUNCHD_STDERR" ]; then
            echo "💡 launchd stderr: tail -f ${LAUNCHD_STDERR}"
        fi
        exit 1
    fi
    echo "💡 查看日志: tail -f ${LOG_PATH}"
else
    echo "❌ 启动失败：未在 launchctl 中找到 ${LABEL}"
    echo "💡 查看日志: tail -f ${LOG_PATH}"
    exit 1
fi
