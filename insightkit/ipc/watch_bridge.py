"""Lightweight directory watch bridge for transcription ingestion.

Uses a polling loop instead of platform-specific watchers to keep sidecar runtime
portable in packaged app environments.
"""

from __future__ import annotations

import os
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

MEDIA_EXTENSIONS = {
    ".mp4", ".mkv", ".avi", ".mov", ".webm", ".flv", ".m4v", ".wmv", ".ts", ".mpg", ".mpeg",
    ".mp3", ".wav", ".m4a", ".flac", ".aac", ".ogg", ".opus", ".wma", ".aiff", ".aif",
}


@dataclass
class WatchSnapshot:
    path: str
    size: int
    mtime_ns: int


class WatchBridge:
    """Directory watcher with stable-size detection and callback dispatch."""

    def __init__(self, poll_interval_sec: float = 1.5, stable_rounds: int = 2):
        self.poll_interval_sec = max(0.5, poll_interval_sec)
        self.stable_rounds = max(1, stable_rounds)
        self._lock = threading.RLock()
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()
        self._dirs: list[Path] = []
        self._seen_stability: dict[str, int] = {}
        self._last_snapshots: dict[str, WatchSnapshot] = {}
        self._submitted: set[str] = set()
        self._on_file: Callable[[str], None] | None = None

    def start(self, dirs: list[str], on_file: Callable[[str], None]) -> dict:
        with self._lock:
            self.stop()
            self._dirs = [Path(d).expanduser().resolve() for d in dirs if d]
            self._on_file = on_file
            self._stop = threading.Event()
            self._seen_stability.clear()
            self._last_snapshots.clear()
            self._submitted.clear()
            self._thread = threading.Thread(target=self._run_loop, name="InsightKitWatchBridge", daemon=True)
            self._thread.start()
            return {
                "state": "running",
                "dirs": [str(x) for x in self._dirs],
                "poll_interval_sec": self.poll_interval_sec,
            }

    def stop(self) -> dict:
        with self._lock:
            th = self._thread
            if th is not None and th.is_alive():
                self._stop.set()
                th.join(timeout=2.0)
            self._thread = None
            return {
                "state": "stopped",
                "dirs": [str(x) for x in self._dirs],
            }

    def status(self) -> dict:
        with self._lock:
            running = self._thread is not None and self._thread.is_alive() and not self._stop.is_set()
            return {
                "state": "running" if running else "stopped",
                "dirs": [str(x) for x in self._dirs],
                "known_files": len(self._last_snapshots),
                "submitted_files": len(self._submitted),
            }

    def _run_loop(self) -> None:
        while not self._stop.is_set():
            self._scan_once()
            self._stop.wait(self.poll_interval_sec)

    def _scan_once(self) -> None:
        with self._lock:
            dirs = list(self._dirs)
            on_file = self._on_file
        if on_file is None:
            return

        for base in dirs:
            if not base.exists() or not base.is_dir():
                continue
            try:
                entries = list(base.iterdir())
            except Exception:
                continue

            for path in entries:
                if not path.is_file():
                    continue
                if path.name.startswith(".") or path.name.startswith("~"):
                    continue
                if path.suffix.lower() not in MEDIA_EXTENSIONS:
                    continue

                p = str(path)
                if p in self._submitted:
                    continue

                try:
                    st = path.stat()
                except OSError:
                    continue

                snap = WatchSnapshot(path=p, size=st.st_size, mtime_ns=getattr(st, "st_mtime_ns", int(st.st_mtime * 1e9)))
                last = self._last_snapshots.get(p)
                if last and last.size == snap.size and last.mtime_ns == snap.mtime_ns and snap.size > 0:
                    stable = self._seen_stability.get(p, 0) + 1
                    self._seen_stability[p] = stable
                else:
                    self._seen_stability[p] = 0

                self._last_snapshots[p] = snap

                if self._seen_stability.get(p, 0) >= self.stable_rounds:
                    self._submitted.add(p)
                    # Dispatch outside of lock.
                    try:
                        on_file(p)
                    except Exception:
                        pass
