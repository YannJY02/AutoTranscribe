#!/usr/bin/env python3
"""
每周自动更新 — FunASR 模型 + Python 依赖。

由 LaunchAgent 每周自动执行，也可手动运行:
    conda activate transcribe && python scripts/update.py
"""

import json
import logging
import subprocess
import sys
import os
from datetime import datetime
from pathlib import Path

# 将 scripts/ 目录加入 Python 路径
sys.path.insert(0, str(Path(__file__).resolve().parent))

from config import LOG_DIR, BASE_DIR

# ── 日志 ──────────────────────────────────────────────────

UPDATE_LOG = LOG_DIR / "update.log"
LOG_DIR.mkdir(parents=True, exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    handlers=[
        logging.FileHandler(UPDATE_LOG, encoding="utf-8"),
        logging.StreamHandler(sys.stdout),
    ],
)
logger = logging.getLogger(__name__)

# ── 需要更新的模型（与 config.py 保持一致）──────────────

MODELS = [
    "iic/SenseVoiceSmall",
    "iic/speech_paraformer-large-vad-punc_asr_nat-zh-cn-16k-common-vocab8404-pytorch",
    "iic/speech_fsmn_vad_zh-cn-16k-common-pytorch",
    "iic/punc_ct-transformer_zh-cn-common-vocab272727-pytorch",
    "iic/speech_campplus_sv_zh-cn_16k-common",
]

# ── 需要更新的 pip 包 ────────────────────────────────────

PIP_PACKAGES = [
    "funasr",
    "modelscope",
    "torch",
    "torchaudio",
    "watchdog",
]


def update_pip_packages() -> list[str]:
    """更新 pip 包，返回实际更新的包列表。"""
    updated = []
    logger.info("📦 检查 pip 依赖更新...")

    for pkg in PIP_PACKAGES:
        try:
            result = subprocess.run(
                [sys.executable, "-m", "pip", "install", "--upgrade", pkg, "-q"],
                capture_output=True, text=True, timeout=300,
            )
            output = result.stdout + result.stderr
            # 判断是否有实际更新（不是 "already satisfied"）
            if "Successfully installed" in output:
                updated.append(pkg)
                logger.info(f"  ✅ {pkg}: 已更新")
            else:
                logger.info(f"  ✔️  {pkg}: 已是最新")
        except Exception as e:
            logger.error(f"  ❌ {pkg}: 更新失败 - {e}")

    return updated


def update_models() -> list[str]:
    """通过 modelscope snapshot_download 检查并更新模型。"""
    updated = []
    logger.info("🧠 检查 FunASR 模型更新...")

    try:
        from modelscope.hub.snapshot_download import snapshot_download
    except ImportError:
        # modelscope 新版本 API
        try:
            from modelscope import snapshot_download
        except ImportError:
            logger.error("无法导入 modelscope snapshot_download")
            return updated

    for model_id in MODELS:
        short_name = model_id.split("/")[-1]
        try:
            logger.info(f"  检查: {short_name}")
            # snapshot_download 会自动检查远程版本，如果有更新则下载
            cache_dir = snapshot_download(model_id)
            logger.info(f"  ✔️  {short_name}: 已同步 → {cache_dir}")
            # modelscope 不直接告诉我们是否有新文件下载
            # 但 snapshot_download 会在有更新时下载新文件
        except Exception as e:
            logger.error(f"  ❌ {short_name}: 同步失败 - {e}")

    return updated


def send_notification(title: str, message: str) -> None:
    """发送 macOS 通知。"""
    try:
        safe_msg = message.replace('"', '\\"')
        safe_title = title.replace('"', '\\"')
        subprocess.run(
            ["osascript", "-e",
             f'display notification "{safe_msg}" with title "{safe_title}" sound name "default"'],
            capture_output=True, timeout=10,
        )
    except Exception:
        pass


def save_update_record(pip_updated: list[str], model_count: int) -> None:
    """保存更新记录。"""
    record_file = LOG_DIR / "update_history.json"
    history = []
    if record_file.exists():
        try:
            history = json.loads(record_file.read_text(encoding="utf-8"))
        except Exception:
            history = []

    history.append({
        "time": datetime.now().isoformat(),
        "pip_updated": pip_updated,
        "models_checked": model_count,
    })

    # 只保留最近 52 条记录（约 1 年）
    history = history[-52:]
    record_file.write_text(json.dumps(history, indent=2, ensure_ascii=False), encoding="utf-8")


def main():
    logger.info("=" * 60)
    logger.info("🔄 自动更新检查开始")
    logger.info(f"⏰ {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    logger.info("=" * 60)

    # 1. 更新 pip 包
    pip_updated = update_pip_packages()

    # 2. 更新模型
    update_models()

    # 3. 保存记录
    save_update_record(pip_updated, len(MODELS))

    # 4. 通知结果
    if pip_updated:
        pkg_list = ", ".join(pip_updated)
        msg = f"已更新依赖: {pkg_list}\\n模型已同步检查"
        logger.info(f"📦 已更新: {pkg_list}")
    else:
        msg = "所有依赖和模型均为最新"
        logger.info("✅ 所有依赖和模型均为最新")

    send_notification("🔄 自动转录 - 更新完成", msg)

    logger.info("=" * 60)
    logger.info("🔄 更新检查完成")
    logger.info("=" * 60)
    logger.info("")


if __name__ == "__main__":
    main()
