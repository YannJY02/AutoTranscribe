"""配置文件 — 自动转录系统所有常量。"""

import os
from pathlib import Path

try:
    from .asr_model_catalog import (
        FUNASR_DEFAULT_ASR_MODEL,
        FUNASR_LID_MODEL,
        FUNASR_PUNC_MODEL,
        FUNASR_SPK_MODEL,
        FUNASR_VAD_MODEL,
    )
except ImportError:
    from asr_model_catalog import (
        FUNASR_DEFAULT_ASR_MODEL,
        FUNASR_LID_MODEL,
        FUNASR_PUNC_MODEL,
        FUNASR_SPK_MODEL,
        FUNASR_VAD_MODEL,
    )

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

# ── 可处理扩展名 ──────────────────────────────────────────
VIDEO_EXTENSIONS = {
    ".mp4", ".mkv", ".avi", ".mov", ".webm",
    ".flv", ".m4v", ".wmv", ".ts", ".mpg", ".mpeg",
}

AUDIO_EXTENSIONS = {
    ".mp3", ".wav", ".m4a", ".flac", ".aac",
    ".ogg", ".opus", ".wma", ".aiff", ".aif",
}

MEDIA_EXTENSIONS = VIDEO_EXTENSIONS | AUDIO_EXTENSIONS

# ── 转录参数 ────────────────────────────────────────────
MIN_SPEAKERS = 2
MAX_SPEAKERS = 4

# ── 模型名称（FunASR） ────────────────────────────────────
LID_MODEL = FUNASR_LID_MODEL          # 语言识别 + 轻量 ASR
ASR_MODEL_ZH = FUNASR_DEFAULT_ASR_MODEL
VAD_MODEL = FUNASR_VAD_MODEL
PUNC_MODEL = FUNASR_PUNC_MODEL
SPK_MODEL = FUNASR_SPK_MODEL

# ── 资源管理 ──────────────────────────────────────────────
FILE_STABLE_CHECK_INTERVAL = 2  # 秒，检查文件写入完成的间隔
FILE_STABLE_MAX_WAIT = 300  # 秒，最长等待文件写入完成（5 分钟）

# ── 确保目录存在 ──────────────────────────────────────────
for d in [VIDEO_DIR, TXT_DIR, LOG_DIR]:
    d.mkdir(parents=True, exist_ok=True)
