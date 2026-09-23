"""Bounded, session-scoped speaker enrichment independent of foreground ASR."""

from __future__ import annotations

import json
import os
import select
import shutil
import subprocess
import tempfile
import threading
import time
import uuid
import wave
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

from insightkit.data.store import InsightStore
from scripts.transcriber import DIARIZATION_ENABLED, DIARIZATION_ENGINE, FLUIDAUDIO_LSEEND_VARIANT, _qwen_text_join


def _speaker(start: int, end: int, spans: list[dict[str, Any]], finalized: int) -> str:
    if end > finalized:
        return ""
    candidates = [(min(end, int(s["end_ms"])) - max(start, int(s["start_ms"])), str(s["speaker"])) for s in spans]
    overlap, label = max(candidates, default=(0, ""), key=lambda pair: pair[0])
    return label if overlap > 0 else ""


def split_speaker_segments(
    segments: list[dict[str, Any]], words: list[dict[str, Any]],
    spans: list[dict[str, Any]], finalized_until_ms: int,
) -> list[dict[str, Any]]:
    """Split only aligned words whose reconstruction preserves the original text."""
    result = []
    for segment in segments:
        aligned = [w for w in words if w["start_ms"] >= segment["start_ms"] and w["end_ms"] <= segment["end_ms"]]
        if not aligned or _qwen_text_join([w["text"] for w in aligned]) != segment["text"]:
            label = _speaker(segment["start_ms"], segment["end_ms"], spans, finalized_until_ms)
            result.append({**segment, "speaker": label})
            continue
        groups: list[tuple[str, list[dict[str, Any]]]] = []
        for word in aligned:
            label = _speaker(word["start_ms"], word["end_ms"], spans, finalized_until_ms)
            if not groups or groups[-1][0] != label:
                groups.append((label, []))
            groups[-1][1].append(word)
        if len(groups) == 1:
            result.append({**segment, "speaker": groups[0][0]})
        else:
            for label, group in groups:
                result.append({**segment, "start_ms": group[0]["start_ms"], "end_ms": group[-1]["end_ms"],
                               "text": _qwen_text_join([w["text"] for w in group]), "speaker": label})
    return result


def _worker_executable() -> Path:
    override = os.getenv("INSIGHTKIT_LIVE_DIARIZATION_WORKER", "").strip()
    root = Path(__file__).resolve().parents[2]
    candidates = [Path(override).expanduser()] if override else [
        root.parent.parent / "MacOS" / "InsightKitLiveDiarization",
        root / "macos" / "LiveDiarizationWorker" / ".build" / "out" / "Products" / "Release" / "InsightKitLiveDiarization",
        root / "macos" / "LiveDiarizationWorker" / ".build" / "release" / "InsightKitLiveDiarization",
    ]
    for path in candidates:
        if path.is_file() and os.access(path, os.X_OK):
            return path
    raise RuntimeError("live_diarization_worker_missing")


class LiveDiarizationWorker:
    """One JSONL subprocess and one LS-EEND model state for the recording."""

    def __init__(self, session_id: str):
        self.session_id = session_id
        self.process: Any = None
        self._lifecycle = threading.Lock()
        self._closed = False
        self._sequence = 0
        self._buffer = b""

    def start(self) -> None:
        with self._lifecycle:
            if self._closed:
                raise RuntimeError("live_diarization_stopped")
            self.process = subprocess.Popen([str(_worker_executable())], stdin=subprocess.PIPE,
                                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
        try:
            self._request("start", variant=FLUIDAUDIO_LSEEND_VARIANT)
        except Exception:
            self.close()
            raise

    def _request(self, action: str, **params: Any) -> dict[str, Any]:
        self._sequence += 1
        request_id = str(self._sequence)
        request = dict(id=request_id, action=action, session_id=self.session_id, **params)
        assert self.process.stdin is not None and self.process.stdout is not None
        self.process.stdin.write((json.dumps(request) + "\n").encode())
        self.process.stdin.flush()
        deadline = time.monotonic() + 40
        while b"\n" not in self._buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.process.stdout], [], [], max(0, remaining))[0]:
                raise TimeoutError("live_diarization_timeout")
            chunk = os.read(self.process.stdout.fileno(), 65536)
            if not chunk:
                raise RuntimeError("live_diarization_worker_exited")
            self._buffer += chunk
            if len(self._buffer) > 4 * 1024 * 1024:
                raise RuntimeError("live_diarization_response_too_large")
        line, self._buffer = self._buffer.split(b"\n", 1)
        response = json.loads(line)
        if response.get("id") != request_id or response.get("session_id") != self.session_id:
            raise RuntimeError("live_diarization_response_mismatch")
        if response.get("ok") is not True:
            error = response.get("error") or {}
            raise RuntimeError(str(error.get("code", "live_diarization_failed")))
        return response

    def feed(self, path: Path, offset_ms: int) -> dict[str, Any]:
        return self._request("feed", wav_path=str(path), offset_ms=offset_ms)

    def close(self) -> None:
        # Termination also interrupts a model call; stop never waits for inference.
        with self._lifecycle:
            if self._closed:
                return
            self._closed = True
            process = self.process
        if process is None:
            return
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=0.25)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=1)
        for stream in (process.stdin, process.stdout):
            if stream:
                stream.close()


@dataclass
class _Chunk:
    chunk_id: str
    path: Path
    offset_ms: int
    end_ms: int
    source: str
    originals: list[dict[str, Any]] = field(default_factory=list)
    current_groups: list[list[dict[str, Any]]] = field(default_factory=list)
    words: list[dict[str, Any]] = field(default_factory=list)
    recognized: bool = False
    fed: bool = False


@dataclass
class _Session:
    meeting_id: str
    token: str = field(default_factory=lambda: str(uuid.uuid4()))
    directory: Any = field(default_factory=lambda: tempfile.TemporaryDirectory(prefix="insightkit-live-speakers-"))
    chunks: dict[str, _Chunk] = field(default_factory=dict)
    operation: Any = field(default_factory=threading.Lock)
    worker: Any = None
    error: str = ""

    def close(self) -> None:
        if self.worker:
            self.worker.close()
        self.chunks.clear()
        self.directory.cleanup()


class LiveDiarizationSessions:
    MAX_PENDING_CHUNKS = 12

    def __init__(self, store: InsightStore, *, worker_factory: Callable[[str], Any] = LiveDiarizationWorker):
        self.store = store
        self._factory = worker_factory
        self._lock = threading.RLock()
        self._sessions: dict[str, _Session] = {}

    def start(self, meeting_id: str) -> None:
        self.stop(meeting_id)
        with self._lock:
            session = _Session(meeting_id)
            if not DIARIZATION_ENABLED:
                session.error = "diarization_disabled"
            elif DIARIZATION_ENGINE not in {"fluid-lseend", "auto"}:
                session.error = "live_diarization_engine_unsupported"
            self._sessions[meeting_id] = session

    def stop(self, meeting_id: str) -> None:
        with self._lock:
            session = self._sessions.pop(meeting_id, None)
        if session:
            session.close()

    def close(self) -> None:
        with self._lock:
            sessions, self._sessions = list(self._sessions.values()), {}
        for session in sessions:
            session.close()

    def capture(self, meeting_id: str, chunk_id: str, path: Path, offset_ms: int, source: str) -> tuple[_Session, _Chunk | None]:
        with self._lock:
            session = self._sessions.get(meeting_id)
            if session is None:
                raise RuntimeError("live_session_stopped")
            if chunk_id in session.chunks:
                raise ValueError("duplicate_live_chunk")
            if session.error or len(session.chunks) >= self.MAX_PENDING_CHUNKS:
                return session, None
            owned = Path(session.directory.name) / f"{uuid.uuid4()}.wav"
            try:
                with wave.open(str(path), "rb") as audio:
                    duration_ms = round(audio.getnframes() * 1000 / audio.getframerate())
                if offset_ms < 0 or not 0 < duration_ms <= 30000 or path.stat().st_size > 8 * 1024 * 1024:
                    raise ValueError("invalid_live_chunk_bounds")
                # Swift may remove its input as soon as foreground ASR returns.
                shutil.copyfile(path, owned)
            except (OSError, ValueError, wave.Error, EOFError) as exc:
                owned.unlink(missing_ok=True)
                session.error = f"speaker_cache_unavailable: {type(exc).__name__}"
                return session, None
            chunk = _Chunk(chunk_id, owned, offset_ms, offset_ms + duration_ms, source)
            session.chunks[chunk_id] = chunk
            return session, chunk

    def recognized(self, ticket: tuple[_Session, _Chunk | None], segments: list[dict[str, Any]]) -> None:
        session, chunk = ticket
        with self._lock:
            if self._sessions.get(session.meeting_id) is not session:
                raise RuntimeError("live_session_stopped")
            if chunk is None:
                return
            chunk.originals = [{k: v for k, v in s.items() if not k.startswith("_")} for s in segments]
            chunk.current_groups = [[segment] for segment in chunk.originals]
            chunk.words = [word for s in segments for word in s.get("_words", [])]
            chunk.recognized = True

    def discard(self, ticket: tuple[_Session, _Chunk | None]) -> None:
        session, chunk = ticket
        with self._lock:
            if chunk is not None:
                session.chunks.pop(chunk.chunk_id, None)
                chunk.path.unlink(missing_ok=True)

    @staticmethod
    def _result(meeting_id: str, status: str, *, error: str = "", updates: list | None = None) -> dict[str, Any]:
        return dict(meeting_id=meeting_id, status=status, updates=updates or [], **({"error": error} if error else {}))

    def enrich(self, meeting_id: str, chunk_id: str) -> dict[str, Any]:
        with self._lock:
            session = self._sessions.get(meeting_id)
            if session is None:
                return self._result(meeting_id, "stopped")
            chunk = session.chunks.get(chunk_id)
            if session.error or chunk is None:
                return self._result(meeting_id, "unavailable", error=session.error or "speaker_chunk_unavailable")
            if not chunk.recognized or chunk.fed or not session.operation.acquire(blocking=False):
                return self._result(meeting_id, "pending")
        try:
            with self._lock:
                if self._sessions.get(meeting_id) is not session:
                    return self._result(meeting_id, "stopped")
                needs_start = session.worker is None
                if needs_start:
                    # Construction is inert. Register before the cancellable startup.
                    session.worker = self._factory(session.token)
            if needs_start:
                session.worker.start()
            response = session.worker.feed(chunk.path, chunk.offset_ms)
            with self._lock:
                if self._sessions.get(meeting_id) is not session:
                    return self._result(meeting_id, "stopped")
                chunk.fed = True
                chunk.path.unlink(missing_ok=True)
                finalized = int(response["finalized_until_ms"])
                spans = response.get("spans", [])
                updates = []
                for key, pending in list(session.chunks.items()):
                    if pending.fed and pending.originals:
                        # Swift can discard duplicate ASR rows before ingestion.
                        # One absent row must not block enrichment of its neighbours.
                        for index, original in enumerate(pending.originals):
                            current = pending.current_groups[index]
                            updated = split_speaker_segments([original], pending.words, spans, finalized)
                            if updated != current and self.store.replace_exact_segments(meeting_id, current, updated):
                                updates.append(dict(chunk_id=key, original_segments=current, segments=updated))
                                pending.current_groups[index] = updated
                    if pending.end_ms <= finalized:
                        pending.path.unlink(missing_ok=True)
                        del session.chunks[key]
                return self._result(meeting_id, "updated" if updates else "pending", updates=updates)
        except Exception as exc:
            with self._lock:
                if self._sessions.get(meeting_id) is not session:
                    return self._result(meeting_id, "stopped")
                session.error = f"live_diarization_unavailable: {type(exc).__name__}: {exc}"
                session.close()
                return self._result(meeting_id, "unavailable", error=session.error)
        finally:
            session.operation.release()
