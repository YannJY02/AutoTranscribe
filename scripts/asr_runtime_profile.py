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


ASR_ENGINE_OPTIONS = ("whisper", "funasr", QWEN_MLX_ENGINE)


def normalize_engine_name(engine_name: str | None, *, default_engine: str | None = None) -> str:
    raw = (engine_name or default_engine or "whisper").strip().lower()
    if raw in {QWEN_MLX_ENGINE, "qwenmlx", "qwen_mlx", "qwen"}:
        return QWEN_MLX_ENGINE
    if raw == "funasr":
        return "funasr"
    return "whisper"


def engine_options() -> list[str]:
    return list(ASR_ENGINE_OPTIONS)


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
