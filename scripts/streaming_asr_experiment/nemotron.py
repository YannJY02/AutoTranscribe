"""Nemotron 3.5 RNNT streaming through the official NeMo-Speech.cpp C ABI.

The library and model are loaded only by ``load``. Each ``run`` creates a new
stream on the same recognizer; no application runtime or preferences are used.
ABI declarations match the official v0.1.0 ``include/nemo_speech/asr.h``.
"""

from __future__ import annotations

import ctypes as C
from dataclasses import dataclass
from pathlib import Path
import time


LATENCY_RIGHT_CONTEXT = {80: 0, 160: 1, 320: 3, 560: 6, 1120: 13}
SDK_REVISION = "4f9676226f667d14608487df744f375db87127f8"
MODEL_REVISION = "1c8deaecc64b91f034d73e08dd8b64625eb3395d"


class _BackendConfig(C.Structure):
    _fields_ = [("size", C.c_size_t), ("gpu", C.c_int32)]


class _ModelConfig(C.Structure):
    _fields_ = [("size", C.c_size_t), ("path", C.c_char_p), ("name", C.c_char_p)]


class _StreamingConfig(C.Structure):
    _fields_ = [("size", C.c_size_t), ("chunk_size", C.c_float),
                ("ctc_left_padding", C.c_float), ("ctc_right_padding", C.c_float),
                ("rnnt_right_context", C.c_int32)]


class _EndpointingConfig(C.Structure):
    _fields_ = [("size", C.c_size_t), ("enable", C.c_bool),
                ("vad_based", C.c_bool), ("stop_history_eou_ms", C.c_int32)]


class _RecognizerConfig(C.Structure):
    _fields_ = [("size", C.c_size_t), ("backend", C.POINTER(_BackendConfig)),
                ("model", C.POINTER(_ModelConfig)), ("streaming", C.POINTER(_StreamingConfig)),
                ("decoder", C.c_void_p), ("vad", C.c_void_p),
                ("endpointing", C.POINTER(_EndpointingConfig)),
                ("postproc", C.c_void_p), ("diar", C.c_void_p), ("batching", C.c_void_p)]


class _RecognitionOptions(C.Structure):
    _fields_ = [("size", C.c_size_t), ("request_id", C.c_char_p),
                ("language_code", C.c_char_p), ("interim_results", C.c_bool),
                ("enable_word_time_offsets", C.c_bool),
                ("enable_automatic_punctuation", C.c_bool),
                ("verbatim_transcripts", C.c_bool), ("profanity_filter", C.c_bool),
                ("stop_history_eou_ms", C.c_int32), ("speech_contexts", C.c_void_p),
                ("speech_context_count", C.c_size_t), ("max_alternatives", C.c_int32),
                ("enable_speaker_diarization", C.c_bool), ("max_speaker_count", C.c_int32)]


def _decode(value: bytes | None) -> str:
    return value.decode("utf-8") if value else ""


class _Bindings:
    """Own C signatures and copy result/error memory before its owner expires."""

    def __init__(self, library_path: Path):
        self.lib = C.CDLL(str(library_path))
        handle, count = C.c_void_p, C.c_size_t
        output = C.POINTER(handle)
        signatures = {
            "version": (C.c_char_p, []),
            "last_error": (C.c_char_p, []),
            "recognition_options_default": (_RecognitionOptions, []),
            "create": (C.c_int, [C.POINTER(_RecognizerConfig), output]),
            "destroy": (None, [handle]),
            "streaming_recognize": (C.c_int, [handle, C.POINTER(_RecognitionOptions), output]),
            "stream_push_f32": (C.c_int, [handle, C.POINTER(C.c_float), count, C.c_int32]),
            "stream_next": (C.c_int, [handle, output]),
            "stream_finish": (C.c_int, [handle]),
            "stream_close": (None, [handle]),
            "result_destroy": (None, [handle]),
            "result_is_final": (C.c_bool, [handle]),
            "result_audio_processed": (C.c_float, [handle]),
            "result_alternative_count": (count, [handle]),
            "result_transcript": (C.c_char_p, [handle, count]),
            "result_confidence": (C.c_float, [handle, count]),
            "result_word_count": (count, [handle, count]),
            "result_word_text": (C.c_char_p, [handle, count, count]),
            "result_word_start_time": (C.c_int32, [handle, count, count]),
            "result_word_end_time": (C.c_int32, [handle, count, count]),
            "result_word_confidence": (C.c_float, [handle, count, count]),
            "result_language_count": (count, [handle, count]),
            "result_language_code": (C.c_char_p, [handle, count, count]),
        }
        for suffix, (return_type, argument_types) in signatures.items():
            function = getattr(self.lib, f"nemo_speech_asr_{suffix}")
            function.restype, function.argtypes = return_type, argument_types
            setattr(self, suffix, function)

    def check(self, status: int, operation: str) -> None:
        if status:
            # The next C API call can invalidate this thread-local error.
            detail = (self.last_error() or b"").decode("utf-8", errors="replace")
            raise RuntimeError(f"NeMo-Speech {operation} failed with status {status}: {detail}")

    def create_recognizer(self, model_path: Path, right_context: int):
        backend = _BackendConfig(C.sizeof(_BackendConfig), 0)
        model = _ModelConfig(C.sizeof(_ModelConfig), str(model_path).encode(), None)
        # These CTC fields still require valid values in the shared config.
        streaming = _StreamingConfig(C.sizeof(_StreamingConfig), 0.16, 1.92, 1.92, right_context)
        endpointing = _EndpointingConfig(C.sizeof(_EndpointingConfig), False, False, 0)
        config = _RecognizerConfig(size=C.sizeof(_RecognizerConfig),
                                   backend=C.pointer(backend), model=C.pointer(model),
                                   streaming=C.pointer(streaming), endpointing=C.pointer(endpointing))
        result = C.c_void_p()
        self.check(self.create(C.byref(config), C.byref(result)), "create")
        if not result.value:
            raise RuntimeError("NeMo-Speech create succeeded without a recognizer")
        return result

    def open_stream(self, recognizer, language: str):
        options = self.recognition_options_default()
        options.language_code = language.encode()
        options.interim_results = True
        options.enable_word_time_offsets = True
        options.enable_automatic_punctuation = False
        options.profanity_filter = False
        options.enable_speaker_diarization = False
        result = C.c_void_p()
        self.check(self.streaming_recognize(recognizer, C.byref(options), C.byref(result)),
                   "streaming_recognize")
        if not result.value:
            raise RuntimeError("NeMo-Speech streaming_recognize succeeded without a stream")
        return result

    def push(self, stream, samples) -> None:
        pointer = samples.ctypes.data_as(C.POINTER(C.c_float))
        self.check(self.stream_push_f32(stream, pointer, len(samples), 16000), "stream_push_f32")

    def pull(self, stream) -> dict | None:
        result = C.c_void_p()
        self.check(self.stream_next(stream, C.byref(result)), "stream_next")
        if not result.value:
            return None
        try:
            alternatives = int(self.result_alternative_count(result))
            words, languages = [], []
            if alternatives:
                for index in range(self.result_word_count(result, 0)):
                    words.append({"text": _decode(self.result_word_text(result, 0, index)),
                                  "start_ms": int(self.result_word_start_time(result, 0, index)),
                                  "end_ms": int(self.result_word_end_time(result, 0, index)),
                                  "confidence": float(self.result_word_confidence(result, 0, index))})
                languages = [_decode(self.result_language_code(result, 0, index))
                             for index in range(self.result_language_count(result, 0))]
            return {"text": _decode(self.result_transcript(result, 0)) if alternatives else "",
                    "is_final": bool(self.result_is_final(result)),
                    "audio_processed_seconds": float(self.result_audio_processed(result)),
                    "confidence": float(self.result_confidence(result, 0)) if alternatives else None,
                    "alternatives": alternatives, "words": words, "languages": languages}
        finally:
            self.result_destroy(result)

    def finish(self, stream) -> None:
        # This call performs synchronous tail decoding; next only retrieves it.
        self.check(self.stream_finish(stream), "stream_finish")


@dataclass
class _State:
    api: _Bindings
    recognizer: C.c_void_p | None
    language: str
    latency_ms: int
    running: bool = False


def _latency(args) -> int:
    value = getattr(args, "latency_ms", None)
    value = 320 if value is None else value
    if isinstance(value, bool) or value not in LATENCY_RIGHT_CONTEXT:
        supported = ", ".join(map(str, LATENCY_RIGHT_CONTEXT))
        raise ValueError(f"Nemotron latency_ms must be one of {supported}; it is not input chunk_ms")
    return int(value)


def _language(args) -> str:
    value = getattr(args, "language", "auto")
    if not isinstance(value, str) or not value.strip() or "\0" in value:
        raise ValueError("Nemotron language must be a nonempty fixed prompt such as auto, en-US, or zh-CN")
    return value


def _library_path(args) -> Path:
    explicit = getattr(args, "library_path", None)
    if explicit:
        path = Path(explicit).expanduser().resolve()
        if not path.is_file():
            raise FileNotFoundError(path)
        return path
    root = getattr(args, "runtime_root", None)
    if root:
        root = Path(root).expanduser().resolve()
        for relative in ("lib/libnemo_speech_asr_c.1.dylib",
                         "nemo-speech/lib/libnemo_speech_asr_c.1.dylib"):
            path = root / relative
            if path.is_file():
                return path.resolve()
    raise ValueError("Nemotron requires --library-path or --runtime-root for the official macOS SDK")


def load(args, journal):
    """Load one Metal recognizer. Lazy graph setup remains in the first stream."""
    latency, language = _latency(args), _language(args)
    model_path = Path(args.model_path).expanduser().resolve()
    with model_path.open("rb") as model_file:
        if model_file.read(4) != b"GGUF":
            raise ValueError("Nemotron model_path must name the single GGUF model")
    library_path = _library_path(args)
    start = time.monotonic_ns()
    api = _Bindings(library_path)
    version = _decode(api.version())
    journal.record("nemotron_library_ready", version=version,
                   duration_ms=(time.monotonic_ns() - start) / 1_000_000)
    start = time.monotonic_ns()
    recognizer = api.create_recognizer(model_path, LATENCY_RIGHT_CONTEXT[latency])
    create_ms = (time.monotonic_ns() - start) / 1_000_000
    metadata = {"adapter": "nemo-speech-c-abi", "runtime_version": version,
                "library_path": str(library_path), "model_path": str(model_path),
                "abi_reference_revision": SDK_REVISION,
                "expected_model_revision": MODEL_REVISION,
                "backend_requested": "Metal", "gpu_device_index": 0,
                "backend_confirmation": "native stderr; no C API backend readback",
                "recognizer_create_ms": create_ms, "warmup_performed": False,
                "lazy_graph_setup_in_first_stream": True,
                "sample_rate": 16000, "latency_ms": latency,
                "rnnt_right_context": LATENCY_RIGHT_CONTEXT[latency],
                "latency_semantics": "nominal encoder mode; not measured publication delay",
                "language_prompt": language, "language_prompt_scope": "fixed per stream",
                "decoder": "greedy", "endpointing": False, "vad": False,
                "punctuation_model": False, "diarization": False,
                "word_timestamps": "native RNNT final-result offsets",
                "partial_text_semantics": "cumulative whole stream",
                "native_audio_processed_semantics": "input fed frontier, not token alignment",
                "native_next_timing_scope": "C next plus result readback and release",
                "seed_applied": False, "max_tokens_applicable": False}
    return _State(api, recognizer, language, latency), metadata


def run(model_state, audio, session, args) -> dict:
    """Pace finite input, drain native partials, then require the flushed final."""
    import numpy as np

    state = model_state
    if state.recognizer is None or state.running:
        raise RuntimeError("Nemotron recognizer is closed or already running a stream")
    if _latency(args) != state.latency_ms or _language(args) != state.language:
        raise ValueError("Nemotron latency/language changed after load; create a matching recognizer")
    if audio.sample_rate != 16000 or audio.frames <= 0:
        raise ValueError("Nemotron experiment requires nonempty mono 16-kHz audio")
    chunk_ms = getattr(args, "chunk_ms", 320)
    if not isinstance(chunk_ms, (int, float)) or isinstance(chunk_ms, bool) or not np.isfinite(chunk_ms) or chunk_ms <= 0:
        raise ValueError("Nemotron chunk_ms must be finite and positive")
    chunk_frames = round(audio.sample_rate * chunk_ms / 1000)
    if chunk_frames < 1:
        raise ValueError("Nemotron chunk_ms is shorter than one audio frame")
    samples = np.ascontiguousarray(audio.as_float32(), dtype=np.float32)
    if samples.ndim != 1 or len(samples) != audio.frames or not np.isfinite(samples).all():
        raise ValueError("Nemotron PCM conversion produced invalid samples")

    stream = None
    state.running = True
    final_result, latest_text = None, None
    decode_ms = finish_ms = 0.0
    result_count = 0

    def drain(end_frame: int, *, after_finish: bool) -> None:
        nonlocal final_result, latest_text, decode_ms, result_count
        while True:
            start = time.monotonic_ns()
            result = state.api.pull(stream)
            duration_ms = (time.monotonic_ns() - start) / 1_000_000
            decode_ms += duration_ms
            if result is not None:
                result_count += 1
                if result["text"] != latest_text or result["is_final"]:
                    session.emit_text(result["text"], semantics="cumulative",
                                      audio_end_frame=end_frame, is_final=result["is_final"],
                                      after_finish=after_finish)
                latest_text = result["text"]
                session.record("nemotron_result", **result, audio_end_frame=end_frame,
                               native_position_semantics="input fed frontier", after_finish=after_finish)
                if result["is_final"]:
                    if not after_finish or final_result is not None:
                        raise RuntimeError("Nemotron emitted an unexpected endpoint with endpointing disabled")
                    final_result = result
                elif after_finish:
                    raise RuntimeError("Nemotron emitted a partial after end-of-stream finish")
            session.record("nemotron_next", duration_ms=duration_ms,
                           returned_result=result is not None, audio_end_frame=end_frame,
                           after_finish=after_finish)
            if result is None:
                return

    try:
        start = time.monotonic_ns()
        stream = state.api.open_stream(state.recognizer, state.language)
        session.record("nemotron_stream_ready", duration_ms=(time.monotonic_ns() - start) / 1_000_000,
                       native_state="new stream", recognizer="reused loaded model",
                       input_chunk_frames=chunk_frames, latency_ms=state.latency_ms)
        for start_frame in range(0, audio.frames, chunk_frames):
            end_frame = min(audio.frames, start_frame + chunk_frames)
            session.pace_to(end_frame)
            start = time.monotonic_ns()
            state.api.push(stream, samples[start_frame:end_frame])
            session.record("nemotron_push", duration_ms=(time.monotonic_ns() - start) / 1_000_000,
                           audio_start_frame=start_frame, audio_end_frame=end_frame)
            drain(end_frame, after_finish=False)
        session.record("nemotron_finish_started", audio_end_frame=audio.frames)
        start = time.monotonic_ns()
        finish_outcome = "error"
        try:
            state.api.finish(stream)
            finish_outcome = "ok"
        finally:
            finish_ms = (time.monotonic_ns() - start) / 1_000_000
            session.record("nemotron_finish_returned", duration_ms=finish_ms,
                           audio_end_frame=audio.frames, outcome=finish_outcome)
        drain(audio.frames, after_finish=True)
        if final_result is None:
            raise RuntimeError("Nemotron finished without a final result; partial output is incomplete")
        return {"text": final_result["text"], "languages": final_result["languages"],
                "words": final_result["words"], "native_final_received": True,
                "native_result_count": result_count, "native_finish_ms": finish_ms,
                "native_next_ms": decode_ms, "native_decode_and_finish_ms": decode_ms + finish_ms}
    finally:
        try:
            if stream is not None:
                state.api.stream_close(stream)
        finally:
            state.running = False


def close(model_state) -> None:
    """Release the recognizer once, after all measured streams have ended."""
    if model_state.running:
        raise RuntimeError("cannot close a running Nemotron recognizer")
    recognizer, model_state.recognizer = model_state.recognizer, None
    if recognizer is not None:
        model_state.api.destroy(recognizer)
