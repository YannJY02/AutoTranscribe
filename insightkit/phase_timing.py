"""Local, content-free monotonic timings for one transcription job.

The context only follows synchronous Python calls. Worker threads must receive
the recorder explicitly for each request; cached workers never own a job.
"""

from __future__ import annotations

from contextlib import contextmanager, nullcontext
from contextvars import ContextVar
from enum import Enum
import threading
import time
from typing import Callable, Iterator, Literal


class Phase(str, Enum):
    QUEUE_WAIT = "queue_wait"
    JOB_EXECUTION = "job_execution"
    TRANSCRIPTION = "transcription"
    AUDIO_PREPARATION = "audio_preparation"
    SPEECH_DETECTION = "speech_detection"
    QWEN_SESSION_READY = "qwen_session_ready"
    QWEN_SESSION_INITIALIZE = "qwen_session_initialize"
    QWEN_WORKER_WAIT = "qwen_worker_wait"
    QWEN_SESSION_TRANSCRIBE = "qwen_session_transcribe"
    SEGMENT_CONVERSION = "segment_conversion"
    SPEAKER_ATTACHMENT = "speaker_attachment"
    PERSIST_SEGMENTS = "persist_segments"
    FINAL_GENERATION = "final_generation"
    FINAL_GENERATION_FALLBACK = "final_generation_fallback"
    PERSIST_FINAL = "persist_final"
    RECORD_WRITE = "record_write"


Outcome = Literal["completed", "failed", "cancelled", "skipped"]
_OUTCOMES = {"completed", "failed", "cancelled", "skipped"}


class TimingSpan:
    def __init__(self, recorder: TimingRecorder, index: int):
        self._recorder = recorder
        self._index = index

    def finish(self, outcome: Outcome = "completed") -> None:
        self._recorder._finish(self._index, outcome)

    def __enter__(self) -> TimingSpan:
        return self

    def __exit__(self, exc_type, _exc, _tb) -> None:
        self.finish("failed" if exc_type is not None else "completed")


class TimingRecorder:
    """Thread-safe bounded-vocabulary spans; no payloads, paths or exceptions."""

    def __init__(self, job_id: str, *, clock_ns: Callable[[], int] | None = None):
        self._job_id = job_id
        self._clock_ns = clock_ns or time.monotonic_ns
        self._origin_ns = self._clock_ns()
        self._lock = threading.Lock()
        self._spans: list[dict] = []

    def start(self, name: Phase) -> TimingSpan:
        if not isinstance(name, Phase):
            raise ValueError("phase must be a fixed Phase value")
        with self._lock:
            index = len(self._spans)
            self._spans.append({
                "phase": name.value,
                "start_offset_ns": self._clock_ns() - self._origin_ns,
                "end_offset_ns": None,
                "outcome": "running",
            })
        return TimingSpan(self, index)

    def record_interval(self, name: Phase, start_ns: int, end_ns: int, outcome: Outcome) -> None:
        """Attach a same-process receipt (for initialization in a worker thread)."""
        if not isinstance(name, Phase) or outcome not in _OUTCOMES:
            raise ValueError("invalid timing vocabulary")
        if start_ns < self._origin_ns or end_ns < start_ns:
            raise ValueError("timing interval is outside this job's monotonic clock")
        with self._lock:
            self._spans.append({
                "phase": name.value,
                "start_offset_ns": start_ns - self._origin_ns,
                "end_offset_ns": end_ns - self._origin_ns,
                "outcome": outcome,
            })

    def _finish(self, index: int, outcome: Outcome) -> None:
        if outcome not in _OUTCOMES:
            raise ValueError("invalid timing outcome")
        with self._lock:
            span = self._spans[index]
            if span["end_offset_ns"] is None:
                span["end_offset_ns"] = self._clock_ns() - self._origin_ns
                span["outcome"] = outcome

    def snapshot(self) -> dict:
        with self._lock:
            sampled_ns = self._clock_ns() - self._origin_ns
            spans = []
            for saved in self._spans:
                span = dict(saved)
                end_ns = span["end_offset_ns"]
                span["duration_ns"] = (sampled_ns if end_ns is None else end_ns) - span["start_offset_ns"]
                spans.append(span)
        return {
            "schema_version": 1,
            "job_id": self._job_id,
            "clock": "monotonic_ns",
            "sampled_offset_ns": sampled_ns,
            "spans": spans,
        }


_current: ContextVar[TimingRecorder | None] = ContextVar("import_phase_timing", default=None)


def current_timing() -> TimingRecorder | None:
    return _current.get()


@contextmanager
def timing_context(recorder: TimingRecorder | None) -> Iterator[None]:
    token = _current.set(recorder)
    try:
        yield
    finally:
        _current.reset(token)


def phase(name: Phase):
    recorder = current_timing()
    return recorder.start(name) if recorder is not None else nullcontext()
