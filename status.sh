#!/bin/bash
# 查看自动转录服务状态
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.yann.autotranscribe"

SERVICE_LINE="$(launchctl list 2>/dev/null | awk -v label="$LABEL" '$3 == label {print $0}')"

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  🎙 自动转录系统状态"
echo "═══════════════════════════════════════════════════════════"
echo ""

# 检查服务是否运行（精确匹配主服务 label，避免误匹配 update agent）
if [ -n "$SERVICE_LINE" ]; then
    PID=$(echo "$SERVICE_LINE" | awk '{print $1}')
    STATUS_CODE=$(echo "$SERVICE_LINE" | awk '{print $2}')
    if [ "$PID" != "-" ]; then
        echo "  🟢 服务状态: 运行中 (PID: ${PID})"
    else
        echo "  🟡 服务状态: 已加载但未运行 (LastExitStatus: ${STATUS_CODE})"
    fi
else
    echo "  🔴 服务状态: 已停止"
fi

# 统计文件
VIDEO_COUNT=$(find "${SCRIPT_DIR}/video" -type f 2>/dev/null | wc -l | tr -d ' ')
TXT_COUNT=$(find "${SCRIPT_DIR}/txt" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
FAIL_COUNT=$(find "${SCRIPT_DIR}/video" -name "fail_*" -type f 2>/dev/null | wc -l | tr -d ' ')

echo "  📹 已处理音视频: ${VIDEO_COUNT}"
echo "  📝 转录文稿: ${TXT_COUNT}"
echo "  ❌ 失败文件: ${FAIL_COUNT}"
echo ""

# 当前转录进度
STATUS_FILE="${SCRIPT_DIR}/logs/status.json"
if [ -f "$STATUS_FILE" ]; then
    STATE=$(python3 -c "import json; d=json.load(open('$STATUS_FILE')); print(d.get('state',''))" 2>/dev/null)
    if [ -n "$STATE" ] && [ "$STATE" != "idle" ]; then
        LABEL=$(python3 -c "import json; d=json.load(open('$STATUS_FILE')); print(d.get('state_label',''))" 2>/dev/null)
        FNAME=$(python3 -c "import json; d=json.load(open('$STATUS_FILE')); print(d.get('filename',''))" 2>/dev/null)
        PCT=$(python3 -c "import json; d=json.load(open('$STATUS_FILE')); print(d.get('progress',0))" 2>/dev/null)
        ELAPSED=$(python3 -c "import json; d=json.load(open('$STATUS_FILE')); print(d.get('elapsed',''))" 2>/dev/null)
        echo "  🔄 当前任务: ${LABEL}"
        echo "  📄 文件: ${FNAME}"
        echo "  📊 进度: ${PCT}%  ⏳ 已用: ${ELAPSED}"
        echo ""
    fi
fi

# 最近5条日志
LOG="${SCRIPT_DIR}/logs/transcribe.log"
if [ -f "$LOG" ]; then
    echo "  📋 最近日志:"
    echo "  ─────────────────────────────────────────"
    tail -5 "$LOG" | sed 's/^/  /'
    echo ""
    echo "  💡 完整日志: tail -f ${LOG}"
    echo "  💡 实时监控: bash monitor.sh"
fi

echo ""
