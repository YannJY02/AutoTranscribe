"""Shared ASR Runtime Profile rules for InsightKit.

This module owns the local runtime choices that must stay consistent across
bootstrap probes, transcription, and sidecar status reporting.
"""

from __future__ import annotations

import os
import shutil
from pathlib import Path
from typing import Any, Mapping

try:
    from .asr_model_catalog import QWEN_MLX_ENGINE
except ImportError:
    from asr_model_catalog import QWEN_MLX_ENGINE


APPLE_SPEECH_ENGINE = "apple-speech"
ASR_ENGINE_OPTIONS = ("whisper", "funasr", QWEN_MLX_ENGINE)
ASR_PEER_ENGINE_OPTIONS = (*ASR_ENGINE_OPTIONS, APPLE_SPEECH_ENGINE)
ASR_PROFILE_SCHEMA_VERSION = 1


def normalize_engine_name(engine_name: str | None, *, default_engine: str | None = None) -> str:
    raw = (engine_name or default_engine or "whisper").strip().lower()
    if raw in {QWEN_MLX_ENGINE, "qwenmlx", "qwen_mlx", "qwen"}:
        return QWEN_MLX_ENGINE
    if raw == "funasr":
        return "funasr"
    return "whisper"


def engine_options() -> list[str]:
    return list(ASR_ENGINE_OPTIONS)


def peer_engine_options() -> list[str]:
    return list(ASR_PEER_ENGINE_OPTIONS)


def normalize_diarization_engine(engine_name: str | None = None) -> str:
    raw = (engine_name or "fluid-lseend").strip().lower().replace("_", "-")
    if raw in {"fluid", "fluid-lseend", "fluid-audio", "fluidaudio", "ls-eend", "lseend"}:
        return "fluid-lseend"
    if raw in {"pyannote", "pyannote-community-1", "qwen-pyannote"}:
        return "pyannote"
    if raw in {"funasr", "campplus"}:
        return "funasr"
    if raw in {"auto", "best"}:
        return "auto"
    if raw in {"0", "off", "none", "disabled"}:
        return "none"
    return "fluid-lseend"


def hf_auth_token(env: Mapping[str, str] | None = None) -> str:
    source = env or os.environ
    token = (
        source.get("PYANNOTE_AUTH_TOKEN", "").strip()
        or source.get("HF_TOKEN", "").strip()
        or source.get("HUGGINGFACE_TOKEN", "").strip()
        or source.get("HUGGING_FACE_HUB_TOKEN", "").strip()
    )
    if token:
        return token
    try:
        from huggingface_hub import get_token

        return (get_token() or "").strip()
    except Exception:
        return ""


def resolve_fluid_audio_cli(
    *,
    model_dir: Path | str | None = None,
    configured_cli: Path | str | None = None,
) -> Path | None:
    candidates: list[Path] = []
    if configured_cli:
        candidates.append(Path(configured_cli).expanduser())

    found = shutil.which("fluidaudiocli")
    if found:
        candidates.append(Path(found))

    root = Path(model_dir).expanduser() if model_dir else _default_model_dir()
    app_support = Path.home() / "Library" / "Application Support"
    candidates.extend(
        [
            root.parent / "tools" / "FluidAudio" / ".build" / "release" / "fluidaudiocli",
            app_support / "InsightKit" / "tools" / "FluidAudio" / ".build" / "release" / "fluidaudiocli",
            app_support / "FluidAudio" / "FluidAudio" / ".build" / "release" / "fluidaudiocli",
            Path("/tmp/FluidAudio/.build/release/fluidaudiocli"),
        ]
    )

    seen: set[str] = set()
    for candidate in candidates:
        key = str(candidate)
        if key in seen:
            continue
        seen.add(key)
        if candidate.exists() and os.access(candidate, os.X_OK):
            return candidate
    return None


def speaker_diarization_status(
    optional: Mapping[str, bool],
    *,
    diarization_engine: str | None = None,
    funasr_spk_ready: bool = False,
    model_dir: Path | str | None = None,
    configured_cli: Path | str | None = None,
    hf_token_value: str | None = None,
) -> dict[str, Any]:
    engine = normalize_diarization_engine(diarization_engine)
    if engine in {"fluid-lseend", "auto"}:
        cli = resolve_fluid_audio_cli(model_dir=model_dir, configured_cli=configured_cli)
        ready = cli is not None
        return {
            "engine": "fluid-lseend",
            "enabled": True,
            "ready": ready,
            "degraded": not ready,
            "path": str(cli) if cli else "",
            "reason": "" if ready else "missing FluidAudio fluidaudiocli executable",
        }
    if engine == "funasr":
        return {
            "engine": "campplus",
            "enabled": True,
            "ready": funasr_spk_ready,
            "degraded": not funasr_spk_ready,
            "reason": "" if funasr_spk_ready else "missing local speaker model",
        }
    if engine == "none":
        return {
            "engine": "none",
            "enabled": False,
            "ready": False,
            "degraded": True,
            "reason": "diarization disabled",
        }

    token = hf_token_value if hf_token_value is not None else hf_auth_token()
    ready = optional.get("pyannote-audio", False) and optional.get("torch", False) and bool(token)
    return {
        "engine": "pyannote-community-1",
        "enabled": True,
        "ready": ready,
        "degraded": not ready,
        "reason": "" if ready else "missing pyannote diarize extra or HF/PYANNOTE token",
    }


def engine_status_snapshot(
    *,
    required: Mapping[str, bool],
    optional: Mapping[str, bool],
    model_name: str,
    model_path: Path | str,
    model_exists: bool,
    vad_engine: str,
    vad_ready: bool,
    timestamps: Mapping[str, Any] | None = None,
    diarization_engine: str | None = None,
    funasr_spk_ready: bool = False,
    model_dir: Path | str | None = None,
    configured_cli: Path | str | None = None,
) -> dict[str, Any]:
    status: dict[str, Any] = {
        "required": dict(required),
        "optional": dict(optional),
        "model": {
            "name": model_name,
            "path": str(model_path),
            "exists": bool(model_exists),
        },
        "vad": {
            "engine": vad_engine,
            "enabled": True,
            "ready": bool(vad_ready),
        },
        "speaker_diarization": speaker_diarization_status(
            optional,
            diarization_engine=diarization_engine,
            funasr_spk_ready=funasr_spk_ready,
            model_dir=model_dir,
            configured_cli=configured_cli,
        ),
        "ready": all(required.values()) and bool(model_exists),
    }
    if timestamps is not None:
        status["timestamps"] = dict(timestamps)
    return status


def apple_speech_engine_profile(env: Mapping[str, str] | None = None) -> dict[str, Any]:
    source = env or os.environ
    prototype_enabled = source.get("INSIGHTKIT_APPLE_SPEECH_PROTOTYPE_ENABLED", "").strip() == "1"
    limitations = [
        "Apple Speech is currently owned by the Swift final-media adapter, not the Python Sidecar runtime.",
        "Live Workspace realtime ASR is not wired to Apple Speech.",
        "Diarization parity has not been proven for Apple Speech.",
    ]
    if not prototype_enabled:
        limitations.insert(0, "The experimental Apple Speech final-media prototype is disabled.")

    return {
        "engine": APPLE_SPEECH_ENGINE,
        "display_name": "Apple Speech",
        "active": False,
        "configured": prototype_enabled,
        "selectable": False,
        "ready": False,
        "availability_state": "degraded" if prototype_enabled else "unavailable",
        "capabilities": {
            "live_asr": False,
            "final_media_asr": prototype_enabled,
            "diarization": False,
            "strict_local": True,
            "runtime_owner": "swift-final-media-adapter",
        },
        "limitations": limitations,
        "user_recovery_hint": (
            "Apple Speech 目前只能作为音频最终媒体的实验转写原型；实时转写仍需使用已配置的本地 ASR Engine。"
            if prototype_enabled
            else "如需试用 Apple Speech，请先在设置中启用实验性音频最终媒体转写；实时转写仍需使用已配置的本地 ASR Engine。"
        ),
    }


def attach_asr_runtime_profile(
    status: Mapping[str, Any],
    *,
    backend: Mapping[str, Any] | None = None,
    warm: Mapping[str, Any] | None = None,
    configured_engine: str | None = None,
    env: Mapping[str, str] | None = None,
) -> dict[str, Any]:
    """Attach the shared ASR Runtime Profile while preserving legacy status fields."""
    merged = dict(status)
    backend_snapshot = dict(backend or merged.get("backend") or {})
    warm_snapshot = _sanitize_warm_status(warm or merged.get("warm") or {})
    merged["backend"] = backend_snapshot
    merged["warm"] = warm_snapshot
    merged["profile"] = asr_runtime_profile_snapshot(
        merged,
        backend=backend_snapshot,
        warm=warm_snapshot,
        configured_engine=configured_engine,
        env=env,
    )
    return merged


def asr_runtime_profile_snapshot(
    status: Mapping[str, Any],
    *,
    backend: Mapping[str, Any] | None = None,
    warm: Mapping[str, Any] | None = None,
    configured_engine: str | None = None,
    env: Mapping[str, str] | None = None,
) -> dict[str, Any]:
    active_engine = normalize_engine_name(str(status.get("engine", "") or ""))
    configured = normalize_engine_name(configured_engine or str(status.get("engine", "") or active_engine))
    backend_snapshot = dict(backend or status.get("backend") or {})
    warm_snapshot = _sanitize_warm_status(warm or status.get("warm") or {})
    ready_by_engine = {
        engine: bool((status.get("ready_by_engine") or {}).get(engine, False))
        for engine in ASR_ENGINE_OPTIONS
    }
    if active_engine in ready_by_engine:
        ready_by_engine[active_engine] = bool(status.get("ready", ready_by_engine[active_engine]))

    active_ready = bool(status.get("ready", False))
    warm_ready = bool(warm_snapshot.get("ready", False))
    warm_in_progress = bool(warm_snapshot.get("in_progress", False))
    warm_state = str(warm_snapshot.get("state", "") or "")
    diarization = dict(status.get("speaker_diarization") or {})
    diarization_degraded = bool(diarization.get("enabled", False)) and bool(diarization.get("degraded", False))
    live_ready = active_ready and warm_ready
    final_media_ready = active_ready
    technical_status = _technical_status(
        runtime_ready=active_ready,
        warm_ready=warm_ready,
        warm_in_progress=warm_in_progress,
        warm_state=warm_state,
        diarization_degraded=diarization_degraded,
    )
    degradation_reason = _degradation_reason(
        runtime_ready=active_ready,
        warm_ready=warm_ready,
        warm_in_progress=warm_in_progress,
        diarization=diarization,
        status=status,
    )
    engine_profiles = {
        engine: _python_engine_profile(
            engine=engine,
            active_engine=active_engine,
            configured_engine=configured,
            ready=ready_by_engine[engine],
            status=status,
        )
        for engine in ASR_ENGINE_OPTIONS
    }
    engine_profiles[APPLE_SPEECH_ENGINE] = apple_speech_engine_profile(env=env)

    return {
        "schema_version": ASR_PROFILE_SCHEMA_VERSION,
        "configured_engine": configured,
        "active_engine": active_engine,
        "engine_options": engine_options(),
        "peer_engine_options": peer_engine_options(),
        "engine_profiles": engine_profiles,
        "live_asr": {
            "ready": live_ready,
            "requires_warm_runtime": True,
            "reason": "" if live_ready else degradation_reason,
        },
        "final_media_asr": {
            "ready": final_media_ready,
            "requires_warm_runtime": False,
            "reason": "" if final_media_ready else degradation_reason,
        },
        "warm": warm_snapshot,
        "backend": backend_snapshot,
        "diarization": diarization,
        "technical_status": technical_status,
        "degradation": {
            "active": technical_status in {"warming", "degraded", "unavailable"},
            "reason": "" if technical_status == "ready" else degradation_reason,
        },
        "user_recovery_hint": _user_recovery_hint(technical_status, degradation_reason),
    }


def _sanitize_warm_status(warm: Mapping[str, Any] | None) -> dict[str, Any]:
    source = warm or {}
    return {
        "ready": bool(source.get("ready", False)),
        "state": str(source.get("state", "idle") or "idle"),
        "in_progress": bool(source.get("in_progress", False)),
        "attempt": int(source.get("attempt", 0) or 0),
        "last_warm_ms": int(source.get("last_warm_ms", 0) or 0),
        "last_error": str(source.get("last_error", "") or ""),
        "watchdog_sec": int(source.get("watchdog_sec", 0) or 0),
    }


def _python_engine_profile(
    *,
    engine: str,
    active_engine: str,
    configured_engine: str,
    ready: bool,
    status: Mapping[str, Any],
) -> dict[str, Any]:
    active = engine == active_engine
    model = dict(status.get("model") or {}) if active else {}
    if not active:
        model_name = ""
    else:
        model_name = str(model.get("name", "") or "")
    return {
        "engine": engine,
        "display_name": _engine_display_name(engine),
        "active": active,
        "configured": engine == configured_engine,
        "selectable": True,
        "ready": bool(ready),
        "availability_state": "available" if ready else "unavailable",
        "model": model,
        "capabilities": {
            "live_asr": bool(ready),
            "final_media_asr": bool(ready),
            "diarization": bool(active and (status.get("speaker_diarization") or {}).get("ready", False)),
            "strict_local": True,
            "runtime_owner": "python-sidecar",
        },
        "limitations": [] if ready else [f"{_engine_display_name(engine)} local runtime is not ready."],
        "user_recovery_hint": (
            ""
            if ready
            else f"请在设置中修复 {_engine_display_name(engine)} 语音识别模型和依赖。"
        ),
        "model_name": model_name,
    }


def _engine_display_name(engine: str) -> str:
    if engine == QWEN_MLX_ENGINE:
        return "Qwen MLX"
    if engine == "funasr":
        return "FunASR"
    return "Whisper"


def _technical_status(
    *,
    runtime_ready: bool,
    warm_ready: bool,
    warm_in_progress: bool,
    warm_state: str,
    diarization_degraded: bool,
) -> str:
    _ = warm_ready
    if not runtime_ready:
        return "unavailable"
    if warm_in_progress:
        return "warming"
    if warm_state == "failed":
        return "degraded"
    if diarization_degraded:
        return "degraded"
    return "ready"


def _degradation_reason(
    *,
    runtime_ready: bool,
    warm_ready: bool,
    warm_in_progress: bool,
    diarization: Mapping[str, Any],
    status: Mapping[str, Any],
) -> str:
    if not runtime_ready:
        missing = _missing_runtime_reason(status)
        return missing or "ASR runtime is not ready."
    if warm_in_progress:
        return "ASR Runtime Warmup is still in progress."
    if not warm_ready:
        return "ASR Runtime Warmup has not completed for live transcription."
    if bool(diarization.get("enabled", False)) and bool(diarization.get("degraded", False)):
        reason = str(diarization.get("reason", "") or "").strip()
        return reason or "Diarization is degraded."
    return ""


def _missing_runtime_reason(status: Mapping[str, Any]) -> str:
    model = status.get("model") or {}
    if isinstance(model, Mapping) and not bool(model.get("exists", False)):
        name = str(model.get("name", "") or "").strip()
        return f"missing local ASR model: {name}" if name else "missing local ASR model"
    required = ((status.get("dependencies") or {}).get("required") or {})
    if isinstance(required, Mapping):
        missing = [name for name, ready in required.items() if not ready]
        if missing:
            return "missing required ASR dependencies: " + ", ".join(sorted(map(str, missing)))
    return ""


def _user_recovery_hint(technical_status: str, reason: str) -> str:
    if technical_status == "ready":
        return ""
    if technical_status == "warming":
        return "本地语音识别正在预热；请稍等，或在设置中重新运行语音识别修复。"
    if technical_status == "degraded":
        return "语音识别可继续使用，但部分能力降级；请检查说话人分离或模型依赖设置。"
    if "missing local ASR model" in reason or "missing required ASR dependencies" in reason:
        return "本地语音识别未就绪；请在设置中运行一键修复语音识别。"
    return "本地语音识别未就绪；请检查模型、依赖和运行时状态后重试。"


def configured_backend_status(
    engine_name: str | None,
    *,
    asr_device: str | None = None,
    asr_compute_type: str | None = None,
    qwen_mlx_compute_type: str | None = None,
) -> dict[str, object]:
    selected_engine = normalize_engine_name(engine_name)
    if selected_engine == QWEN_MLX_ENGINE:
        compute = (qwen_mlx_compute_type or os.getenv("INSIGHTKIT_QWEN_MLX_COMPUTE_TYPE", "mlx")).strip() or "mlx"
        return {
            "device": "mlx",
            "compute_type": compute,
            "configured_device": "mlx",
            "configured_compute_type": compute,
            "resolved": "",
            "supported_compute_types": ["mlx", "float16", "bfloat16", "float32"],
        }
    if selected_engine == "funasr":
        return {
            "device": "auto",
            "compute_type": "float32",
            "configured_device": "auto",
            "configured_compute_type": "float32",
            "resolved": "",
            "supported_compute_types": ["float16", "float32"],
        }

    requested_device = (asr_device or os.getenv("INSIGHTKIT_ASR_DEVICE", "auto")).strip() or "auto"
    requested_compute = (asr_compute_type or os.getenv("INSIGHTKIT_ASR_COMPUTE_TYPE", "int8")).strip() or "int8"
    return {
        "device": requested_device,
        "compute_type": requested_compute,
        "configured_device": requested_device,
        "configured_compute_type": requested_compute,
        "resolved": "",
        "supported_compute_types": supported_compute_types(requested_device),
    }


def supported_compute_types(device: str) -> list[str]:
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


def _default_model_dir() -> Path:
    return Path(
        os.getenv(
            "INSIGHTKIT_MODEL_DIR",
            str(Path.home() / "Library" / "Application Support" / "InsightKit" / "models"),
        )
    ).expanduser()
