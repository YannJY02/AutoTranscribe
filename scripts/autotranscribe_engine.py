#!/usr/bin/env python3
"""Switch the LaunchAgent-backed Desktop/Downloads transcription engine."""

from __future__ import annotations

import argparse
import os
import plistlib
import subprocess
from pathlib import Path

try:
    from .asr_model_catalog import (
        FUNASR_DEFAULT_ASR_MODEL,
        QWEN_MLX_DEFAULT_MODEL,
        QWEN_MLX_ENGINE,
        QWEN_MLX_FORCED_ALIGNER_MODEL,
        WHISPER_RECOMMENDED_FAST_MODEL,
    )
except ImportError:
    from asr_model_catalog import (
        FUNASR_DEFAULT_ASR_MODEL,
        QWEN_MLX_DEFAULT_MODEL,
        QWEN_MLX_ENGINE,
        QWEN_MLX_FORCED_ALIGNER_MODEL,
        WHISPER_RECOMMENDED_FAST_MODEL,
    )


DEFAULT_PLIST = Path.home() / "Library" / "LaunchAgents" / "com.yann.autotranscribe.plist"
DEFAULT_MODEL_DIR = Path.home() / "Library" / "Application Support" / "InsightKit" / "models"
DEFAULT_PATH = "/Users/yann.jy/miniconda3/envs/transcribe/bin:/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"


def _model_for_engine(engine: str) -> str:
    if engine == "funasr":
        return FUNASR_DEFAULT_ASR_MODEL
    if engine == QWEN_MLX_ENGINE:
        return QWEN_MLX_DEFAULT_MODEL
    return WHISPER_RECOMMENDED_FAST_MODEL


def _load_plist(path: Path) -> dict:
    if not path.exists():
        raise FileNotFoundError(str(path))
    with path.open("rb") as fh:
        return plistlib.load(fh)


def _write_plist(path: Path, payload: dict) -> None:
    with path.open("wb") as fh:
        plistlib.dump(payload, fh, sort_keys=False)


def configure_engine(plist_path: Path, engine: str) -> dict[str, str]:
    payload = _load_plist(plist_path)
    env = dict(payload.get("EnvironmentVariables") or {})
    env.setdefault("PATH", DEFAULT_PATH)
    env.update(
        {
            "INSIGHTKIT_ASR_ENGINE": engine,
            "INSIGHTKIT_ASR_MODEL": _model_for_engine(engine),
            "INSIGHTKIT_ASR_STRICT_LOCAL_ONLY": "1",
            "INSIGHTKIT_MODEL_DIR": str(DEFAULT_MODEL_DIR),
            "INSIGHTKIT_VAD_ENABLED": "1",
            "INSIGHTKIT_DIARIZATION_ENABLED": "1",
            "INSIGHTKIT_WHISPER_MODEL": WHISPER_RECOMMENDED_FAST_MODEL,
            "INSIGHTKIT_FUNASR_ASR_MODEL": FUNASR_DEFAULT_ASR_MODEL,
            "INSIGHTKIT_QWEN_MLX_MODEL": QWEN_MLX_DEFAULT_MODEL,
            "INSIGHTKIT_QWEN_ASR_MODEL": QWEN_MLX_DEFAULT_MODEL,
            "INSIGHTKIT_QWEN_FORCED_ALIGNER_MODEL": QWEN_MLX_FORCED_ALIGNER_MODEL,
            "INSIGHTKIT_QWEN_RETURN_TIMESTAMPS": "1",
        }
    )
    payload["EnvironmentVariables"] = env
    _write_plist(plist_path, payload)
    return env


def reload_launch_agent(plist_path: Path) -> None:
    uid = os.getuid()
    domain = f"gui/{uid}"
    label = "com.yann.autotranscribe"
    subprocess.run(["launchctl", "bootout", domain, str(plist_path)], check=False, stderr=subprocess.DEVNULL)
    subprocess.run(["launchctl", "bootstrap", domain, str(plist_path)], check=True)
    subprocess.run(["launchctl", "print", f"{domain}/{label}"], check=False)


def main() -> int:
    parser = argparse.ArgumentParser(description="Switch Desktop/Downloads auto-transcription engine")
    parser.add_argument("engine", choices=["whisper", "funasr", QWEN_MLX_ENGINE])
    parser.add_argument("--plist", default=str(DEFAULT_PLIST), help="LaunchAgent plist path")
    parser.add_argument("--no-reload", action="store_true", help="write plist without reloading launchd")
    args = parser.parse_args()

    plist_path = Path(args.plist).expanduser()
    env = configure_engine(plist_path, args.engine)
    print(f"configured {plist_path}")
    print(f"INSIGHTKIT_ASR_ENGINE={env['INSIGHTKIT_ASR_ENGINE']}")
    print(f"INSIGHTKIT_ASR_MODEL={env['INSIGHTKIT_ASR_MODEL']}")
    if not args.no_reload:
        reload_launch_agent(plist_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
