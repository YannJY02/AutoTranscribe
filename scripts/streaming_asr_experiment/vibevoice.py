"""Bounded VibeVoice-ASR-Streaming-1.5B replay through its native KV API.

Only the language decoder is 4-bit. Audio encoders and connectors stay BF16.
Runtime imports are deliberately deferred so protocol tests need no MLX/model.
"""

from __future__ import annotations

import importlib.metadata
import json
import math
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterator


MODEL_ID = "microsoft/VibeVoice-ASR-Streaming-1.5B"
MODEL_REVISION = "4262d23d8a539a6530cf64fbd0b1751ef9a30853"
RUNTIME_REVISION = "17001a6950956302f15b53d86b601324efe716ba"
SAMPLE_RATE = 24000
CHUNK_SAMPLES = 70400
WINDOW_SAMPLES = 83200
MAX_DURATION_SECONDS = 8 * 60
PER_CHUNK_TOKEN_LIMIT = 256


@dataclass(frozen=True)
class Window:
    index: int
    model_start_sample: int
    real_model_samples: int
    source_start_frame: int
    source_end_frame: int
    local_output_start: int
    consumed_end_frame: int
    final: bool


@dataclass
class ModelState:
    model: Any
    mx: Any
    resample: Callable[..., Any]
    resample_halo_frames: int
    metadata: dict[str, Any]


def _ceil_div(numerator: int, denominator: int) -> int:
    return (numerator + denominator - 1) // denominator


def windows(total_frames: int, source_rate: int, halo_frames: int = 0) -> Iterator[Window]:
    """Plan phase-aligned windows; source_end includes actual FIR lookahead."""
    if total_frames <= 0 or source_rate <= 0 or halo_frames < 0:
        raise ValueError("Audio length/rate must be positive and halo nonnegative")
    gcd = math.gcd(source_rate, SAMPLE_RATE)
    up, down = SAMPLE_RATE // gcd, source_rate // gcd
    total_model_samples = _ceil_div(total_frames * up, down)
    starts = range(0, total_model_samples, CHUNK_SAMPLES)
    for index, start in enumerate(starts):
        end = min(start + WINDOW_SAMPLES, total_model_samples)
        # The reduced input ratio fixes the polyphase origin across windows.
        read_start = max(0, (start * down // up - halo_frames) // down * down)
        read_end = min(total_frames, _ceil_div(end * down, up) + halo_frames)
        consumed_end = min(total_frames, _ceil_div((start + CHUNK_SAMPLES) * down, up))
        yield Window(
            index=index,
            model_start_sample=start,
            real_model_samples=end - start,
            source_start_frame=read_start,
            source_end_frame=read_end,
            local_output_start=start - read_start * up // down,
            consumed_end_frame=consumed_end,
            final=start + CHUNK_SAMPLES >= total_model_samples,
        )


_MARKERS = re.compile(
    r"(?P<special><\|[^<>]*\|>)|"
    r"(?P<label>^[ \t]*Speaker[ \t]+(?P<speaker>\d+)[ \t]*:[ \t]*)",
    re.MULTILINE,
)


class SpeakerParser:
    """Buffer split control labels without charging them as recognized text.

The released protocol uses newline-prefixed plain-text Speaker k: labels.
Continuation chunks concatenate verbatim; no spaces are guessed between them.
Offsets below are text offsets, never acoustic/word timestamps.
"""

    def __init__(self) -> None:
        self.raw = ""
        self.text = ""
        self.events: list[dict[str, Any]] = []

    def feed(self, raw: str, *, final: bool = False) -> dict[str, Any]:
        self.raw += raw
        cut = len(self.raw)
        warnings = []
        line_start = self.raw.rfind("\n") + 1
        line = self.raw[line_start:].lstrip(" \t")
        if not final and not line:
            # Indentation can arrive before the rest of a newline-prefixed label.
            cut = line_start
        partial_speaker = bool(line) and (
            "Speaker".startswith(line)
            or re.fullmatch(r"Speaker[ \t]+(?:\d+[ \t]*)?", line) is not None
        )
        incomplete_label = re.fullmatch(r"Speaker[ \t]+\d+[ \t]*", line)
        if partial_speaker and (not final or incomplete_label):
            cut = line_start
            if final:
                warnings.append("incomplete_speaker_label")
        special_start = self.raw.rfind("<|")
        if special_start >= 0 and "|>" not in self.raw[special_start:]:
            cut = min(cut, special_start)
            if final:
                warnings.append("incomplete_special_token")
        elif not final and self.raw.endswith("<"):
            cut = min(cut, len(self.raw) - 1)

        visible = self.raw[:cut]
        parts, events, offset = [], [], 0
        text_length = 0
        for match in _MARKERS.finditer(visible):
            part = visible[offset:match.start()]
            parts.append(part)
            text_length += len(part)
            if match.group("label"):
                events.append({
                    "speaker_id": int(match.group("speaker")),
                    "raw_offset": match.start(),
                    "text_offset": text_length,
                    "raw_label": match.group(),
                })
            offset = match.end()
        parts.append(visible[offset:])
        text = "".join(parts)
        trim = len(text) - len(text.lstrip())
        text = text.lstrip()
        for event in events:
            event["text_offset"] = max(0, event["text_offset"] - trim)
        if not text.startswith(self.text):
            raise RuntimeError("VibeVoice parser attempted to revise emitted text")
        new_events = events[len(self.events):]
        changed = text != self.text
        self.text, self.events = text, events
        return {"text": text, "changed": changed, "new_speakers": new_events, "warnings": warnings}


def _read_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"Expected JSON object: {path.name}")
    return value


def _validate_model_path(model_path: Path) -> dict[str, Any]:
    if not model_path.is_dir():
        raise ValueError("VibeVoice requires a local converted model directory")
    config = _read_json(model_path / "config.json")
    decoder = config.get("decoder_config", {})
    expected = {"hidden_size": 1536, "num_hidden_layers": 28, "num_key_value_heads": 2}
    if any(decoder.get(key) != value for key, value in expected.items()):
        raise ValueError("This driver requires the 1.5B streaming decoder configuration")
    if "VibeVoiceForASRStreamingTraining" not in config.get("architectures", []):
        raise ValueError("This driver requires the ASR streaming checkpoint")
    preprocessor = _read_json(model_path / "preprocessor_config.json")
    expected_preprocessor = {
        "target_sample_rate": SAMPLE_RATE,
        "speech_tok_compress_ratio": 3200,
        "chunk_frames": 22,
        "lookahead_frames": 4,
        "normalize_audio": False,
    }
    if any(preprocessor.get(key) != value for key, value in expected_preprocessor.items()):
        raise ValueError("Streaming processor sidecar differs from the pinned checkpoint")
    tokenizer = _read_json(model_path / "tokenizer_config.json")
    added = tokenizer.get("added_tokens_decoder", {})
    if not any(item.get("content") == "<|text_chunk_end|>" for item in added.values()):
        raise ValueError("Converted tokenizer is missing <|text_chunk_end|>")
    if not (model_path / "tokenizer.json").is_file() or not any(model_path.glob("*.safetensors")):
        raise ValueError("Converted model is missing tokenizer.json or safetensors weights")
    quantization = config.get("quantization", config.get("quantization_config", {}))
    if quantization.get("bits") != 4 or quantization.get("group_size") != 64:
        raise ValueError("The comparison requires affine 4-bit, group-size-64 conversion")
    if quantization.get("mode", "affine") != "affine":
        raise ValueError("The comparison requires affine quantization")
    return config


def _weight_summary(model_path: Path) -> dict[str, Any]:
    """Inspect actual storage: upstream conversion leaves config dtype unchanged."""
    nonquantized_bytes = quantized_bytes = 0
    tensor_count = 0
    for path in sorted(model_path.glob("*.safetensors")):
        with path.open("rb") as source:
            header_size = int.from_bytes(source.read(8), "little")
            if not 0 < header_size <= 16 * 1024 * 1024:
                raise ValueError(f"Invalid safetensors header size: {path.name}")
            header = json.loads(source.read(header_size))
        for name, tensor in header.items():
            if name == "__metadata__":
                continue
            size = tensor["data_offsets"][1] - tensor["data_offsets"][0]
            tensor_count += 1
            if not name.startswith("language_model."):
                if tensor["dtype"] != "BF16":
                    raise ValueError("Audio encoders/connectors must have actual BF16 weights")
                nonquantized_bytes += size
            else:
                if name.endswith(".weight") and len(tensor["shape"]) == 2 and tensor["dtype"] != "U32":
                    raise ValueError("Language-model matrices must have packed 4-bit weights")
                quantized_bytes += size
    if not tensor_count or not nonquantized_bytes or not quantized_bytes:
        raise ValueError("Converted weights are missing expected model components")
    return {"tensor_count": tensor_count, "non_language_model_bytes": nonquantized_bytes,
            "language_model_bytes": quantized_bytes,
            "total_tensor_bytes": nonquantized_bytes + quantized_bytes}


def drop_verified_tied_lm_head(
    weights: dict[str, Any], *, tied_embeddings: bool, arrays_equal: Callable[[Any, Any], bool],
) -> dict[str, Any]:
    """Remove a redundant source head only after equality is actually established.

The pinned converter maps the separate checkpoint lm_head into a module that
does not exist for a tied decoder. Keep strict loading and reject unequal data.
This helper operates on upstream-sanitized weights during conversion only.
"""
    head_name = "language_model.lm_head.weight"
    if not tied_embeddings or head_name not in weights:
        return weights
    embedding = weights.get("language_model.model.embed_tokens.weight")
    head = weights[head_name]
    if embedding is None or head.shape != embedding.shape or not arrays_equal(head, embedding):
        raise ValueError("Tied lm_head differs from embed_tokens; conversion cannot discard it")
    return {name: value for name, value in weights.items() if name != head_name}


def _runtime(runtime_root: Path) -> tuple[Any, Callable[..., Any], Callable[..., Any], int]:
    # Set before imports: upstream's tokenizer hook otherwise has a remote fallback.
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    sys.path.insert(0, str(runtime_root))
    import huggingface_hub.constants
    import mlx.core as mx
    import mlx_audio
    from mlx_audio.resample import _polyphase_filter, resample_audio_array
    from mlx_audio.stt import load as load_model

    huggingface_hub.constants.HF_HUB_OFFLINE = True
    if Path(mlx_audio.__file__).resolve().parent != runtime_root / "mlx_audio":
        raise RuntimeError("A different mlx_audio package was already imported")
    up, down, fir = _polyphase_filter(16000, SAMPLE_RATE)
    support = _ceil_div((len(fir) - 1) // 2 + down, up)
    halo_frames = _ceil_div(support, down) * down
    return mx, load_model, resample_audio_array, halo_frames


def load(args: Any, journal: Any) -> tuple[ModelState, dict[str, Any]]:
    model_path = Path(args.model_path).expanduser().resolve()
    runtime_root = Path(args.runtime_root).expanduser().resolve()
    config = _validate_model_path(model_path)
    weight_summary = _weight_summary(model_path)
    revision = subprocess.run(
        ["git", "-C", str(runtime_root), "rev-parse", "HEAD"],
        check=True, capture_output=True, text=True,
    ).stdout.strip()
    if revision != RUNTIME_REVISION:
        raise ValueError(f"Expected mlx-audio revision {RUNTIME_REVISION}, found {revision}")
    journal.record("vibevoice_load_start", model_path=str(model_path), runtime_revision=revision)
    mx, load_model, resample, halo = _runtime(runtime_root)
    mx.random.seed(args.seed)
    model = load_model(model_path, strict=True)
    if (
        not model.is_streaming_model or model.sample_rate != SAMPLE_RATE
        or model.streaming_chunk_samples != CHUNK_SAMPLES
        or model.streaming_window_samples != WINDOW_SAMPLES or model.normalize_audio
    ):
        raise ValueError("Loaded runtime does not match the pinned streaming geometry")
    versions = {}
    for package in ("mlx", "numpy", "scipy", "transformers", "huggingface-hub"):
        versions[package] = importlib.metadata.version(package)
    metadata = {
        "model_id": MODEL_ID, "source_model_revision": MODEL_REVISION,
        "model_path": str(model_path), "runtime_root": str(runtime_root),
        "runtime_revision": revision, "versions": versions,
        "native_streaming": True, "state_scope": "new KV cache per run",
        "emission_granularity": "completed native audio chunk",
        "sample_rate": SAMPLE_RATE, "chunk_samples": CHUNK_SAMPLES,
        "window_samples": WINDOW_SAMPLES, "chunk_ms": CHUNK_SAMPLES / 24,
        "lookahead_ms": (WINDOW_SAMPLES - CHUNK_SAMPLES) / 24,
        "first_window_audio_ms": WINDOW_SAMPLES / 24,
        "resampler_halo_input_frames": halo, "resampler_halo_ms": halo / 16,
        "requested_chunk_ms": getattr(args, "chunk_ms", None),
        "requested_latency_ms": getattr(args, "latency_ms", None),
        "requested_language": args.language, "language_prior": None,
        "quantization": config.get("quantization", config.get("quantization_config")),
        "quantized_components": ["language_model"],
        "nonquantized_dtype": "bfloat16",
        "weight_storage": weight_summary,
        "config_dtype_field": config.get("torch_dtype"),
        "per_chunk_token_limit": PER_CHUNK_TOKEN_LIMIT,
        "max_duration_seconds": MAX_DURATION_SECONDS,
        "word_timestamps": False, "speaker_timestamps": False,
        "native_step_finish_reason_available": False,
        "raw_output_scope": "decoded native step text; upstream removes special tokens",
    }
    journal.record("vibevoice_load_complete", metadata=metadata)
    return ModelState(model, mx, resample, halo, metadata), metadata


def _audio_window(state: ModelState, samples: Any, window: Window, source_rate: int) -> Any:
    # Only this released slice is used, including the FIR support declared to pace_to.
    chunk = samples[window.source_start_frame:window.source_end_frame]
    if source_rate != SAMPLE_RATE:
        chunk = state.resample(chunk, source_rate, SAMPLE_RATE, axis=0)
    start = window.local_output_start
    chunk = chunk[start:start + window.real_model_samples]
    if len(chunk) != window.real_model_samples:
        raise RuntimeError("Resampler returned insufficient samples for a streaming window")
    tensor = state.mx.array(chunk, dtype=state.mx.float32)[None, :]
    padding = WINDOW_SAMPLES - window.real_model_samples
    if padding:
        tensor = state.mx.pad(tensor, [(0, 0), (0, padding)])
    return tensor


def run(state: ModelState, audio: Any, session: Any, args: Any) -> dict[str, Any]:
    if audio.sample_rate != 16000:
        raise ValueError("The comparison fixture must be 16 kHz mono audio")
    if audio.frames <= 0 or audio.frames > MAX_DURATION_SECONDS * audio.sample_rate:
        raise ValueError("VibeVoice streaming supports nonempty audio up to eight minutes")
    max_tokens = int(getattr(args, "max_tokens", 4096))
    if max_tokens <= 0:
        raise ValueError("max_tokens must be positive")

    state.mx.random.seed(args.seed)
    parser = SpeakerParser()
    session.record("stream_state_init_start")
    stream = state.model.init_streaming_state()
    session.record("stream_state_init_end", prompt_tokens=stream.get("prompt_tokens"))
    samples = audio.as_float32()
    raw_chunks, reasons = [], []
    token_count = 0
    plan = list(windows(audio.frames, audio.sample_rate, state.resample_halo_frames))

    def publish(parsed: dict[str, Any], window: Window, raw: str) -> None:
        for event in parsed["new_speakers"]:
            session.record("speaker", **event, audio_end_frame=window.source_end_frame,
                           timing_semantics="event arrival; no acoustic speaker timestamp")
        if parsed["changed"] and parsed["text"].strip():
            session.emit_text(parsed["text"], semantics="cumulative",
                              audio_end_frame=window.source_end_frame, raw=raw,
                              chunk_index=window.index, consumed_end_frame=window.consumed_end_frame)
        for warning in parsed["warnings"]:
            reasons.append(warning)
            session.record("truncation", reason=warning, chunk_index=window.index)

    try:
        for window in plan:
            session.pace_to(window.source_end_frame)
            step_start = session.elapsed_ms()
            session.record("stream_step_start", chunk_index=window.index,
                           audio_end_frame=window.source_end_frame,
                           model_window_audio_end_frame=min(audio.frames, _ceil_div(
                               (window.model_start_sample + window.real_model_samples) * audio.sample_rate,
                               SAMPLE_RATE)),
                           model_start_sample=window.model_start_sample,
                           real_model_samples=window.real_model_samples,
                           zero_padding_samples=WINDOW_SAMPLES - window.real_model_samples,
                           eof_flush=window.source_end_frame == audio.frames)
            tensor = _audio_window(state, samples, window, audio.sample_rate)
            features = state.model.encode_speech(tensor, verbose=False)
            encode_end = session.elapsed_ms()
            before = int(stream["generation_tokens"])
            limit = min(PER_CHUNK_TOKEN_LIMIT, max_tokens - token_count)
            raw, stream = state.model.streaming_generate_step(
                features, stream, max_new_tokens=limit, temperature=0.0,
            )
            if not isinstance(raw, str):
                raise TypeError("Native streaming step must return decoded text")
            generated = int(stream["generation_tokens"]) - before
            if not 0 <= generated <= limit:
                raise RuntimeError("Native streaming token count violated its per-step budget")
            token_count += generated
            raw_chunks.append(raw)
            publish(parser.feed(raw), window, raw)
            session.record("stream_step_end", chunk_index=window.index, raw=raw,
                           generated_tokens=generated, total_generated_tokens=token_count,
                           encoding_ms=encode_end - step_start,
                           decoding_ms=session.elapsed_ms() - encode_end)
            del tensor, features
            state.mx.clear_cache()
            if generated == limit:
                reason = "total_token_limit_reached" if token_count >= max_tokens else "per_chunk_token_limit_reached"
                reasons.append(reason)
                session.record("truncation", reason=reason, chunk_index=window.index,
                               finish_reason_available=False)
                break
        publish(parser.feed("", final=True), plan[len(raw_chunks) - 1], "")
        session.record("stream_end", completed=not reasons, processed_chunks=len(raw_chunks),
                       expected_chunks=len(plan), generation_tokens=token_count)
        return {
            "text": parser.text.strip(), "raw_text": "".join(raw_chunks),
            "raw_chunks": raw_chunks, "speaker_events": parser.events,
            "generation_tokens": token_count, "processed_chunks": len(raw_chunks),
            "expected_chunks": len(plan), "truncated": bool(reasons),
            "truncation_reasons": reasons, "completed": not reasons,
            "native_step_finish_reason_available": False,
        }
    finally:
        # The resident model is retained; all conversation/KV references die here.
        stream.clear()
        state.mx.clear_cache()


def close(state: ModelState) -> None:
    state.model = None
    state.mx.clear_cache()
