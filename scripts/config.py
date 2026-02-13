"""配置文件 — 自动转录系统所有常量。"""

import os
from pathlib import Path

# ── 基础路径 ──────────────────────────────────────────────
BASE_DIR = Path(__file__).resolve().parent.parent
VIDEO_DIR = BASE_DIR / "video"
TXT_DIR = BASE_DIR / "txt"
LOG_DIR = BASE_DIR / "logs"
PROCESSED_FILE = BASE_DIR / "logs" / "processed.json"
LOG_FILE = BASE_DIR / "logs" / "transcribe.log"

# ── 监控目录 ──────────────────────────────────────────────
WATCH_DIRS = [
    Path.home() / "Desktop",
    Path.home() / "Downloads",
]

# ── 视频扩展名 ────────────────────────────────────────────
VIDEO_EXTENSIONS = {
    ".mp4", ".mkv", ".avi", ".mov", ".webm",
    ".flv", ".m4v", ".wmv", ".ts", ".mpg", ".mpeg",
}

# ── 转录参数 ────────────────────────────────────────────
MIN_SPEAKERS = 2
MAX_SPEAKERS = 4

# ── 模型名称（FunASR） ────────────────────────────────────
LID_MODEL = "iic/SenseVoiceSmall"          # 语言识别 + 轻量 ASR
ASR_MODEL_ZH = "iic/speech_paraformer-large-vad-punc_asr_nat-zh-cn-16k-common-vocab8404-pytorch"
VAD_MODEL = "iic/speech_fsmn_vad_zh-cn-16k-common-pytorch"
PUNC_MODEL = "iic/punc_ct-transformer_zh-cn-common-vocab272727-pytorch"
SPK_MODEL = "iic/speech_campplus_sv_zh-cn_16k-common"

# ── 资源管理 ──────────────────────────────────────────────
FILE_STABLE_CHECK_INTERVAL = 2  # 秒，检查文件写入完成的间隔
FILE_STABLE_MAX_WAIT = 300  # 秒，最长等待文件写入完成（5 分钟）

# ── 确保目录存在 ──────────────────────────────────────────
for d in [VIDEO_DIR, TXT_DIR, LOG_DIR]:
    d.mkdir(parents=True, exist_ok=True)
