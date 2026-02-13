"""
FSEvents 文件监控 — 检测 Desktop/Downloads 的新视频文件。

使用 macOS 原生 FSEvents API，待机 CPU 占用近零。
"""

import logging
import os
import time
import threading
from pathlib import Path
from typing import Callable

from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler, FileCreatedEvent, FileMovedEvent

from config import (
    WATCH_DIRS, VIDEO_EXTENSIONS,
    FILE_STABLE_CHECK_INTERVAL, FILE_STABLE_MAX_WAIT,
)
from file_manager import is_processed, mark_processed

logger = logging.getLogger(__name__)


class VideoHandler(FileSystemEventHandler):
    """检测新视频文件并触发回调。"""

    def __init__(self, on_new_video: Callable[[Path], None]):
        super().__init__()
        self.on_new_video = on_new_video
        self._processing_lock = threading.Lock()
        self._currently_processing: set[str] = set()

    def _is_video(self, path: str) -> bool:
        """检查文件扩展名是否为视频。"""
        return Path(path).suffix.lower() in VIDEO_EXTENSIONS

    def _handle_file(self, filepath: str) -> None:
        """处理单个文件事件。"""
        if not self._is_video(filepath):
            return

        path = Path(filepath)

        # 跳过隐藏文件和临时文件
        if path.name.startswith(".") or path.name.startswith("~"):
            return

        # 跳过项目自身目录中的文件（video/, txt/ 等）
        from config import BASE_DIR
        try:
            path.resolve().relative_to(BASE_DIR.resolve())
            logger.debug(f"跳过项目内文件: {path.name}")
            return
        except ValueError:
            pass  # 不在项目目录内，继续处理

        # 跳过已处理文件
        if is_processed(filepath):
            logger.debug(f"跳过已处理文件: {path.name}")
            return

        # 防止同一文件并发处理
        with self._processing_lock:
            if filepath in self._currently_processing:
                return
            self._currently_processing.add(filepath)

        # 在后台线程中等待文件写入完成再处理
        thread = threading.Thread(
            target=self._wait_and_process,
            args=(path,),
            daemon=True,
        )
        thread.start()

    def _wait_and_process(self, path: Path) -> None:
        """等待文件写入完成，然后触发回调。"""
        try:
            if not self._wait_for_stable(path):
                logger.warning(f"文件写入超时或消失: {path.name}")
                return

            logger.info(f"检测到新视频: {path.name} ({path.stat().st_size / 1024 / 1024:.1f} MB)")
            self.on_new_video(path)

        finally:
            with self._processing_lock:
                self._currently_processing.discard(str(path))

    def _wait_for_stable(self, path: Path) -> bool:
        """等待文件大小稳定（写入完成）。"""
        waited = 0
        prev_size = -1

        while waited < FILE_STABLE_MAX_WAIT:
            if not path.exists():
                return False

            try:
                curr_size = path.stat().st_size
            except OSError:
                return False

            if curr_size > 0 and curr_size == prev_size:
                return True  # 文件大小稳定，写入完成

            prev_size = curr_size
            time.sleep(FILE_STABLE_CHECK_INTERVAL)
            waited += FILE_STABLE_CHECK_INTERVAL

        return False  # 超时

    def on_created(self, event):
        if isinstance(event, FileCreatedEvent) and not event.is_directory:
            self._handle_file(event.src_path)

    def on_moved(self, event):
        if isinstance(event, FileMovedEvent) and not event.is_directory:
            self._handle_file(event.dest_path)


def start_watching(on_new_video: Callable[[Path], None]) -> Observer:
    """启动文件监控，返回 Observer 实例。"""
    handler = VideoHandler(on_new_video)
    observer = Observer()

    for watch_dir in WATCH_DIRS:
        if watch_dir.exists():
            observer.schedule(handler, str(watch_dir), recursive=False)
            logger.info(f"📂 监控目录: {watch_dir}")
        else:
            logger.warning(f"目录不存在，跳过: {watch_dir}")

    observer.start()
    logger.info("👁 文件监控已启动 (FSEvents)")
    return observer
