#!/usr/bin/env python3
"""Run incremental ASR for a single WAV chunk."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

# Allow importing project modules when run directly.
sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from transcriber import transcribe_audio_chunk  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description="Transcribe a live WAV chunk")
    parser.add_argument("--wav", required=True, help="path to chunk wav")
    parser.add_argument("--offset-ms", type=int, default=0, help="chunk start offset in meeting")
    parser.add_argument(
        "--engine",
        default="",
        choices=["", "whisper", "funasr", "qwen-mlx"],
        help="override local ASR engine",
    )
    args = parser.parse_args()

    if args.engine:
        os.environ["INSIGHTKIT_ASR_ENGINE"] = args.engine

    wav = Path(args.wav).expanduser().resolve()
    try:
        segments = transcribe_audio_chunk(wav, offset_ms=args.offset_ms)
        print(json.dumps({"segments": segments}, ensure_ascii=False))
        return 0
    except Exception as exc:
        print(json.dumps({"error": str(exc), "segments": []}, ensure_ascii=False))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
