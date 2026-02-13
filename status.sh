#!/bin/bash
# 查看自动转录服务状态
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  🎙 自动转录系统状态"
echo "═══════════════════════════════════════════════════════════"
echo ""

# 检查服务是否运行
if launchctl list | grep -q "com.yann.autotranscribe"; then
    echo "  🟢 服务状态: 运行中"
else
    echo "  🔴 服务状态: 已停止"
fi

# 统计文件
VIDEO_COUNT=$(find "${SCRIPT_DIR}/video" -type f 2>/dev/null | wc -l | tr -d ' ')
TXT_COUNT=$(find "${SCRIPT_DIR}/txt" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
FAIL_COUNT=$(find "${SCRIPT_DIR}/video" -name "fail_*" -type f 2>/dev/null | wc -l | tr -d ' ')

echo "  📹 已转录视频: ${VIDEO_COUNT}"
echo "  📝 转录文稿: ${TXT_COUNT}"
echo "  ❌ 失败文件: ${FAIL_COUNT}"
echo ""

# 最近5条日志
LOG="${SCRIPT_DIR}/logs/transcribe.log"
if [ -f "$LOG" ]; then
    echo "  📋 最近日志:"
    echo "  ─────────────────────────────────────────"
    tail -5 "$LOG" | sed 's/^/  /'
    echo ""
    echo "  💡 完整日志: tail -f ${LOG}"
fi

echo ""
