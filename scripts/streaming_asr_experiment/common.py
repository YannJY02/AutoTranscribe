"""Input, publication clocks, and text scoring shared by experiment adapters.

No application preferences, capture devices, or model libraries are imported.
Pacing records when a finite WAV source releases audio; it does not implement
the product's bounded capture queue or measure GUI publication.
"""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import math
from pathlib import Path
import re
import threading
import time
import unicodedata
import wave


HAN = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\U00020000-\U0002fa1f]")
ENGLISH_WORD = re.compile(r"[a-z0-9]+(?:'[a-z0-9]+)*")


def sha256_file(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


@dataclass(frozen=True)
class Audio:
    sample_rate: int
    frames: int
    pcm16: bytes

    @property
    def duration_ms(self) -> float:
        return self.frames * 1000 / self.sample_rate

    def as_float32(self):
        import numpy as np

        return np.frombuffer(self.pcm16, dtype="<i2").astype(np.float32) / 32768.0


def load_audio(path: Path, max_seconds: float = 300) -> Audio:
    with wave.open(str(path), "rb") as stream:
        if (stream.getnchannels(), stream.getsampwidth(), stream.getframerate(), stream.getcomptype()) != (1, 2, 16000, "NONE"):
            raise ValueError("input must be mono 16-kHz PCM16 WAV; no implicit conversion")
        frames = stream.getnframes()
        if not frames or frames > max_seconds * 16000:
            raise ValueError("audio duration is empty or exceeds the declared limit")
        pcm = stream.readframes(frames)
        if len(pcm) != frames * 2:
            raise ValueError("WAV header claims more PCM frames than are present")
    return Audio(16000, frames, pcm)


def load_reference(path: Path, duration_ms: float) -> tuple[str, list[dict]]:
    data = json.loads(path.read_text(encoding="utf-8"))
    segments = data.get("segments")
    if not isinstance(segments, list) or not segments:
        raise ValueError("reference must contain nonempty segments")
    selected = []
    for segment in segments:
        start, end, text = segment.get("start_ms"), segment.get("end_ms"), segment.get("text")
        if (not isinstance(start, (int, float)) or isinstance(start, bool)
                or not isinstance(end, (int, float)) or isinstance(end, bool)
                or not math.isfinite(start) or not math.isfinite(end)
                or start < 0 or end <= start or end > duration_ms
                or not isinstance(text, str) or not text.strip()):
            raise ValueError("reference contains invalid, empty, or out-of-audio segments")
        selected.append(segment)
    selected.sort(key=lambda item: item["start_ms"])
    return " ".join(item["text"] for item in selected), selected


def edit_distance(expected: list[str], actual: list[str]) -> int:
    previous = list(range(len(actual) + 1))
    for index, token in enumerate(expected, 1):
        current = [index]
        for column, candidate in enumerate(actual, 1):
            current.append(min(current[-1] + 1, previous[column] + 1,
                               previous[column - 1] + (token != candidate)))
        previous = current
    return previous[-1]


def quality_metrics(reference: str, hypothesis: str) -> dict:
    """Same normalization as YAN-76; excludes speaker/time/cross-language order."""
    def normalize(value):
        return unicodedata.normalize("NFKC", value).lower().replace("’", "'")

    result = {}
    for name, tokenizer in (("chinese_cer", HAN.findall), ("english_wer", ENGLISH_WORD.findall)):
        expected, actual = tokenizer(normalize(reference)), tokenizer(normalize(hypothesis))
        errors = edit_distance(expected, actual)
        result[name] = {"errors": errors, "reference_units": len(expected),
                        "hypothesis_units": len(actual),
                        "rate": errors / len(expected) if expected else None}
    return result


class EventJournal:
    """Flush complete JSON lines under a lock; preserve partial evidence on exit."""

    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self._stream = path.open("x", encoding="utf-8")
        path.chmod(0o600)
        self._lock = threading.RLock()
        self._sequence = 0
        self._start = time.monotonic_ns()

    def record(self, kind: str, **fields) -> dict:
        reserved = {"sequence", "kind", "process_elapsed_ms"} & fields.keys()
        if reserved:
            raise ValueError(f"reserved event fields: {sorted(reserved)}")
        with self._lock:
            row = {"sequence": self._sequence, "kind": kind,
                   "process_elapsed_ms": (time.monotonic_ns() - self._start) / 1_000_000,
                   **fields}
            serialized = json.dumps(row, ensure_ascii=False, allow_nan=False)
            self._stream.write(serialized + "\n")
            self._stream.flush()
            self._sequence += 1
            return row

    def __call__(self, kind: str, **fields) -> dict:
        return self.record(kind, **fields)

    def close(self):
        with self._lock:
            self._stream.close()


class StreamSession:
    """A new source/publication clock per stream; model weights may be reused."""

    def __init__(self, audio: Audio, journal: EventJournal, pass_index: int, *,
                 pacing: str = "realtime", clock=time.monotonic, sleep=time.sleep):
        if pacing not in {"realtime", "accelerated"}:
            raise ValueError("invalid pacing")
        self.audio, self.journal, self.pass_index = audio, journal, pass_index
        self.pacing, self._clock, self._sleep = pacing, clock, sleep
        self._start = clock()
        self._lock = threading.RLock()
        self._pace_lock = threading.Lock()
        self._last_frame = 0
        self.first_text_ms = None
        self.text_events = 0
        self.max_source_lateness_ms = 0.0
        self.record("stream_started", pacing=pacing, audio_ms=audio.duration_ms)

    def elapsed_ms(self) -> float:
        return (self._clock() - self._start) * 1000

    def record(self, kind: str, **fields) -> dict:
        if {"pass_index", "stream_elapsed_ms"} & fields.keys():
            raise ValueError("reserved session fields")
        return self.journal.record(kind, pass_index=self.pass_index,
                                   stream_elapsed_ms=self.elapsed_ms(), **fields)

    def pace_to(self, end_frame: int) -> None:
        """Wait before input delivery; the reported frontier is released audio."""
        if isinstance(end_frame, bool) or not isinstance(end_frame, int):
            raise ValueError("audio frontier must be an integer frame index")
        with self._pace_lock:
            with self._lock:
                if not self._last_frame <= end_frame <= self.audio.frames:
                    raise ValueError("audio frontier went backward or exceeded the finite source")
            due_ms = end_frame * 1000 / self.audio.sample_rate
            if self.pacing == "realtime":
                remaining = (due_ms - self.elapsed_ms()) / 1000
                if remaining > 0:
                    self._sleep(remaining)
            with self._lock:
                self._last_frame = end_frame
                lateness = max(0.0, self.elapsed_ms() - due_ms)
                self.max_source_lateness_ms = max(self.max_source_lateness_ms, lateness)
                self.record("audio_released", audio_end_frame=end_frame, audio_end_ms=due_ms,
                            source_lateness_ms=lateness)

    def emit_text(self, text: str, *, semantics: str, audio_end_frame: int | None = None,
                  **details) -> dict:
        if not isinstance(text, str) or semantics not in {"delta", "cumulative", "final"}:
            raise ValueError("text must declare delta, cumulative, or final semantics")
        with self._lock:
            frontier = self._last_frame if audio_end_frame is None else audio_end_frame
            if (isinstance(frontier, bool) or not isinstance(frontier, int)
                    or frontier < 0 or frontier > self._last_frame):
                raise ValueError("text frontier exceeds the released audio")
            if text.strip():
                if self.first_text_ms is None:
                    self.first_text_ms = self.elapsed_ms()
                self.text_events += 1
            return self.record("text", text=text, semantics=semantics,
                               audio_end_frame=frontier,
                               audio_end_ms=frontier * 1000 / self.audio.sample_rate,
                               **details)

    def summary(self) -> dict:
        with self._lock:
            return {"pacing": self.pacing, "first_text_ms": self.first_text_ms,
                    "text_events": self.text_events, "released_frames": self._last_frame,
                    "max_source_lateness_ms": self.max_source_lateness_ms,
                    "stream_wall_ms": self.elapsed_ms()}
