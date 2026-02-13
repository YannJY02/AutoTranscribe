#!/bin/bash
# ═══════════════════════════════════════════════════════════
# 🎙 自动转录系统 — 一键安装脚本
# ═══════════════════════════════════════════════════════════
#
# 使用方法: bash install.sh
#
# 脚本会自动:
#   1. 创建 conda 环境 (transcribe)
#   2. 安装所有依赖
#   3. 创建目录结构
#   4. 注册开机自启
#   5. 启动服务
# ═══════════════════════════════════════════════════════════

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_NAME="transcribe"
PLIST_NAME="com.yann.autotranscribe"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"

# 颜色
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[  OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail()  { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  🎙 自动转录系统 — 一键安装"
echo "═══════════════════════════════════════════════════════════"
echo ""

# ── 检查 conda ──────────────────────────────────────────
info "检查 conda..."
if ! command -v conda &>/dev/null; then
    fail "未找到 conda，请先安装 Miniconda: https://docs.conda.io/en/latest/miniconda.html"
fi
ok "conda 已安装"

# ── 检查 ffmpeg ─────────────────────────────────────────
info "检查 ffmpeg..."
if ! command -v ffmpeg &>/dev/null; then
    info "安装 ffmpeg..."
    brew install ffmpeg || fail "ffmpeg 安装失败"
fi
ok "ffmpeg 已安装"

# ── 创建/更新 conda 环境 ────────────────────────────────
info "配置 conda 环境 '${ENV_NAME}'..."

# 获取 conda base 路径
CONDA_BASE="$(conda info --base)"

if conda env list | grep -qw "$ENV_NAME"; then
    ok "环境 '${ENV_NAME}' 已存在，更新依赖..."
    # 激活环境并安装
    source "${CONDA_BASE}/etc/profile.d/conda.sh"
    conda activate "$ENV_NAME"
else
    info "创建新环境 '${ENV_NAME}' (Python 3.11)..."
    conda create -n "$ENV_NAME" python=3.11 -y
    source "${CONDA_BASE}/etc/profile.d/conda.sh"
    conda activate "$ENV_NAME"
    ok "环境创建完成"
fi

# ── 安装 Python 依赖 ────────────────────────────────────
info "安装 Python 依赖 (funasr, torch, watchdog)..."
info "这可能需要几分钟，请耐心等待..."

pip install --upgrade pip -q
pip install funasr modelscope torch torchaudio watchdog -q

ok "Python 依赖安装完成"

# ── 获取 Python 路径 ────────────────────────────────────
PYTHON_PATH="$(which python)"
info "Python 路径: ${PYTHON_PATH}"

# ── 创建目录结构 ────────────────────────────────────────
info "创建目录结构..."
mkdir -p "${SCRIPT_DIR}/video"
mkdir -p "${SCRIPT_DIR}/txt"
mkdir -p "${SCRIPT_DIR}/logs"
mkdir -p "${SCRIPT_DIR}/scripts"
ok "目录结构就绪"

# ── 创建 LaunchAgent ────────────────────────────────────
info "配置开机自启..."

cat > "$PLIST_PATH" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_NAME}</string>
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
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>StandardOutPath</key>
    <string>${SCRIPT_DIR}/logs/launchd_stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${SCRIPT_DIR}/logs/launchd_stderr.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>${CONDA_BASE}/envs/${ENV_NAME}/bin:/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin</string>
    </dict>
</dict>
</plist>
PLIST_EOF

ok "LaunchAgent 已创建: ${PLIST_PATH}"

# ── 创建每周更新 LaunchAgent ────────────────────────────
info "配置每周自动更新..."
UPDATE_PLIST_PATH="$HOME/Library/LaunchAgents/com.yann.autotranscribe.update.plist"

cat > "$UPDATE_PLIST_PATH" << UPDATE_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.yann.autotranscribe.update</string>
    <key>ProgramArguments</key>
    <array>
        <string>${PYTHON_PATH}</string>
        <string>${SCRIPT_DIR}/scripts/update.py</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${SCRIPT_DIR}</string>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Weekday</key>
        <integer>0</integer>
        <key>Hour</key>
        <integer>3</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>${SCRIPT_DIR}/logs/update_stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${SCRIPT_DIR}/logs/update_stderr.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>${CONDA_BASE}/envs/${ENV_NAME}/bin:/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin</string>
    </dict>
</dict>
</plist>
UPDATE_EOF

launchctl unload "$UPDATE_PLIST_PATH" 2>/dev/null || true
launchctl load "$UPDATE_PLIST_PATH"
ok "每周更新已配置 (每周日 03:00)"

# ── 加载 LaunchAgent ────────────────────────────────────
info "启动服务..."
# 先卸载旧的（如果存在）
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"
ok "服务已启动"

# ── 完成 ────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════"
echo -e "  ${GREEN}✅ 安装完成！${NC}"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "  📂 监控目录: ~/Desktop, ~/Downloads"
echo "  📹 视频存放: ${SCRIPT_DIR}/video/"
echo "  📝 转录输出: ${SCRIPT_DIR}/txt/"
echo "  📋 运行日志: ${SCRIPT_DIR}/logs/"
echo ""
echo "  常用命令:"
echo "    bash ${SCRIPT_DIR}/start.sh    # 启动服务"
echo "    bash ${SCRIPT_DIR}/stop.sh     # 停止服务"
echo "    bash ${SCRIPT_DIR}/status.sh   # 查看状态"
echo ""
echo "  💡 首次转录时会自动下载模型 (~1-2 GB)，请保持网络连接。"
echo ""
