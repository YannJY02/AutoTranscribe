#!/usr/bin/env python3
"""Evaluate one manually observed clapper event in a saved recording."""

from __future__ import annotations

import argparse
import math
from decimal import Decimal
from pathlib import Path


DEFAULT_TOLERANCE_MS = 150.0


def measure_offset(
    audio_event_sec: float,
    video_event_sec: float,
    tolerance_ms: float = DEFAULT_TOLERANCE_MS,
) -> tuple[float, str, bool]:
    values = (audio_event_sec, video_event_sec, tolerance_ms)
    if not all(math.isfinite(value) for value in values):
        raise ValueError("event times and tolerance must be finite")
    if audio_event_sec < 0 or video_event_sec < 0:
        raise ValueError("event times must be non-negative")
    if tolerance_ms <= 0:
        raise ValueError("tolerance must be positive")

    offset_ms = float(
        (Decimal(str(video_event_sec)) - Decimal(str(audio_event_sec))) * 1_000
    )
    if offset_ms > 0:
        direction = "video_lags_audio"
    elif offset_ms < 0:
        direction = "video_leads_audio"
    else:
        direction = "aligned"
    return offset_ms, direction, abs(offset_ms) < tolerance_ms


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recording", type=Path, help="Saved recording containing the observed clap")
    parser.add_argument("audio_event_sec", type=float, help="Audio click onset in seconds")
    parser.add_argument("video_event_sec", type=float, help="First hand-contact frame in seconds")
    parser.add_argument(
        "--tolerance-ms",
        type=float,
        default=DEFAULT_TOLERANCE_MS,
        help="Strict upper bound for absolute offset (default: 150 ms)",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not args.recording.is_file():
        raise SystemExit(f"recording does not exist: {args.recording}")

    try:
        offset_ms, direction, passed = measure_offset(
            args.audio_event_sec,
            args.video_event_sec,
            args.tolerance_ms,
        )
    except ValueError as exc:
        raise SystemExit(str(exc)) from exc

    print(f"recording={args.recording.resolve()}")
    print(f"approx_offset_ms={offset_ms:+.1f}")
    print(f"direction={direction}")
    print(f"tolerance_ms={args.tolerance_ms:.1f}")
    print(f"result={'GREEN' if passed else 'RED'}")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
