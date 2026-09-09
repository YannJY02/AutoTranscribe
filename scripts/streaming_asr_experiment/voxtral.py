"""Finite PCM source for the pinned, otherwise unchanged voxmlx microphone loop.

Model imports occur only in load(). Each run invokes the upstream function anew
and retains its incremental encoder, decoder, EOS resets, and final flush.
"""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass, field
import hashlib
import importlib
from pathlib import Path
import subprocess
import sys
import threading
import time
from types import SimpleNamespace
from typing import Any


SOURCE_REVISION = "e6d193e85e84e30f26e370c66973ce287b8a9d57"
MODEL_ID = "T0mSIlver/Voxtral-Mini-4B-Realtime-2602-MLX-4bit"
MODEL_REVISION = "e41b00294733d2db2fe767cd7c5454ba617c2bed"
BLOCK_FRAMES = 1280
SAMPLE_RATE = 16000
NATIVE_DELAY_MS = 480
_MISSING = object()


class _EndOfInput(KeyboardInterrupt):
    """Caught only by the upstream loop's normal stop/finally path."""


@dataclass
class _State:
    module: Any
    model: Any
    tokenizer: Any
    config: dict
    model_path: Path
    run_lock: Any = field(default_factory=threading.Lock)


def _validate_args(args):
    if getattr(args, "latency_ms", NATIVE_DELAY_MS) != NATIVE_DELAY_MS:
        raise ValueError("the pinned voxmlx baseline uses its native 480 ms delay")
    if getattr(args, "language", "auto") != "auto":
        raise ValueError("the native voxmlx stream uses automatic language detection")
    limit = getattr(args, "max_tokens", 4096)
    if isinstance(limit, bool) or not isinstance(limit, int) or limit <= 0:
        raise ValueError("max_tokens must be a positive integer")


def load(args, journal):
    """Load local, pinned source and weights once; never download implicitly."""
    _validate_args(args)
    root = Path(args.runtime_root).expanduser().resolve()
    model_path = Path(args.model_path).expanduser().resolve()
    source_file = root / "voxmlx" / "stream.py"
    if not source_file.is_file():
        raise ValueError("runtime_root must contain the pinned voxmlx checkout")
    revision = subprocess.check_output(
        ["git", "-C", str(root), "rev-parse", "HEAD"], text=True
    ).strip()
    dirty = subprocess.check_output(
        ["git", "-C", str(root), "status", "--porcelain", "--untracked-files=no"],
        text=True,
    ).strip()
    if revision != SOURCE_REVISION or dirty:
        raise ValueError("voxmlx requires the exact unmodified source revision")
    for name in ("config.json", "model.safetensors", "model.safetensors.index.json", "tekken.json"):
        if not (model_path / name).is_file():
            raise ValueError(f"missing local Voxtral model file: {name}")
    sys.path.insert(0, str(root))
    try:
        package = importlib.import_module("voxmlx")
        module = importlib.import_module("voxmlx.stream")
    finally:
        sys.path.remove(str(root))
    if Path(module.__file__).resolve() != source_file:
        raise RuntimeError("an already imported voxmlx module has a different source path")
    import mlx.core as mx

    mx.random.seed(getattr(args, "seed", 0))
    model, tokenizer, config = package.load_model(str(model_path))
    metadata = {
        "runtime": "awni/voxmlx", "source_revision": revision,
        "runtime_root": str(root),
        "source_sha256": hashlib.sha256(source_file.read_bytes()).hexdigest(),
        "model_path": str(model_path),
        "expected_model_id": MODEL_ID, "expected_model_revision": MODEL_REVISION,
        "model_weights_bytes": (model_path / "model.safetensors").stat().st_size,
        "quantization": config.get("quantization"),
        "native_delay_ms": NATIVE_DELAY_MS, "native_delay_tokens": 6,
        "native_block_frames": BLOCK_FRAMES, "native_chunk_ms": 80,
        "requested_chunk_ms": getattr(args, "chunk_ms", None),
        "left_padding_tokens": 32, "right_padding_tokens": 17,
        "decoder_cache_max_tokens": 8192, "encoder_cache_max_frames": 100000,
        "configured_encoder_sliding_window": 750,
        "encoder_sliding_window_applied": False,
        "cache_scope": "fresh stream-local caches per run; model weights reused",
        "source_clock": "session-relative; native setup can cause recorded release lateness",
        "flush_timing_scope": "native finally from InputStream.stop through function return",
        "output_semantics": "exact concatenation of native decoded-token print deltas",
        "coverage_limit": "native EOS resets can discard buffered audio or embeddings",
        "language": "auto", "temperature": 0.0,
    }
    journal.record("voxtral_native_configuration", **metadata)
    return _State(module, model, tokenizer, config, model_path), metadata


def _snapshot(local_variables):
    """Small observations of the pinned loop; never copy tensors or change state."""
    values = {
        "tail_flush_eligible": local_variables.get("cache") is not None
        and local_variables.get("y") is not None,
        "prefilled": bool(local_variables.get("prefilled", False)),
    }
    for name in ("n_audio_samples_fed", "n_total_decoded"):
        if name in local_variables:
            values[name] = int(local_variables[name])
    for name in ("audio_buf", "pending_audio"):
        if name in local_variables:
            values[name + "_frames"] = len(local_variables[name])
    return values


class _FiniteInput:
    def __init__(self, pcm, frames, session):
        self.pcm, self.frames, self.session = pcm, frames, session
        self.callback = None
        self.thread = None
        self.cancelled = threading.Event()
        self.done = threading.Event()
        self.lock = threading.RLock()
        self.delivered_frames = 0
        self.error = None
        self.complete = False
        self.eof_requested = False
        self.flush_start_ms = None
        self.flush_snapshot = None

    def input_stream(self, *, samplerate, channels, dtype, blocksize, callback):
        if (samplerate, channels, dtype, blocksize) != (SAMPLE_RATE, 1, "float32", BLOCK_FRAMES):
            raise RuntimeError("upstream audio capture configuration changed")
        if self.callback is not None:
            raise RuntimeError("one finite source may create only one InputStream")
        self.callback = callback
        return self

    def start(self):
        self.session.record("native_audio_source_started", block_frames=BLOCK_FRAMES,
                            expected_frames=self.frames)
        self.thread = threading.Thread(target=self._produce, name="voxtral-finite-pcm", daemon=True)
        self.thread.start()

    def _produce(self):
        try:
            for start in range(0, self.frames, BLOCK_FRAMES):
                if self.cancelled.is_set():
                    return
                end = min(start + BLOCK_FRAMES, self.frames)
                self.session.pace_to(end)
                if self.cancelled.is_set():
                    return
                with self.lock:
                    self.callback(self.pcm[start:end].reshape(-1, 1), end - start, None, None)
                    self.delivered_frames = end
                    self.session.record("native_audio_callback", audio_start_frame=start,
                                        audio_end_frame=end)
            self.complete = True
        except BaseException as error:
            self.error = error
        finally:
            self.done.set()

    def frontier(self):
        with self.lock:
            return self.delivered_frames

    def shutdown(self):
        self.cancelled.set()
        if self.thread is not None:
            self.thread.join(timeout=2)

    def stop(self):
        if self.flush_start_ms is None:
            self.flush_start_ms = self.session.elapsed_ms()
            self.flush_snapshot = _snapshot(sys._getframe(1).f_locals)
            self.session.record("native_flush_started", eof_requested=self.eof_requested,
                                audio_end_frame=self.frontier(), **self.flush_snapshot)
        self.shutdown()

    def close(self):
        self.shutdown()


class _NativeClock:
    def __init__(self, source):
        self.source = source

    @staticmethod
    def monotonic():
        return time.monotonic()

    def _checkpoint(self, caller):
        source = self.source
        if source.error is not None:
            raise source.error
        if source.done.is_set() and not source.eof_requested:
            # An accelerated producer can finish after the native loop drains an
            # empty buffer. Let that loop consume the newly arrived PCM before
            # asking its finally block to flush (which requires decoder prefill).
            local_variables = caller.f_locals
            if not local_variables.get("prefilled") and len(local_variables.get("audio_buf", ())) > 0:
                return
            if not source.complete:
                raise RuntimeError("finite audio source stopped before all PCM was delivered")
            source.eof_requested = True
            source.session.record("native_eof_requested", audio_end_frame=source.frontier(),
                                  **_snapshot(local_variables))
            raise _EndOfInput()

    def sleep(self, seconds):
        caller = sys._getframe(1)
        self._checkpoint(caller)
        time.sleep(seconds)
        self._checkpoint(caller)


class _TokenOutput:
    def __init__(self, tokenizer, source, session, max_tokens):
        self.tokenizer, self.source, self.session = tokenizer, source, session
        self.max_tokens = max_tokens
        self.tokens = 0
        self.eos_count = 0
        self.pending = deque()
        self.parts = []

    def __getattr__(self, name):
        return getattr(self.tokenizer, name)

    def decode(self, token_ids, *args, **kwargs):
        ids = [int(token) for token in token_ids]
        if self.tokens + len(ids) > self.max_tokens:
            self.session.record("native_token_limit_exceeded", max_tokens=self.max_tokens,
                                decoded_tokens=self.tokens, raw={"next_token_ids": ids})
            raise RuntimeError("Voxtral exceeded the declared native token limit")
        value = self.tokenizer.decode(token_ids, *args, **kwargs)
        if not isinstance(value, str) or self.pending:
            raise RuntimeError("upstream native token decode/print contract changed")
        self.tokens += len(ids)
        self.pending.append((value, ids))
        return value

    def print(self, *values, **kwargs):
        separator, ending = kwargs.get("sep", " "), kwargs.get("end", "\n")
        value = separator.join(str(item) for item in values)
        if ending == "" and len(values) == 1 and self.pending and value == self.pending[0][0]:
            delta, ids = self.pending.popleft()
            self.parts.append(delta)
            self.session.emit_text(delta, semantics="delta", audio_end_frame=self.source.frontier(),
                                   raw={"native_token_ids": ids,
                                        "during_flush": self.source.flush_start_ms is not None})
        elif not values and kwargs.get("flush") is True:
            self.eos_count += 1
            self.session.record("native_eos", audio_end_frame=self.source.frontier(),
                                raw={"printed_separator": ending})
        else:
            self.session.record("native_diagnostic", raw={"text": value + ending})


def run(model_state, audio, session, args):
    _validate_args(args)
    if audio.sample_rate != SAMPLE_RATE or audio.frames <= 0:
        raise ValueError("Voxtral requires nonempty mono 16-kHz audio")
    if not model_state.run_lock.acquire(blocking=False):
        raise RuntimeError("Voxtral model instances cannot run concurrent native sessions")
    source = None
    saved = {}
    failure = None
    try:
        pcm = audio.as_float32()
        if len(pcm) != audio.frames:
            raise ValueError("decoded PCM length does not match the finite audio source")
        source = _FiniteInput(pcm, audio.frames, session)
        output = _TokenOutput(model_state.tokenizer, source, session, getattr(args, "max_tokens", 4096))
        module = model_state.module
        hooks = {
            "load_model": lambda _: (model_state.model, output, model_state.config),
            "sd": SimpleNamespace(InputStream=source.input_stream),
            "time": _NativeClock(source),
            "print": output.print,
        }
        for name, value in hooks.items():
            saved[name] = getattr(module, name, _MISSING)
            setattr(module, name, value)
        session.record("native_stream_configuration", native_delay_ms=NATIVE_DELAY_MS,
                       native_chunk_ms=80, requested_chunk_ms=getattr(args, "chunk_ms", None),
                       max_tokens=output.max_tokens,
                       cache_scope="new stream locals; loaded model weights reused",
                       encoder_cache_max_frames=100000, encoder_sliding_window_applied=False,
                       raw={"padding_left_tokens": 32, "padding_right_tokens": 17})
        module.stream_transcribe(model_path=str(model_state.model_path), temperature=0.0)
        if source.error is not None:
            raise source.error
        if not source.eof_requested or not source.complete or source.frontier() != audio.frames:
            raise RuntimeError("native loop returned without completing the adapter's finite EOF")
        if source.flush_start_ms is None or output.pending:
            raise RuntimeError("native loop returned without its expected flush/output boundary")
        if source.thread is not None and source.thread.is_alive():
            raise RuntimeError("finite audio producer did not stop")
        flush_ms = session.elapsed_ms() - source.flush_start_ms
        session.record("native_flush_completed", flush_ms=flush_ms,
                       audio_end_frame=source.frontier(), decoded_tokens=output.tokens)
        return {"text": "".join(output.parts), "decoded_tokens": output.tokens,
                "native_eos_count": output.eos_count, "native_delay_ms": NATIVE_DELAY_MS,
                "native_chunk_ms": 80, "input_frames_delivered": source.frontier(),
                "native_flush_ms": flush_ms, "native_flush_snapshot": source.flush_snapshot,
                "native_flush_completed": True}
    except BaseException as error:
        failure = error
        if source is not None and source.flush_start_ms is not None:
            session.record("native_flush_unconfirmed", observed_ms=session.elapsed_ms() - source.flush_start_ms,
                           error_type=type(error).__name__)
        session.record("native_stream_failed", error_type=type(error).__name__, error=str(error))
        raise
    finally:
        if source is not None:
            source.shutdown()
            if source.thread is not None and source.thread.is_alive():
                session.record("native_source_shutdown_failed", original_failure=type(failure).__name__
                               if failure is not None else None)
        for name, value in saved.items():
            if value is _MISSING:
                delattr(model_state.module, name)
            else:
                setattr(model_state.module, name, value)
        model_state.run_lock.release()
