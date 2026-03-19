"""
InsightKit 本地转写引擎（faster-whisper + silero-vad + pyannote）。

默认严格本地模式：
- 必须使用本地 ASR 模型目录（不允许静默网络下载回退）
- 无法加载 ASR/VAD 时直接报错
- 说话人分离为可降级能力（无 HF token 时仅关闭分离，不阻塞 ASR）
"""

from __future__ import annotations

import logging
import math
import os
import subprocess
import tempfile
import threading
import time
import wave
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

LID_SAMPLE_SECONDS = 45

# 运行时配置（可由环境变量覆盖）
ASR_ENGINE = os.getenv("INSIGHTKIT_ASR_ENGINE", "whisper").strip().lower() or "whisper"
DEFAULT_MODEL_NAME = os.getenv("INSIGHTKIT_ASR_MODEL", "large-v3").strip() or "large-v3"
MODEL_DIR = Path(
    os.getenv(
        "INSIGHTKIT_MODEL_DIR",
        str(Path.home() / "Library" / "Application Support" / "InsightKit" / "models"),
    )
).expanduser()
WHISPER_MODEL_DIR = MODEL_DIR / "faster-whisper" / DEFAULT_MODEL_NAME
FUNASR_MODEL_DIR = MODEL_DIR / "funasr"
STRICT_LOCAL_ONLY = os.getenv("INSIGHTKIT_ASR_STRICT_LOCAL_ONLY", "1").strip() != "0"
VAD_ENABLED = os.getenv("INSIGHTKIT_VAD_ENABLED", "1").strip() != "0"
DIARIZATION_ENABLED = os.getenv("INSIGHTKIT_DIARIZATION_ENABLED", "1").strip() != "0"
HF_TOKEN = (
    os.getenv("HF_TOKEN", "").strip()
    or os.getenv("HUGGINGFACE_TOKEN", "").strip()
    or os.getenv("HUGGING_FACE_HUB_TOKEN", "").strip()
)
ASR_DEVICE = os.getenv("INSIGHTKIT_ASR_DEVICE", "auto").strip() or "auto"
ASR_COMPUTE_TYPE = os.getenv("INSIGHTKIT_ASR_COMPUTE_TYPE", "int8").strip() or "int8"
FUNASR_ASR_MODEL = (
    os.getenv("INSIGHTKIT_FUNASR_ASR_MODEL", "").strip()
    or "iic/speech_paraformer-large-vad-punc_asr_nat-zh-cn-16k-common-vocab8404-pytorch"
)
FUNASR_VAD_MODEL = os.getenv("INSIGHTKIT_FUNASR_VAD_MODEL", "iic/speech_fsmn_vad_zh-cn-16k-common-pytorch").strip()
FUNASR_PUNC_MODEL = os.getenv("INSIGHTKIT_FUNASR_PUNC_MODEL", "iic/punc_ct-transformer_zh-cn-common-vocab272727-pytorch").strip()
FUNASR_SPK_MODEL = os.getenv("INSIGHTKIT_FUNASR_SPK_MODEL", "iic/speech_campplus_sv_zh-cn_16k-common").strip()

_models: dict[str, Any] = {}
_model_registry_lock = threading.Lock()
_models_lock = _model_registry_lock
_runtime_state_lock = threading.Lock()
_runtime_backend_snapshot: dict[str, Any] | None = None
_runtime_warm_snapshot: dict[str, Any] | None = None
_prewarm_thread: threading.Thread | None = None
_prewarm_timer: threading.Timer | None = None
_prewarm_generation = 0
_prewarm_key: tuple[str, str] | None = None


def _supported_compute_types(device: str) -> list[str]:
    try:
        import ctranslate2

        supported = ctranslate2.get_supported_compute_types(device)
        if isinstance(supported, (set, list, tuple)):
            return sorted(str(x) for x in supported)
        if supported:
            return [str(supported)]
    except Exception:
        pass
    return []


def _configured_backend_status(engine_name: str | None = None) -> dict[str, Any]:
    selected_engine = "funasr" if (engine_name or _engine()) == "funasr" else "whisper"
    if selected_engine == "funasr":
        return {
            "device": "auto",
            "compute_type": "float32",
            "configured_device": "auto",
            "configured_compute_type": "float32",
            "resolved": "",
            "supported_compute_types": ["float16", "float32"],
        }

    return {
        "device": ASR_DEVICE,
        "compute_type": ASR_COMPUTE_TYPE,
        "configured_device": ASR_DEVICE,
        "configured_compute_type": ASR_COMPUTE_TYPE,
        "resolved": "",
        "supported_compute_types": _supported_compute_types(ASR_DEVICE),
    }


def _resolved_funasr_device() -> str:
    resolved = "cpu"
    try:
        import torch

        if bool(getattr(torch.cuda, "is_available", lambda: False)()):
            resolved = "cuda"
        elif bool(getattr(getattr(torch.backends, "mps", None), "is_available", lambda: False)()):
            resolved = "mps"
    except Exception:
        pass
    return resolved


def _resolved_backend_status(engine_name: str | None = None) -> dict[str, Any]:
    backend = _configured_backend_status(engine_name)
    selected_engine = "funasr" if (engine_name or _engine()) == "funasr" else "whisper"
    backend["resolved"] = _resolved_funasr_device() if selected_engine == "funasr" else ("cpu" if ASR_DEVICE == "auto" else ASR_DEVICE)
    return backend


def _default_backend_status() -> dict[str, Any]:
    return _configured_backend_status()


def _default_warm_status() -> dict[str, Any]:
    return {
        "ready": False,
        "state": "idle",
        "in_progress": False,
        "attempt": 0,
        "last_warm_ms": 0,
        "last_error": "",
        "watchdog_sec": 0,
        "_generation": 0,
        "_started_at": 0.0,
    }


def _sanitize_warm_state(state: dict[str, Any]) -> dict[str, Any]:
    return {
        "ready": bool(state.get("ready", False)),
        "state": str(state.get("state", "idle") or "idle"),
        "in_progress": bool(state.get("in_progress", False)),
        "attempt": int(state.get("attempt", 0) or 0),
        "last_warm_ms": int(state.get("last_warm_ms", 0) or 0),
        "last_error": str(state.get("last_error", "") or ""),
        "watchdog_sec": int(state.get("watchdog_sec", 0) or 0),
    }


def _runtime_warm_state_locked() -> dict[str, Any]:
    global _runtime_warm_snapshot
    if not isinstance(_runtime_warm_snapshot, dict):
        _runtime_warm_snapshot = _default_warm_status()
    return _runtime_warm_snapshot


def _runtime_backend_state_locked() -> dict[str, Any]:
    global _runtime_backend_snapshot
    if not isinstance(_runtime_backend_snapshot, dict):
        _runtime_backend_snapshot = _default_backend_status()
    return _runtime_backend_snapshot


def _set_backend_status(backend: dict[str, Any]) -> None:
    with _runtime_state_lock:
        snapshot = _configured_backend_status()
        snapshot.update(dict(backend))
        if not snapshot.get("configured_device"):
            snapshot["configured_device"] = snapshot.get("device", "")
        if not snapshot.get("configured_compute_type"):
            snapshot["configured_compute_type"] = snapshot.get("compute_type", "")
        global _runtime_backend_snapshot
        _runtime_backend_snapshot = snapshot


def _set_warm_state(**updates: Any) -> dict[str, Any]:
    with _runtime_state_lock:
        state = dict(_runtime_warm_state_locked())
        state.update(updates)
        global _runtime_warm_snapshot
        _runtime_warm_snapshot = state
        return dict(state)


def _finalize_warm_success(generation: int, warm_ms: int) -> None:
    with _runtime_state_lock:
        state = dict(_runtime_warm_state_locked())
        if int(state.get("_generation", 0) or 0) != generation:
            return
        state.update(
            {
                "ready": True,
                "state": "ready",
                "in_progress": False,
                "last_warm_ms": max(0, int(warm_ms)),
                "last_error": "",
                "_started_at": 0.0,
            }
        )
        global _runtime_warm_snapshot, _prewarm_thread, _prewarm_timer, _prewarm_key
        _runtime_warm_snapshot = state
        if _prewarm_timer is not None:
            _prewarm_timer.cancel()
            _prewarm_timer = None
        _prewarm_thread = None
        _prewarm_key = None


def _finalize_warm_failure(generation: int, error: str) -> None:
    with _runtime_state_lock:
        state = dict(_runtime_warm_state_locked())
        if int(state.get("_generation", 0) or 0) != generation:
            return
        state.update(
            {
                "ready": False,
                "state": "failed",
                "in_progress": False,
                "last_error": str(error or "warm failed"),
                "_generation": generation + 1,
                "_started_at": 0.0,
            }
        )
        global _runtime_warm_snapshot, _prewarm_thread, _prewarm_timer, _prewarm_key
        _runtime_warm_snapshot = state
        if _prewarm_timer is not None:
            _prewarm_timer.cancel()
            _prewarm_timer = None
        _prewarm_thread = None
        _prewarm_key = None


def _discard_engine_cache(engine_name: str) -> None:
    key = "funasr" if engine_name == "funasr" else "whisper"
    with _model_registry_lock:
        _models.pop(key, None)


def _prewarm_watchdog_expired(generation: int, timeout_sec: int) -> None:
    _finalize_warm_failure(generation, f"prewarm timed out after {timeout_sec}s")


def _warm_generation_is_active(generation: int) -> bool:
    with _runtime_state_lock:
        state = _runtime_warm_state_locked()
        return int(state.get("_generation", 0) or 0) == generation and bool(state.get("in_progress", False))


def runtime_backend_status(engine: str | None = None) -> dict[str, Any]:
    with _runtime_state_lock:
        if isinstance(_runtime_backend_snapshot, dict):
            return dict(_runtime_backend_snapshot)
    return _configured_backend_status(engine)


def runtime_warm_status() -> dict[str, Any]:
    with _runtime_state_lock:
        state = dict(_runtime_warm_state_locked())
    return _sanitize_warm_state(state)


def _mark_warm_ready(warm_ms: int | None = None) -> None:
    current = runtime_warm_status()
    _set_warm_state(
        ready=True,
        state="ready",
        in_progress=False,
        last_warm_ms=max(0, int(warm_ms if warm_ms is not None else current.get("last_warm_ms", 0))),
        last_error="",
    )


def _reset_runtime_state_for_tests() -> None:
    global _runtime_backend_snapshot, _runtime_warm_snapshot, _prewarm_thread, _prewarm_timer, _prewarm_generation, _prewarm_key
    with _runtime_state_lock:
        if _prewarm_timer is not None:
            _prewarm_timer.cancel()
        _prewarm_generation += 1
        _runtime_backend_snapshot = None
        _runtime_warm_snapshot = _default_warm_status()
        _prewarm_thread = None
        _prewarm_timer = None
        _prewarm_key = None
    with _model_registry_lock:
        _models.clear()

def _write_silence_wav(duration_sec: float = 0.25, sample_rate: int = 16_000) -> Path:
    path = Path(tempfile.mktemp(suffix="_warmup.wav"))
    frame_count = max(1, int(duration_sec * sample_rate))
    silence = b"\x00\x00" * frame_count
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        wf.writeframes(silence)
    return path


def _engine() -> str:
    return "funasr" if ASR_ENGINE == "funasr" else "whisper"


def _active_model_name(engine_name: str) -> str:
    if engine_name == "funasr":
        return FUNASR_ASR_MODEL
    return DEFAULT_MODEL_NAME


def _local_funasr_paths() -> dict[str, Path]:
    return {
        "asr": FUNASR_MODEL_DIR / "asr",
        "vad": FUNASR_MODEL_DIR / "vad",
        "punc": FUNASR_MODEL_DIR / "punc",
        "spk": FUNASR_MODEL_DIR / "spk",
    }


def _get_audio_duration(audio_path: str) -> float:
    """使用 ffprobe 获取音频时长（秒）。"""
    try:
        result = subprocess.run(
            [
                "ffprobe",
                "-v",
                "quiet",
                "-show_entries",
                "format=duration",
                "-of",
                "csv=p=0",
                audio_path,
            ],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        return float(result.stdout.strip())
    except Exception as exc:
        logger.warning("无法获取音频时长: %s", exc)
        return 0.0


def extract_audio(input_path: Path, output_path: Path | None = None) -> Path:
    """从输入音视频文件提取 16kHz 单声道 WAV 音频。"""
    if output_path is None:
        output_path = Path(tempfile.mktemp(suffix=".wav"))

    cmd = [
        "ffmpeg",
        "-y",
        "-i",
        str(input_path),
        "-vn",
        "-acodec",
        "pcm_s16le",
        "-ar",
        "16000",
        "-ac",
        "1",
        str(output_path),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=900, check=False)
    if result.returncode != 0:
        raise RuntimeError(f"ffmpeg 失败: {result.stderr[-500:]}")
    return output_path


def _load_model(key: str):
    """
    兼容旧调用方（scripts/main.py 仍会调用 _load_model("asr")）。
    """
    if key != "asr":
        raise ValueError(f"未知模型 key: {key}")
    return _CompatASRModel()


def _resolve_model_source() -> str:
    explicit_path = os.getenv("INSIGHTKIT_ASR_MODEL_PATH", "").strip()
    if explicit_path:
        path = Path(explicit_path).expanduser()
        if path.exists():
            return str(path)
        raise RuntimeError(f"指定的 ASR 模型路径不存在: {path}")

    local_path = WHISPER_MODEL_DIR
    if local_path.exists():
        return str(local_path)

    if STRICT_LOCAL_ONLY:
        raise RuntimeError(
            "本地 ASR 模型未就绪。请先执行 asr.runtime.bootstrap（期望目录: "
            f"{local_path}）。"
        )

    # 非严格模式下允许 faster-whisper 自行下载模型
    return DEFAULT_MODEL_NAME


def _load_whisper_model():
    with _model_registry_lock:
        cached = _models.get("whisper")
    if cached is not None:
        return cached

    try:
        from faster_whisper import WhisperModel
    except Exception as exc:
        raise RuntimeError(
            "未安装 faster-whisper。请先执行 asr.runtime.bootstrap。"
        ) from exc

    model_source = _resolve_model_source()
    logger.info(
        "加载 faster-whisper 模型: source=%s device=%s compute=%s",
        model_source,
        ASR_DEVICE,
        ASR_COMPUTE_TYPE,
    )
    model = WhisperModel(
        model_size_or_path=model_source,
        device=ASR_DEVICE,
        compute_type=ASR_COMPUTE_TYPE,
        download_root=str(MODEL_DIR / "faster-whisper"),
        local_files_only=STRICT_LOCAL_ONLY,
    )
    resolved = str(getattr(model, "device", ASR_DEVICE) or ASR_DEVICE).lower()
    backend = _resolved_backend_status("whisper")
    backend["resolved"] = resolved
    _set_backend_status(backend)

    with _model_registry_lock:
        cached = _models.get("whisper")
        if cached is None:
            _models["whisper"] = model
            return model
        return cached


def _load_silero_model():
    with _model_registry_lock:
        cached = _models.get("silero_vad")
    if cached is not None:
        return cached

    try:
        from silero_vad import load_silero_vad
    except Exception as exc:
        raise RuntimeError(
            "未安装 silero-vad。请先执行 asr.runtime.bootstrap。"
        ) from exc

    model = load_silero_vad()
    with _model_registry_lock:
        cached = _models.get("silero_vad")
        if cached is None:
            _models["silero_vad"] = model
            return model
        return cached


def _resolve_funasr_source(local_path: Path, remote_id: str) -> str:
    if local_path.exists():
        return str(local_path)
    if STRICT_LOCAL_ONLY:
        raise RuntimeError(
            "本地 FunASR 模型未就绪。请先执行 asr.runtime.bootstrap（期望目录: "
            f"{local_path}）。"
        )
    return remote_id


def _load_funasr_model():
    with _model_registry_lock:
        cached = _models.get("funasr")
    if cached is not None:
        return cached

    try:
        from funasr import AutoModel
    except Exception as exc:
        raise RuntimeError("未安装 FunASR。请先执行 asr.runtime.bootstrap。") from exc

    paths = _local_funasr_paths()
    model = AutoModel(
        model=_resolve_funasr_source(paths["asr"], FUNASR_ASR_MODEL),
        vad_model=_resolve_funasr_source(paths["vad"], FUNASR_VAD_MODEL) if VAD_ENABLED else None,
        punc_model=_resolve_funasr_source(paths["punc"], FUNASR_PUNC_MODEL),
        spk_model=_resolve_funasr_source(paths["spk"], FUNASR_SPK_MODEL) if DIARIZATION_ENABLED else None,
        disable_update=True,
        trust_remote_code=True,
    )
    _set_backend_status(_resolved_backend_status("funasr"))

    with _model_registry_lock:
        cached = _models.get("funasr")
        if cached is None:
            _models["funasr"] = model
            return model
        return cached


def _speech_exists(audio_path: Path) -> bool:
    if not VAD_ENABLED:
        return True
    try:
        from silero_vad import get_speech_timestamps, read_audio
    except Exception as exc:
        raise RuntimeError("silero-vad 运行失败，请检查安装。") from exc

    vad_model = _load_silero_model()
    waveform = read_audio(str(audio_path), sampling_rate=16000)
    speech = get_speech_timestamps(
        waveform,
        vad_model,
        sampling_rate=16000,
        threshold=0.3,
        min_speech_duration_ms=100,
    )
    return len(speech) > 0


def _extract_audio_clip(audio_path: Path, max_seconds: int = LID_SAMPLE_SECONDS) -> Path:
    """提取前 N 秒音频用于快速语言检测。"""
    duration = _get_audio_duration(str(audio_path))
    if duration <= max_seconds:
        return audio_path

    clip_path = Path(tempfile.mktemp(suffix="_lid_clip.wav"))
    cmd = [
        "ffmpeg",
        "-y",
        "-i",
        str(audio_path),
        "-t",
        str(max_seconds),
        "-acodec",
        "pcm_s16le",
        "-ar",
        "16000",
        "-ac",
        "1",
        str(clip_path),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=120, check=False)
    if result.returncode != 0:
        logger.warning("截取语言检测片段失败，回退完整音频: %s", result.stderr[-200:])
        return audio_path
    return clip_path


def _load_diarization_pipeline():
    if not DIARIZATION_ENABLED:
        return None
    if not HF_TOKEN:
        return None

    with _model_registry_lock:
        cached = _models.get("pyannote_pipeline")
    if cached is not None:
        return cached

    try:
        from pyannote.audio import Pipeline
    except Exception:
        return None

    try:
        pipeline = Pipeline.from_pretrained(
            "pyannote/speaker-diarization-3.1",
            use_auth_token=HF_TOKEN,
        )
        with _model_registry_lock:
            cached = _models.get("pyannote_pipeline")
            if cached is None:
                _models["pyannote_pipeline"] = pipeline
                return pipeline
            return cached
    except Exception as exc:
        logger.warning("pyannote 初始化失败，将禁用分离: %s", exc)
        return None


def _diarize(audio_path: Path) -> list[tuple[int, int, str]]:
    pipeline = _load_diarization_pipeline()
    if pipeline is None:
        return []

    try:
        diarization = pipeline(str(audio_path))
    except Exception as exc:
        logger.warning("pyannote 说话人分离失败，继续无 speaker 转写: %s", exc)
        return []

    spans: list[tuple[int, int, str]] = []
    for turn, _, speaker in diarization.itertracks(yield_label=True):
        start_ms = max(0, int(round(float(turn.start) * 1000)))
        end_ms = max(start_ms + 1, int(round(float(turn.end) * 1000)))
        spans.append((start_ms, end_ms, str(speaker)))
    return spans


def _pick_speaker(start_ms: int, end_ms: int, spans: list[tuple[int, int, str]]) -> str:
    best_speaker = ""
    best_overlap = 0
    for s0, s1, speaker in spans:
        overlap = max(0, min(end_ms, s1) - max(start_ms, s0))
        if overlap > best_overlap:
            best_overlap = overlap
            best_speaker = speaker
    return best_speaker


def _confidence_from_logprob(avg_logprob: float | None) -> float:
    if avg_logprob is None:
        return 0.0
    try:
        value = math.exp(float(avg_logprob))
        return max(0.0, min(1.0, value))
    except Exception:
        return 0.0


def _transcribe_whisper(audio_path: Path) -> tuple[str, list[dict[str, Any]]]:
    if not _speech_exists(audio_path):
        return "unknown", []

    model = _load_whisper_model()
    segments_iter, info = model.transcribe(
        str(audio_path),
        language=None,
        vad_filter=False,
        beam_size=1,
        best_of=1,
        condition_on_previous_text=True,
        word_timestamps=False,
    )

    speaker_spans = _diarize(audio_path)
    segments: list[dict[str, Any]] = []

    for seg in segments_iter:
        text = str(getattr(seg, "text", "") or "").strip()
        if not text:
            continue
        start_ms = max(0, int(round(float(getattr(seg, "start", 0.0)) * 1000)))
        end_ms = max(start_ms + 200, int(round(float(getattr(seg, "end", 0.0)) * 1000)))
        speaker = _pick_speaker(start_ms, end_ms, speaker_spans)
        segments.append(
            {
                "start": start_ms,
                "end": end_ms,
                "text": text,
                "speaker": speaker,
                "confidence": _confidence_from_logprob(getattr(seg, "avg_logprob", None)),
            }
        )

    language = str(getattr(info, "language", "") or "unknown")
    _mark_warm_ready()
    if language.startswith("zh"):
        language = "zh"
    elif language.startswith("en"):
        language = "en"
    elif not language:
        language = "unknown"
    return language, segments


def _transcribe_funasr(audio_path: Path) -> tuple[str, list[dict[str, Any]]]:
    model = _load_funasr_model()
    result = model.generate(input=str(audio_path))
    parsed = _parse_funasr_result(result)
    segments: list[dict[str, Any]] = []
    for seg in parsed:
        text = str(seg.get("text", "") or "").strip()
        if not text:
            continue
        start_ms = int(seg.get("start", 0) or 0)
        end_ms = int(seg.get("end", 0) or 0)
        if end_ms <= start_ms:
            end_ms = start_ms + 1200
        speaker = str(seg.get("speaker", "") or "")
        segments.append(
            {
                "start": start_ms,
                "end": end_ms,
                "text": text,
                "speaker": speaker,
                "confidence": float(seg.get("confidence", 0.0) or 0.0),
            }
        )
    _mark_warm_ready()
    return "zh", segments


def _transcribe_active(audio_path: Path) -> tuple[str, list[dict[str, Any]]]:
    if _engine() == "funasr":
        return _transcribe_funasr(audio_path)
    return _transcribe_whisper(audio_path)


def _warmup_once(engine_name: str) -> None:
    wav_path: Path | None = None
    try:
        wav_path = _write_silence_wav()
        if engine_name == "funasr":
            model = _load_funasr_model()
            _ = model.generate(input=str(wav_path))
        else:
            model = _load_whisper_model()
            segments_iter, _ = model.transcribe(
                str(wav_path),
                language="en",
                vad_filter=False,
                beam_size=1,
                best_of=1,
                condition_on_previous_text=False,
                word_timestamps=False,
            )
            # Consume at most one segment to force graph initialization.
            for _ in segments_iter:
                break
    finally:
        if wav_path and wav_path.exists():
            try:
                wav_path.unlink()
            except Exception:
                pass


def _warm_worker(engine_name: str, model_name: str, generation: int) -> None:
    started = time.perf_counter()
    try:
        logger.info("asr prewarm start: engine=%s model=%s generation=%s", engine_name, model_name, generation)
        _set_warm_state(state="loading")
        if engine_name == "funasr":
            _load_funasr_model()
        else:
            _load_whisper_model()
        if not _warm_generation_is_active(generation):
            _discard_engine_cache(engine_name)
            return
        _set_warm_state(state="warming")
        _warmup_once(engine_name)
        if not _warm_generation_is_active(generation):
            _discard_engine_cache(engine_name)
            return
        warm_ms = int((time.perf_counter() - started) * 1000)
        logger.info(
            "asr prewarm ready: engine=%s model=%s generation=%s warm_ms=%s backend_resolved=%s",
            engine_name,
            model_name,
            generation,
            warm_ms,
            runtime_backend_status().get("resolved", ""),
        )
        _finalize_warm_success(generation, warm_ms)
    except Exception as exc:
        logger.warning("asr prewarm failed: engine=%s model=%s generation=%s error=%s", engine_name, model_name, generation, exc)
        _discard_engine_cache(engine_name)
        _finalize_warm_failure(generation, str(exc))


def prewarm_asr(
    engine: str | None = None,
    model: str | None = None,
    timeout_sec: int = 20,
) -> dict[str, Any]:
    selected_engine = "funasr" if (engine or _engine()) == "funasr" else "whisper"
    selected_model = (model or _active_model_name(selected_engine)).strip() or _active_model_name(selected_engine)
    watchdog_sec = max(3, int(timeout_sec or 20))

    global _prewarm_generation, _prewarm_thread, _prewarm_timer, _prewarm_key, _runtime_warm_snapshot, _runtime_backend_snapshot
    with _runtime_state_lock:
        state = dict(_runtime_warm_state_locked())
        active_thread = _prewarm_thread
        active_key = _prewarm_key
        if (
            bool(state.get("in_progress", False))
            and active_thread is not None
            and active_thread.is_alive()
            and active_key == (selected_engine, selected_model)
        ):
            snapshot = _sanitize_warm_state(state)
            return {
                "ok": True,
                "engine": selected_engine,
                "model": selected_model,
                "state": snapshot["state"],
                "started": False,
                "in_progress": snapshot["in_progress"],
                "attempt": snapshot["attempt"],
                "watchdog_sec": snapshot["watchdog_sec"],
                "warm_ms": snapshot["last_warm_ms"],
                "backend": dict(_runtime_backend_state_locked()),
                "warm": snapshot,
                "error": snapshot["last_error"],
            }

        _prewarm_generation += 1
        generation = _prewarm_generation
        attempt = max(0, int(state.get("attempt", 0) or 0)) + 1
        next_state = dict(state)
        next_state.update(
            {
                "ready": False,
                "state": "loading",
                "in_progress": True,
                "attempt": attempt,
                "last_error": "",
                "watchdog_sec": watchdog_sec,
                "_generation": generation,
                "_started_at": time.perf_counter(),
            }
        )
        _runtime_warm_snapshot = next_state
        _runtime_backend_snapshot = _configured_backend_status(selected_engine)
        if _prewarm_timer is not None:
            _prewarm_timer.cancel()
        _prewarm_key = (selected_engine, selected_model)
        worker = threading.Thread(
            target=_warm_worker,
            args=(selected_engine, selected_model, generation),
            name=f"asr-prewarm-{selected_engine}",
            daemon=True,
        )
        timer = threading.Timer(watchdog_sec, _prewarm_watchdog_expired, args=(generation, watchdog_sec))
        timer.daemon = True
        _prewarm_thread = worker
        _prewarm_timer = timer

    timer.start()
    worker.start()
    snapshot = runtime_warm_status()
    logger.info(
        "asr prewarm accepted: engine=%s model=%s warm_state=%s warm_attempt=%s watchdog_sec=%s",
        selected_engine,
        selected_model,
        snapshot.get("state"),
        snapshot.get("attempt"),
        watchdog_sec,
    )
    return {
        "ok": True,
        "engine": selected_engine,
        "model": selected_model,
        "state": snapshot["state"],
        "started": True,
        "in_progress": snapshot["in_progress"],
        "attempt": snapshot["attempt"],
        "watchdog_sec": watchdog_sec,
        "warm_ms": snapshot["last_warm_ms"],
        "backend": runtime_backend_status(),
        "warm": snapshot,
        "error": snapshot["last_error"],
    }


def detect_language(audio_path: Path) -> str:
    """
    返回 'zh' / 'en' / 'unknown'。
    """
    clip_path = None
    try:
        clip_path = _extract_audio_clip(audio_path)
        lang, _ = _transcribe_active(clip_path)
        return lang
    except Exception as exc:
        logger.warning("语言检测失败，默认 unknown: %s", exc)
        return "unknown"
    finally:
        if clip_path and clip_path != audio_path and clip_path.exists():
            try:
                clip_path.unlink()
            except Exception:
                pass


def transcribe(input_path: Path) -> dict[str, Any]:
    """
    完整转录流程：提取音频 -> 本地 ASR -> 返回结构化片段。

    返回:
    {
      "lang": "zh|en|unknown",
      "duration": float,
      "segments": [{"start":int,"end":int,"text":str,"speaker":str,"confidence":float}, ...]
    }
    """
    audio_path = None
    try:
        audio_path = extract_audio(input_path)
        duration = _get_audio_duration(str(audio_path))
        lang, segments = _transcribe_active(audio_path)
        return {
            "lang": lang,
            "duration": duration,
            "segments": segments,
        }
    finally:
        if audio_path and audio_path.exists():
            try:
                audio_path.unlink()
            except Exception:
                pass


def transcribe_audio_chunk(wav_path: Path, offset_ms: int = 0) -> list[dict[str, Any]]:
    """
    对单个 WAV chunk 执行增量转写，并返回绝对时间戳片段。
    """
    if not wav_path.exists():
        raise FileNotFoundError(str(wav_path))
    if wav_path.suffix.lower() != ".wav":
        raise ValueError("live chunk must be wav")

    _, raw_segments = _transcribe_active(wav_path)

    out: list[dict[str, Any]] = []
    for seg in raw_segments:
        text = str(seg.get("text", "") or "").strip()
        if not text:
            continue

        start = int(seg.get("start", 0) or 0)
        end = int(seg.get("end", 0) or 0)
        if end <= start:
            end = start + 1200

        out.append(
            {
                "start_ms": start + int(offset_ms),
                "end_ms": end + int(offset_ms),
                "speaker": str(seg.get("speaker", "") or ""),
                "text": text,
                "confidence": float(seg.get("confidence", 0.0) or 0.0),
            }
        )
    return out


class _CompatASRModel:
    """兼容 scripts/main.py 中 `asr_model.generate(input=...)` 调用。"""

    def generate(self, input: str):  # noqa: A002
        path = Path(input).expanduser().resolve()
        _, segments = _transcribe_active(path)
        sentence_info = [
            {
                "start": seg["start"],
                "end": seg["end"],
                "text": seg["text"],
                "spk": seg["speaker"],
            }
            for seg in segments
        ]
        return [
            {
                "text": " ".join(seg["text"] for seg in segments),
                "sentence_info": sentence_info,
            }
        ]


def _parse_funasr_result(result) -> list[dict[str, Any]]:
    """
    兼容旧解析逻辑，同时支持 faster-whisper 兼容输出。
    """
    segments: list[dict[str, Any]] = []
    if not result:
        return segments

    for item in result:
        if isinstance(item, dict):
            # faster-whisper 兼容结构：直接有 start/end/text
            if {"start", "end", "text"}.issubset(item.keys()):
                segments.append(
                    {
                        "start": int(item.get("start", 0) or 0),
                        "end": int(item.get("end", 0) or 0),
                        "text": str(item.get("text", "") or ""),
                        "speaker": str(item.get("speaker", "") or ""),
                        "confidence": float(item.get("confidence", 0.0) or 0.0),
                    }
                )
                continue

            sentence_info = item.get("sentence_info", [])
            if sentence_info:
                for sent in sentence_info:
                    speaker = sent.get("spk", "")
                    if isinstance(speaker, int):
                        speaker = f"spk{speaker}"
                    segments.append(
                        {
                            "start": int(sent.get("start", 0) or 0),
                            "end": int(sent.get("end", 0) or 0),
                            "text": str(sent.get("text", "") or ""),
                            "speaker": str(speaker or ""),
                            "confidence": float(sent.get("confidence", 0.0) or 0.0),
                        }
                    )
                continue

            text = str(item.get("text", "") or "").strip()
            if text:
                segments.append({"start": 0, "end": 0, "text": text, "speaker": "", "confidence": 0.0})
        else:
            segments.append({"start": 0, "end": 0, "text": str(item), "speaker": "", "confidence": 0.0})

    return segments
