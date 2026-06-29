#!/usr/bin/env python3
"""ASR runtime health probe and bootstrap helpers for InsightKit."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

try:
    from .asr_model_catalog import (
        FUNASR_DEFAULT_ASR_MODEL,
        FUNASR_PUNC_MODEL,
        FUNASR_SPK_MODEL,
        FUNASR_VAD_MODEL,
        QWEN_MLX_DEFAULT_MODEL,
        QWEN_MLX_ENGINE,
        QWEN_MLX_FORCED_ALIGNER_MODEL,
        WHISPER_DEFAULT_MODEL,
        is_funasr_nano_model,
        qwen_mlx_repo_for_model,
        whisper_repo_for_model,
    )
    from .asr_runtime_profile import (
        ASR_ENGINE_OPTIONS,
        attach_asr_runtime_profile,
        configured_backend_status,
        engine_status_snapshot,
        engine_options,
        hf_auth_token,
        normalize_diarization_engine,
        normalize_engine_name,
        resolve_fluid_audio_cli,
        speaker_diarization_status,
    )
except ImportError:
    from asr_model_catalog import (
        FUNASR_DEFAULT_ASR_MODEL,
        FUNASR_PUNC_MODEL,
        FUNASR_SPK_MODEL,
        FUNASR_VAD_MODEL,
        QWEN_MLX_DEFAULT_MODEL,
        QWEN_MLX_ENGINE,
        QWEN_MLX_FORCED_ALIGNER_MODEL,
        WHISPER_DEFAULT_MODEL,
        is_funasr_nano_model,
        qwen_mlx_repo_for_model,
        whisper_repo_for_model,
    )
    from asr_runtime_profile import (
        ASR_ENGINE_OPTIONS,
        attach_asr_runtime_profile,
        configured_backend_status,
        engine_status_snapshot,
        engine_options,
        hf_auth_token,
        normalize_diarization_engine,
        normalize_engine_name,
        resolve_fluid_audio_cli,
        speaker_diarization_status,
    )

DEFAULT_ENGINE = os.getenv("INSIGHTKIT_ASR_ENGINE", "whisper").strip().lower() or "whisper"
DEFAULT_WHISPER_MODEL = (
    os.getenv("INSIGHTKIT_WHISPER_MODEL", "").strip()
    or os.getenv("INSIGHTKIT_ASR_MODEL", "").strip()
    or WHISPER_DEFAULT_MODEL
)
DEFAULT_FUNASR_MODEL = (
    os.getenv("INSIGHTKIT_FUNASR_ASR_MODEL", "").strip()
    or FUNASR_DEFAULT_ASR_MODEL
)
DEFAULT_QWEN_MLX_MODEL = (
    os.getenv("INSIGHTKIT_QWEN_MLX_MODEL", "").strip()
    or os.getenv("INSIGHTKIT_QWEN_ASR_MODEL", "").strip()
    or QWEN_MLX_DEFAULT_MODEL
)
DEFAULT_QWEN_FORCED_ALIGNER_MODEL = (
    os.getenv("INSIGHTKIT_QWEN_FORCED_ALIGNER_MODEL", "").strip()
    or QWEN_MLX_FORCED_ALIGNER_MODEL
)
MODEL_DIR = Path(
    os.getenv(
        "INSIGHTKIT_MODEL_DIR",
        str(Path.home() / "Library" / "Application Support" / "InsightKit" / "models"),
    )
).expanduser()
WHISPER_ROOT = MODEL_DIR / "faster-whisper"
FUNASR_ROOT = MODEL_DIR / "funasr"
QWEN_MLX_ROOT = MODEL_DIR / "qwen3-asr"
DIARIZATION_ENGINE = os.getenv("INSIGHTKIT_DIARIZATION_ENGINE", "fluid-lseend").strip()
FLUIDAUDIO_CLI = os.getenv("INSIGHTKIT_FLUIDAUDIO_CLI", "").strip()

FUNASR_DEFAULTS = {
    "asr": DEFAULT_FUNASR_MODEL,
    "vad": FUNASR_VAD_MODEL,
    "punc": FUNASR_PUNC_MODEL,
    "spk": FUNASR_SPK_MODEL,
}


def _hf_auth_token() -> str:
    return hf_auth_token()


def _diarization_engine() -> str:
    return normalize_diarization_engine(DIARIZATION_ENGINE)


def _resolve_fluid_audio_cli() -> Path | None:
    return resolve_fluid_audio_cli(model_dir=MODEL_DIR, configured_cli=FLUIDAUDIO_CLI)


def _speaker_diarization_status(optional: dict[str, bool], *, funasr_spk_ready: bool = False) -> dict[str, Any]:
    return speaker_diarization_status(
        optional,
        diarization_engine=_diarization_engine(),
        funasr_spk_ready=funasr_spk_ready,
        model_dir=MODEL_DIR,
        configured_cli=FLUIDAUDIO_CLI,
        hf_token_value=_hf_auth_token(),
    )


def _backend_status(engine: str) -> dict[str, Any]:
    return configured_backend_status(engine)


def _normalize_engine(engine: str | None) -> str:
    return normalize_engine_name(engine, default_engine=DEFAULT_ENGINE)


def _module_installed(module_name: str) -> bool:
    try:
        return importlib.util.find_spec(module_name) is not None
    except ModuleNotFoundError:
        return False


def _required_modules(engine: str) -> dict[str, str]:
    if engine == QWEN_MLX_ENGINE:
        return {
            "mlx_qwen3_asr": "mlx-qwen3-asr",
            "mlx": "mlx",
            "huggingface_hub": "huggingface-hub",
            "silero_vad": "silero-vad",
        }
    if engine == "funasr":
        return {
            "funasr": "funasr",
            "modelscope": "modelscope",
            "torch": "torch",
            "torchaudio": "torchaudio",
        }
    return {
        "faster_whisper": "faster-whisper",
        "silero_vad": "silero-vad",
    }


def _optional_modules() -> dict[str, str]:
    return {
        "huggingface_hub": "huggingface-hub",
        "pyannote.audio": "pyannote-audio",
        "torch": "torch",
        "torchcodec": "torchcodec",
        "openai": "openai",
        "google.generativeai": "google-generativeai",
    }


def _repo_for_whisper(model_name: str) -> str:
    return whisper_repo_for_model(model_name)


def _target_whisper_path(model_name: str) -> Path:
    return WHISPER_ROOT / model_name


def _target_funasr_paths() -> dict[str, Path]:
    return {
        "asr": FUNASR_ROOT / "asr",
        "vad": FUNASR_ROOT / "vad",
        "punc": FUNASR_ROOT / "punc",
        "spk": FUNASR_ROOT / "spk",
    }


def _target_qwen_path(model_name: str) -> Path:
    path = Path(model_name).expanduser()
    if path.is_absolute():
        return path
    return QWEN_MLX_ROOT / model_name.strip().split("/")[-1]


def _target_qwen_forced_aligner_path() -> Path:
    return _target_qwen_path(DEFAULT_QWEN_FORCED_ALIGNER_MODEL)


def _qwen_snapshot_ready(path: Path) -> bool:
    return path.exists() and (path / "config.json").exists() and any(path.glob("*.safetensors"))


def _funasr_model_kwargs(model_name: str, model_source: Path | str) -> dict[str, Any]:
    kwargs: dict[str, Any] = {
        "trust_remote_code": True,
        "disable_update": True,
    }
    source_path = Path(str(model_source)).expanduser()
    if is_funasr_nano_model(model_name):
        # FunASR 1.3.x includes the Nano model implementation, but it uses
        # package-local bare imports and must be imported before AutoModel
        # looks up the registered model class.
        import funasr.models.fun_asr_nano as nano_pkg

        nano_dir = str(Path(nano_pkg.__file__).resolve().parent)
        if nano_dir not in sys.path:
            sys.path.insert(0, nano_dir)
        import funasr.models.fun_asr_nano.model  # noqa: F401

        model_py = source_path / "model.py"
        if model_py.exists():
            kwargs["remote_code"] = str(model_py)
    return kwargs


def _engine_status(engine: str, whisper_model: str, funasr_model: str) -> dict[str, Any]:
    required = {
        pip_name: _module_installed(module_name)
        for module_name, pip_name in _required_modules(engine).items()
    }
    optional = {
        pip_name: _module_installed(module_name)
        for module_name, pip_name in _optional_modules().items()
    }

    if engine == QWEN_MLX_ENGINE:
        model_path = _target_qwen_path(DEFAULT_QWEN_MLX_MODEL)
        aligner_path = _target_qwen_forced_aligner_path()
        model_exists = _qwen_snapshot_ready(model_path)
        aligner_exists = _qwen_snapshot_ready(aligner_path)
        return engine_status_snapshot(
            required=required,
            optional=optional,
            model_name=DEFAULT_QWEN_MLX_MODEL,
            model_path=model_path,
            model_exists=model_exists,
            vad_engine="silero-vad",
            vad_ready=required.get("silero-vad", False),
            timestamps={
                "engine": "qwen-forced-aligner",
                "enabled": True,
                "ready": aligner_exists,
                "model": DEFAULT_QWEN_FORCED_ALIGNER_MODEL,
                "path": str(aligner_path),
            },
            diarization_engine=_diarization_engine(),
            model_dir=MODEL_DIR,
            configured_cli=FLUIDAUDIO_CLI,
        )

    if engine == "funasr":
        paths = _target_funasr_paths()
        model_exists = paths["asr"].exists()
        vad_ready = required.get("funasr", False) and paths["vad"].exists()
        diar_ready = paths["spk"].exists()
        return engine_status_snapshot(
            required=required,
            optional=optional,
            model_name=funasr_model,
            model_path=paths["asr"],
            model_exists=model_exists,
            vad_engine="funasr-vad",
            vad_ready=vad_ready,
            diarization_engine=_diarization_engine(),
            funasr_spk_ready=diar_ready,
            model_dir=MODEL_DIR,
            configured_cli=FLUIDAUDIO_CLI,
        )

    model_path = _target_whisper_path(whisper_model)
    return engine_status_snapshot(
        required=required,
        optional=optional,
        model_name=whisper_model,
        model_path=model_path,
        model_exists=model_path.exists(),
        vad_engine="silero-vad",
        vad_ready=required.get("silero-vad", False),
        diarization_engine=_diarization_engine(),
        model_dir=MODEL_DIR,
        configured_cli=FLUIDAUDIO_CLI,
    )


def runtime_status(engine: str | None = None) -> dict[str, Any]:
    normalized_engine = _normalize_engine(engine)
    whisper_status = _engine_status("whisper", DEFAULT_WHISPER_MODEL, DEFAULT_FUNASR_MODEL)
    funasr_status = _engine_status("funasr", DEFAULT_WHISPER_MODEL, DEFAULT_FUNASR_MODEL)
    qwen_status = _engine_status(QWEN_MLX_ENGINE, DEFAULT_WHISPER_MODEL, DEFAULT_FUNASR_MODEL)
    if normalized_engine == QWEN_MLX_ENGINE:
        active = qwen_status
    elif normalized_engine == "funasr":
        active = funasr_status
    else:
        active = whisper_status

    status = {
        "python": {
            "executable": sys.executable,
            "version": sys.version.split()[0],
        },
        "engine": normalized_engine,
        "engine_options": engine_options(),
        "active_profile": active["model"]["name"],
        "model": active["model"],
        "vad": active["vad"],
        "timestamps": active.get("timestamps", {}),
        "speaker_diarization": active["speaker_diarization"],
        "dependencies": {
            "required": active["required"],
            "optional": active["optional"],
        },
        "ready_by_engine": {
            "whisper": bool(whisper_status["ready"]),
            "funasr": bool(funasr_status["ready"]),
            QWEN_MLX_ENGINE: bool(qwen_status["ready"]),
        },
        "backend": _backend_status(normalized_engine),
        "warm": {
            "ready": False,
            "state": "idle",
            "in_progress": False,
            "attempt": 0,
            "last_warm_ms": 0,
            "last_error": "",
        },
        "ready": bool(active["ready"]),
    }
    return attach_asr_runtime_profile(
        status,
        backend=status["backend"],
        warm=status["warm"],
        configured_engine=normalized_engine,
    )


def _run(cmd: list[str], timeout: int = 3600) -> tuple[bool, str]:
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
            timeout=timeout,
            check=False,
        )
    except Exception as exc:
        return False, str(exc)
    if proc.returncode == 0:
        return True, (proc.stdout or "").strip()[-4000:]
    tail = f"{(proc.stdout or '').strip()}\n{(proc.stderr or '').strip()}".strip()
    return False, tail[-4000:]


def _bootstrap_whisper(model_name: str) -> dict[str, Any]:
    steps: list[dict[str, Any]] = []
    WHISPER_ROOT.mkdir(parents=True, exist_ok=True)

    install_required_cmd = [
        sys.executable,
        "-m",
        "pip",
        "install",
        "--upgrade",
        "pip",
        "setuptools",
        "wheel",
        "faster-whisper",
        "silero-vad",
        "huggingface-hub>=0.34,<1.0",
        "openai",
        "google-generativeai",
    ]
    ok, output = _run(install_required_cmd, timeout=5400)
    steps.append({"name": "install_required_dependencies", "ok": ok, "detail": output})
    if not ok:
        return {"ok": False, "steps": steps, "status": runtime_status(engine="whisper")}

    install_optional_cmd = [
        sys.executable,
        "-m",
        "pip",
        "install",
        "pyannote.audio",
    ]
    optional_ok, optional_output = _run(install_optional_cmd, timeout=3600)
    steps.append({"name": "install_optional_pyannote", "ok": optional_ok, "detail": optional_output})

    target = _target_whisper_path(model_name)
    if not target.exists():
        target.mkdir(parents=True, exist_ok=True)
        repo = _repo_for_whisper(model_name)
        download_cmd = [
            sys.executable,
            "-c",
            (
                "from faster_whisper.utils import download_model;"
                f"download_model({json.dumps(model_name)}, output_dir={json.dumps(str(target))})"
            ),
        ]
        ok, output = _run(download_cmd, timeout=5400)
        steps.append({"name": "download_model", "ok": ok, "detail": output, "repo": repo, "path": str(target)})
        if not ok:
            return {"ok": False, "steps": steps, "status": runtime_status(engine="whisper")}
    else:
        steps.append({"name": "download_model", "ok": True, "detail": "model already exists", "path": str(target)})

    validate_cmd = [
        sys.executable,
        "-c",
        (
            "from faster_whisper import WhisperModel;"
            f"WhisperModel(r'{target}', device='cpu', compute_type='int8', local_files_only=True);"
            "print('ok')"
        ),
    ]
    ok, output = _run(validate_cmd, timeout=600)
    steps.append({"name": "validate_model_load", "ok": ok, "detail": output})
    status = runtime_status(engine="whisper")
    return {"ok": ok and status.get("ready", False), "steps": steps, "status": status}


def _bootstrap_funasr(model_name: str) -> dict[str, Any]:
    steps: list[dict[str, Any]] = []
    FUNASR_ROOT.mkdir(parents=True, exist_ok=True)
    paths = _target_funasr_paths()

    install_required_cmd = [
        sys.executable,
        "-m",
        "pip",
        "install",
        "funasr",
        "modelscope",
        "torch",
        "torchaudio",
        "openai",
        "google-generativeai",
    ]
    ok, output = _run(install_required_cmd, timeout=5400)
    steps.append({"name": "install_required_dependencies", "ok": ok, "detail": output})
    if not ok:
        return {"ok": False, "steps": steps, "status": runtime_status(engine="funasr")}

    for key, model_id in {
        "asr": model_name,
        "vad": FUNASR_DEFAULTS["vad"],
        "punc": FUNASR_DEFAULTS["punc"],
        "spk": FUNASR_DEFAULTS["spk"],
    }.items():
        target = paths[key]
        target.mkdir(parents=True, exist_ok=True)
        download_cmd = [
            sys.executable,
            "-c",
            (
                "try:\n"
                " from modelscope.hub.snapshot_download import snapshot_download\n"
                "except Exception:\n"
                " from modelscope import snapshot_download\n"
                f"snapshot_download(model_id='{model_id}', local_dir=r'{target}')"
            ),
        ]
        ok, output = _run(download_cmd, timeout=5400)
        steps.append(
            {
                "name": f"download_{key}_model",
                "ok": ok,
                "detail": output,
                "repo": model_id,
                "path": str(target),
            }
        )
        if not ok:
            return {"ok": False, "steps": steps, "status": runtime_status(engine="funasr")}

    is_nano = is_funasr_nano_model(model_name)
    validate_kwargs = {
        "model": str(paths["asr"]),
        "vad_model": None if is_nano else str(paths["vad"]),
        "punc_model": None if is_nano else str(paths["punc"]),
        "spk_model": None if is_nano else str(paths["spk"]),
        **_funasr_model_kwargs(model_name, paths["asr"]),
    }
    nano_import = ""
    if is_nano:
        nano_import = (
            "import sys;"
            "import funasr.models.fun_asr_nano as nano_pkg;"
            "from pathlib import Path;"
            "nano_dir=str(Path(nano_pkg.__file__).resolve().parent);"
            "sys.path.insert(0,nano_dir) if nano_dir not in sys.path else None;"
            "import funasr.models.fun_asr_nano.model;"
        )
    validate_cmd = [
        sys.executable,
        "-c",
        (
            "import json;"
            + nano_import +
            "from funasr import AutoModel;"
            f"AutoModel(**json.loads({json.dumps(json.dumps(validate_kwargs))}));"
            "print('ok')"
        ),
    ]
    ok, output = _run(validate_cmd, timeout=1200)
    steps.append({"name": "validate_model_load", "ok": ok, "detail": output})
    status = runtime_status(engine="funasr")
    return {"ok": ok and status.get("ready", False), "steps": steps, "status": status}


def _download_hf_snapshot(repo_id: str, target: Path) -> tuple[bool, str]:
    target.mkdir(parents=True, exist_ok=True)
    download_cmd = [
        sys.executable,
        "-c",
        (
            "from huggingface_hub import snapshot_download;"
            f"snapshot_download(repo_id={json.dumps(repo_id)}, local_dir={json.dumps(str(target))}, "
            "local_dir_use_symlinks=False)"
        ),
    ]
    env = os.environ.copy()
    env.setdefault("HF_HUB_DISABLE_XET", "1")
    try:
        proc = subprocess.run(
            download_cmd,
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
            timeout=7200,
            check=False,
            env=env,
        )
    except Exception as exc:
        return False, str(exc)
    if proc.returncode == 0:
        return True, (proc.stdout or "").strip()[-4000:]
    tail = f"{(proc.stdout or '').strip()}\n{(proc.stderr or '').strip()}".strip()
    return False, tail[-4000:]


def _bootstrap_qwen_mlx(model_name: str) -> dict[str, Any]:
    steps: list[dict[str, Any]] = []
    QWEN_MLX_ROOT.mkdir(parents=True, exist_ok=True)

    install_required_cmd = [
        sys.executable,
        "-m",
        "pip",
        "install",
        "mlx-qwen3-asr[diarize]>=0.3.5",
        "silero-vad",
        "huggingface-hub>=0.34,<1.0",
        "openai",
        "google-generativeai",
    ]
    ok, output = _run(install_required_cmd, timeout=7200)
    steps.append({"name": "install_qwen_mlx_dependencies", "ok": ok, "detail": output})
    if not ok:
        return {"ok": False, "steps": steps, "status": runtime_status(engine=QWEN_MLX_ENGINE)}

    for label, requested_model in {
        "asr": model_name,
        "forced_aligner": DEFAULT_QWEN_FORCED_ALIGNER_MODEL,
    }.items():
        target = _target_qwen_path(requested_model)
        if _qwen_snapshot_ready(target):
            steps.append({"name": f"download_{label}_model", "ok": True, "detail": "model already exists", "path": str(target)})
            continue
        repo = qwen_mlx_repo_for_model(requested_model)
        ok, output = _download_hf_snapshot(repo, target)
        steps.append(
            {
                "name": f"download_{label}_model",
                "ok": ok,
                "detail": output,
                "repo": repo,
                "path": str(target),
            }
        )
        if not ok:
            return {"ok": False, "steps": steps, "status": runtime_status(engine=QWEN_MLX_ENGINE)}

    target = _target_qwen_path(model_name)
    validate_cmd = [
        sys.executable,
        "-c",
        (
            "from mlx_qwen3_asr import Session;"
            f"Session(model=r'{target}');"
            "print('ok')"
        ),
    ]
    ok, output = _run(validate_cmd, timeout=900)
    steps.append({"name": "validate_model_load", "ok": ok, "detail": output})
    status = runtime_status(engine=QWEN_MLX_ENGINE)
    return {"ok": ok and status.get("ready", False), "steps": steps, "status": status}


def bootstrap_runtime(model_name: str | None = None, engine: str | None = None) -> dict[str, Any]:
    normalized_engine = _normalize_engine(engine)
    if normalized_engine == QWEN_MLX_ENGINE:
        model = (model_name or DEFAULT_QWEN_MLX_MODEL).strip() or DEFAULT_QWEN_MLX_MODEL
        return _bootstrap_qwen_mlx(model_name=model)
    if normalized_engine == "funasr":
        model = (model_name or DEFAULT_FUNASR_MODEL).strip() or DEFAULT_FUNASR_MODEL
        return _bootstrap_funasr(model_name=model)
    model = (model_name or DEFAULT_WHISPER_MODEL).strip() or DEFAULT_WHISPER_MODEL
    return _bootstrap_whisper(model_name=model)


def main() -> int:
    parser = argparse.ArgumentParser(description="Probe or bootstrap InsightKit ASR runtime")
    parser.add_argument("action", choices=["status", "bootstrap"], help="operation")
    parser.add_argument("--model", default="", help="ASR model name")
    parser.add_argument("--engine", default=DEFAULT_ENGINE, choices=list(ASR_ENGINE_OPTIONS), help="ASR engine")
    args = parser.parse_args()

    if args.action == "status":
        print(json.dumps(runtime_status(engine=args.engine), ensure_ascii=False))
        return 0

    model = args.model.strip() or None
    result = bootstrap_runtime(model_name=model, engine=args.engine)
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result.get("ok") else 2


if __name__ == "__main__":
    raise SystemExit(main())
