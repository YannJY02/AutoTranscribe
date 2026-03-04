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

DEFAULT_ENGINE = os.getenv("INSIGHTKIT_ASR_ENGINE", "whisper").strip().lower() or "whisper"
DEFAULT_WHISPER_MODEL = (
    os.getenv("INSIGHTKIT_WHISPER_MODEL", "").strip()
    or os.getenv("INSIGHTKIT_ASR_MODEL", "").strip()
    or "large-v3"
)
DEFAULT_FUNASR_MODEL = (
    os.getenv("INSIGHTKIT_FUNASR_ASR_MODEL", "").strip()
    or "iic/speech_paraformer-large-vad-punc_asr_nat-zh-cn-16k-common-vocab8404-pytorch"
)
MODEL_DIR = Path(
    os.getenv(
        "INSIGHTKIT_MODEL_DIR",
        str(Path.home() / "Library" / "Application Support" / "InsightKit" / "models"),
    )
).expanduser()
WHISPER_ROOT = MODEL_DIR / "faster-whisper"
FUNASR_ROOT = MODEL_DIR / "funasr"

FUNASR_DEFAULTS = {
    "asr": DEFAULT_FUNASR_MODEL,
    "vad": "iic/speech_fsmn_vad_zh-cn-16k-common-pytorch",
    "punc": "iic/punc_ct-transformer_zh-cn-common-vocab272727-pytorch",
    "spk": "iic/speech_campplus_sv_zh-cn_16k-common",
}


def _normalize_engine(engine: str | None) -> str:
    raw = (engine or DEFAULT_ENGINE).strip().lower()
    if raw not in {"whisper", "funasr"}:
        return "whisper"
    return raw


def _module_installed(module_name: str) -> bool:
    try:
        return importlib.util.find_spec(module_name) is not None
    except ModuleNotFoundError:
        return False


def _required_modules(engine: str) -> dict[str, str]:
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
        "openai": "openai",
        "google.generativeai": "google-generativeai",
    }


def _repo_for_whisper(model_name: str) -> str:
    normalized = model_name.strip()
    if normalized.startswith("Systran/"):
        return normalized
    return f"Systran/faster-whisper-{normalized}"


def _target_whisper_path(model_name: str) -> Path:
    return WHISPER_ROOT / model_name


def _target_funasr_paths() -> dict[str, Path]:
    return {
        "asr": FUNASR_ROOT / "asr",
        "vad": FUNASR_ROOT / "vad",
        "punc": FUNASR_ROOT / "punc",
        "spk": FUNASR_ROOT / "spk",
    }


def _engine_status(engine: str, whisper_model: str, funasr_model: str) -> dict[str, Any]:
    required = {
        pip_name: _module_installed(module_name)
        for module_name, pip_name in _required_modules(engine).items()
    }
    optional = {
        pip_name: _module_installed(module_name)
        for module_name, pip_name in _optional_modules().items()
    }

    hf_token = (
        os.getenv("HF_TOKEN", "").strip()
        or os.getenv("HUGGINGFACE_TOKEN", "").strip()
        or os.getenv("HUGGING_FACE_HUB_TOKEN", "").strip()
    )

    if engine == "funasr":
        paths = _target_funasr_paths()
        model_exists = paths["asr"].exists()
        vad_ready = required.get("funasr", False) and paths["vad"].exists()
        diar_ready = paths["spk"].exists()
        ready = all(required.values()) and model_exists
        return {
            "required": required,
            "optional": optional,
            "model": {
                "name": funasr_model,
                "path": str(paths["asr"]),
                "exists": model_exists,
            },
            "vad": {
                "engine": "funasr-vad",
                "enabled": True,
                "ready": vad_ready,
            },
            "speaker_diarization": {
                "engine": "campplus",
                "enabled": True,
                "ready": diar_ready,
                "degraded": not diar_ready,
                "reason": "" if diar_ready else "missing local speaker model",
            },
            "ready": ready,
        }

    model_path = _target_whisper_path(whisper_model)
    asr_ready = all(required.values()) and model_path.exists()
    diarization_enabled = optional.get("pyannote-audio", False) and bool(hf_token)
    return {
        "required": required,
        "optional": optional,
        "model": {
            "name": whisper_model,
            "path": str(model_path),
            "exists": model_path.exists(),
        },
        "vad": {
            "engine": "silero-vad",
            "enabled": True,
            "ready": required.get("silero-vad", False),
        },
        "speaker_diarization": {
            "engine": "pyannote",
            "enabled": True,
            "ready": diarization_enabled,
            "degraded": not diarization_enabled,
            "reason": "" if diarization_enabled else "missing pyannote package or HF token",
        },
        "ready": asr_ready,
    }


def runtime_status(engine: str | None = None) -> dict[str, Any]:
    normalized_engine = _normalize_engine(engine)
    whisper_status = _engine_status("whisper", DEFAULT_WHISPER_MODEL, DEFAULT_FUNASR_MODEL)
    funasr_status = _engine_status("funasr", DEFAULT_WHISPER_MODEL, DEFAULT_FUNASR_MODEL)
    active = whisper_status if normalized_engine == "whisper" else funasr_status

    return {
        "python": {
            "executable": sys.executable,
            "version": sys.version.split()[0],
        },
        "engine": normalized_engine,
        "engine_options": ["whisper", "funasr"],
        "active_profile": active["model"]["name"],
        "model": active["model"],
        "vad": active["vad"],
        "speaker_diarization": active["speaker_diarization"],
        "dependencies": {
            "required": active["required"],
            "optional": active["optional"],
        },
        "ready_by_engine": {
            "whisper": bool(whisper_status["ready"]),
            "funasr": bool(funasr_status["ready"]),
        },
        "ready": bool(active["ready"]),
    }


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
        "huggingface-hub",
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
                "from huggingface_hub import snapshot_download;"
                f"snapshot_download(repo_id='{repo}', local_dir=r'{target}', local_dir_use_symlinks=False)"
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
        "--upgrade",
        "pip",
        "setuptools",
        "wheel",
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

    validate_cmd = [
        sys.executable,
        "-c",
        (
            "from funasr import AutoModel;"
            f"AutoModel(model=r'{paths['asr']}', vad_model=r'{paths['vad']}', punc_model=r'{paths['punc']}', spk_model=r'{paths['spk']}');"
            "print('ok')"
        ),
    ]
    ok, output = _run(validate_cmd, timeout=1200)
    steps.append({"name": "validate_model_load", "ok": ok, "detail": output})
    status = runtime_status(engine="funasr")
    return {"ok": ok and status.get("ready", False), "steps": steps, "status": status}


def bootstrap_runtime(model_name: str | None = None, engine: str | None = None) -> dict[str, Any]:
    normalized_engine = _normalize_engine(engine)
    if normalized_engine == "funasr":
        model = (model_name or DEFAULT_FUNASR_MODEL).strip() or DEFAULT_FUNASR_MODEL
        return _bootstrap_funasr(model_name=model)
    model = (model_name or DEFAULT_WHISPER_MODEL).strip() or DEFAULT_WHISPER_MODEL
    return _bootstrap_whisper(model_name=model)


def main() -> int:
    parser = argparse.ArgumentParser(description="Probe or bootstrap InsightKit ASR runtime")
    parser.add_argument("action", choices=["status", "bootstrap"], help="operation")
    parser.add_argument("--model", default="", help="ASR model name")
    parser.add_argument("--engine", default=DEFAULT_ENGINE, choices=["whisper", "funasr"], help="ASR engine")
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
