#!/usr/bin/env python3
"""
自动转录系统 — 入口脚本。

启动 FSEvents 文件监控，检测到新视频后弹窗确认、转录、保存 Markdown。
"""

import logging
import signal
import sys
import time
from datetime import datetime
from pathlib import Path

# 将 scripts/ 目录加入 Python 路径
sys.path.insert(0, str(Path(__file__).resolve().parent))

from config import LOG_FILE, LOG_DIR
from watcher import start_watching
from notifier import (
    ask_confirm, notify_start, notify_stage,
    show_result_dialog, notify_done, notify_fail,
)
from transcriber import transcribe, extract_audio, detect_language, _load_model, _get_audio_duration
from file_manager import (
    generate_standard_name, move_video, save_transcript_md,
    mark_processed, is_processed,
)

# ── 日志配置 ──────────────────────────────────────────────

LOG_DIR.mkdir(parents=True, exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    handlers=[
        logging.FileHandler(LOG_FILE, encoding="utf-8"),
        logging.StreamHandler(sys.stdout),
    ],
)
logger = logging.getLogger(__name__)


# ── 转录回调 ──────────────────────────────────────────────

def on_new_video(video_path: Path) -> None:
    """检测到新视频时的处理流程。"""
    filename = video_path.name
    filesize_mb = video_path.stat().st_size / 1024 / 1024

    # 再次检查是否已处理（多线程防护）
    if is_processed(str(video_path)):
        return

    # 1. 弹窗确认
    logger.info(f"弹窗确认: {filename}")
    if not ask_confirm(filename, filesize_mb):
        mark_processed(str(video_path))
        return

    # 标记为已处理（防止重复）
    mark_processed(str(video_path))

    # 2. 开始转录
    notify_start(filename, filesize_mb)
    logger.info(f"{'='*60}")
    logger.info(f"开始转录: {filename} ({filesize_mb:.1f} MB)")
    logger.info(f"{'='*60}")

    t0 = time.time()
    standard_name = None

    try:
        # ── 阶段 1/4: 提取音频 ──
        notify_stage(filename, "1/4 提取音频中...")
        audio_path = extract_audio(video_path)
        duration = _get_audio_duration(str(audio_path))
        duration_min = f"{duration / 60:.1f} 分钟" if duration >= 60 else f"{duration:.0f} 秒"
        logger.info(f"音频时长: {duration:.1f}s")

        # ── 阶段 2/4: 语言检测 ──
        notify_stage(filename, "2/4 检测语言...", f"音频时长: {duration_min}")
        lang = detect_language(audio_path)
        lang_label = {"zh": "中文", "en": "English", "en_cn": "中英混合"}.get(lang, lang)
        logger.info(f"检测语言: {lang}")

        # ── 阶段 3/4: ASR 转录 ──
        notify_stage(filename, "3/4 转录中...", f"语言: {lang_label} | 时长: {duration_min}")
        logger.info(f"开始转录 (引擎: Paraformer-zh)...")

        asr_model = _load_model("asr")
        result = asr_model.generate(input=str(audio_path))
        from transcriber import _parse_funasr_result
        segments = _parse_funasr_result(result)

        # 清理临时音频
        try:
            audio_path.unlink()
        except Exception:
            pass

        elapsed = time.time() - t0
        elapsed_str = _format_elapsed(elapsed)
        logger.info(f"音频时长: {duration:.0f}s | 转录耗时: {elapsed_str}")
        logger.info(f"片段数: {len(segments)}")

        # ── 阶段 4/4: 保存文件 ──
        notify_stage(filename, "4/4 保存文件...")

        # 生成标准名称
        standard_name = generate_standard_name(lang)

        # 保存 Markdown
        md_path = save_transcript_md(standard_name, lang, duration, segments)
        logger.info(f"✅ Markdown: {md_path}")

        # 移动视频
        new_video_path = move_video(video_path, standard_name, success=True)
        logger.info(f"✅ 视频: {new_video_path}")

        # 统计说话人
        speakers = set()
        for seg in segments:
            spk = seg.get("speaker", "")
            if spk:
                speakers.add(spk)
        speakers_count = max(len(speakers), 1)

        # ── 最终结果弹窗 ──
        show_result_dialog(
            filename=standard_name,
            success=True,
            lang=lang,
            duration_str=duration_min,
            elapsed_str=elapsed_str,
            segments_count=len(segments),
            speakers_count=speakers_count,
            output_file=f"{standard_name}.md",
        )
        logger.info(f"✅ 转录成功完成: {standard_name} (耗时 {elapsed_str})")

    except Exception as e:
        elapsed = time.time() - t0
        elapsed_str = _format_elapsed(elapsed)
        error_msg = str(e)
        logger.error(f"❌ 转录失败: {filename} - {error_msg}", exc_info=True)

        # 尝试移动视频并标记为失败
        try:
            if standard_name is None:
                standard_name = generate_standard_name("unknown")
            move_video(video_path, standard_name, success=False)
        except Exception as move_err:
            logger.error(f"移动失败视频也出错: {move_err}")

        # 弹窗通知失败
        show_result_dialog(
            filename=filename,
            success=False,
            elapsed_str=elapsed_str,
            error=error_msg,
        )

    logger.info("")


def _format_elapsed(seconds: float) -> str:
    """格式化耗时。"""
    if seconds < 60:
        return f"{seconds:.0f}s"
    m = int(seconds) // 60
    s = int(seconds) % 60
    return f"{m}m{s}s"


# ── 主入口 ────────────────────────────────────────────────

def main():
    logger.info("=" * 60)
    logger.info("🎙 自动转录系统启动")
    logger.info(f"⏰ {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    logger.info("=" * 60)

    # 启动监控
    observer = start_watching(on_new_video)

    # 优雅退出
    def shutdown(signum, frame):
        logger.info("\n🛑 正在停止...")
        observer.stop()
        observer.join(timeout=5)
        logger.info("👋 已退出")
        sys.exit(0)

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    logger.info("")
    logger.info("💡 将视频文件保存到 Desktop 或 Downloads 即可触发自动转录")
    logger.info("💡 按 Ctrl+C 停止服务")
    logger.info("💡 查看日志: tail -f " + str(LOG_FILE))
    logger.info("")

    # 保持运行
    try:
        while True:
            time.sleep(1)
    except (KeyboardInterrupt, SystemExit):
        observer.stop()
        observer.join(timeout=5)


if __name__ == "__main__":
    main()
