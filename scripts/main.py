#!/usr/bin/env python3
"""
自动转录系统 — 入口脚本。

启动 FSEvents 文件监控，检测到新视频后弹窗确认、转录、保存 Markdown。
"""

import logging
import queue
import signal
import sys
import threading
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
from progress import progress
from dashboard_server import run_dashboard_bg
import webbrowser

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

def _run_transcribe_with_progress(
    asr_model, audio_path: str, duration: float
) -> list:
    """
    在后台线程运行 ASR 转录，同时在主线程更新进度百分比。
    基于已用时间 vs 预估时间来估算进度。
    """
    """
    在后台线程运行 ASR 转录，同时在主线程更新进度百分比。
    基于已用时间 vs 预估时间来估算进度。
    """
    result_container = [None]
    error_container = [None]
    done_event = threading.Event()

    def _run():
        try:
            result_container[0] = asr_model.generate(input=audio_path)
        except Exception as e:
            error_container[0] = e
        finally:
            done_event.set()

    thread = threading.Thread(target=_run, daemon=True)
    thread.start()

    # 预估转录时间：大约音频时长的 0.3~0.5 倍（Apple Silicon）
    # 使用保守估计，避免进度条到 100% 后还在等
    estimated_seconds = max(duration * 0.5, 30)

    while not done_event.is_set():
        done_event.wait(timeout=2)  # 每 2 秒更新一次
        if done_event.is_set():
            break
        elapsed = time.time() - (progress._start_time or time.time())
        # 使用对数增长曲线：快速上升到 80%，然后缓慢接近 95%
        # 这样即使预估不准也不会超过 95%
        raw_pct = min(elapsed / estimated_seconds, 1.0)
        # 将线性进度映射到对数曲线：0→0, 1→95
        display_pct = int(95 * (1 - (1 - raw_pct) ** 1.5))
        display_pct = max(1, min(display_pct, 95))
        progress.update_transcribe_progress(
            display_pct,
            f"已用 {_format_elapsed(elapsed)} | 预估 {_format_elapsed(estimated_seconds)}",
        )

    thread.join(timeout=5)

    if error_container[0] is not None:
        raise error_container[0]
    return result_container[0]


def process_video(video_path: Path) -> None:
    """处理单个视频的核心流程（由 worker 线程调用）。"""
    filename = video_path.name
    filesize_mb = video_path.stat().st_size / 1024 / 1024

    # 从等待队列中移除（开始处理）
    progress.remove_from_queue(filename)

    # 再次检查是否已处理（多线程防护）
    if is_processed(str(video_path)):
        return

    # 进度: 准备开始
    progress.start(filename, filesize_mb)

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
        progress.update("extract", f"{filename}")
        notify_stage(filename, "1/4 提取音频中...")
        audio_path = extract_audio(video_path)
        duration = _get_audio_duration(str(audio_path))
        duration_min = f"{duration / 60:.1f} 分钟" if duration >= 60 else f"{duration:.0f} 秒"
        logger.info(f"音频时长: {duration:.1f}s")

        # ── 阶段 2/4: 语言检测 ──
        progress.update("detect", f"音频时长: {duration_min}", duration_sec=duration)
        notify_stage(filename, "2/4 检测语言...", f"音频时长: {duration_min}")
        lang = detect_language(audio_path)
        lang_label = {"zh": "中文", "en": "English", "en_cn": "中英混合"}.get(lang, lang)
        logger.info(f"检测语言: {lang}")

        # ── 阶段 3/4: ASR 转录 ──
        progress.update("transcribe", f"语言: {lang_label} | 时长: {duration_min}")
        notify_stage(filename, "3/4 转录中...", f"语言: {lang_label} | 时长: {duration_min}")
        logger.info(f"开始转录 (引擎: Paraformer-zh)...")

        asr_model = _load_model("asr")
        result = _run_transcribe_with_progress(asr_model, str(audio_path), duration)
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
        progress.update("save", f"正在保存 Markdown...")
        notify_stage(filename, "4/4 保存文件...")

        # 生成标准名称 (使用视频创建时间)
        try:
            # macOS 上 st_birthtime 为创建时间
            stat = video_path.stat()
            if hasattr(stat, "st_birthtime"):
                creation_time = datetime.fromtimestamp(stat.st_birthtime)
            else:
                creation_time = datetime.fromtimestamp(stat.st_mtime)
        except Exception:
            creation_time = datetime.now()

        standard_name = generate_standard_name(lang, date=creation_time)

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

        # 进度: 完成
        progress.finish(
            success=True, lang=lang,
            segments=len(segments), speakers=speakers_count,
            output_file=f"{standard_name}.md",
        )

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

        # 短暂显示完成状态后恢复空闲
        time.sleep(5)
        progress.reset_to_idle()

    except Exception as e:
        elapsed = time.time() - t0
        elapsed_str = _format_elapsed(elapsed)
        error_msg = str(e)
        logger.error(f"❌ 转录失败: {filename} - {error_msg}", exc_info=True)

        # 进度: 失败
        progress.set_error(error_msg)
        progress.finish(success=False)

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

        # 短暂显示失败状态后恢复空闲
        time.sleep(5)
        progress.reset_to_idle()

    logger.info("")


def _format_elapsed(seconds: float) -> str:
    """格式化耗时。"""
    if seconds < 60:
        return f"{seconds:.0f}s"
    m = int(seconds) // 60
    s = int(seconds) % 60
    return f"{m}m{s}s"

    return f"{m}m{s}s"


# ── 任务队列系统 ──────────────────────────────────────────

class TaskQueue:
    def __init__(self):
        self.q = queue.Queue()
        # 启动消费者线程
        self.worker_thread = threading.Thread(target=self._worker, daemon=True)
        self.worker_thread.start()

    def add_task(self, video_path: Path):
        """添加任务到队列"""
        filename = video_path.name
        filesize_mb = video_path.stat().st_size / 1024 / 1024
        
        # 记录到 progress 队列显示
        progress.add_to_queue(filename, filesize_mb)
        
        self.q.put(video_path)
        logger.info(f"加入队列: {filename}")

    def _worker(self):
        """消费者循环"""
        logger.info("任务队列工作线程已启动")
        while True:
            video_path = self.q.get()
            try:
                logger.info(f"队列取出任务: {video_path.name}")
                process_video(video_path)
            except Exception as e:
                logger.error(f"处理任务出错: {e}", exc_info=True)
            finally:
                self.q.task_done()
                time.sleep(1)  # 任务间短暂冷却

# 全局队列实例
task_queue = TaskQueue()

def on_new_video(video_path: Path) -> None:
    """检测到新视频时的入口（Watcher 回调）。"""
    filename = video_path.name
    filesize_mb = video_path.stat().st_size / 1024 / 1024

    # 再次检查是否已处理（多线程防护）
    if is_processed(str(video_path)):
        return

    # 1. 弹窗确认 (在入队前进行，允许批量确认)
    logger.info(f"弹窗确认: {filename}")
    if ask_confirm(filename, filesize_mb):
        # 加入队列
        task_queue.add_task(video_path)
    else:
        # 用户拒绝，标记为已处理以免再次触发
        logger.info(f"用户取消: {filename}")
        mark_processed(str(video_path))
# ── 主入口 ────────────────────────────────────────────────

def main():
    logger.info("=" * 60)
    logger.info("🎙 自动转录系统启动")
    logger.info(f"⏰ {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    logger.info("=" * 60)

    logger.info("=" * 60)

    # 启动 Dashboard
    try:
        run_dashboard_bg()
        logger.info("📊 Dashboard running at http://localhost:7860")
        # 自动打开浏览器
        webbrowser.open("http://localhost:7860")
    except Exception as e:
        logger.error(f"Failed to start dashboard: {e}")

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
