#!/usr/bin/env python3
"""Diagnose InsightKit issue 24 media/transcript timeline alignment.

Reads a saved Record Folder and verifies that the single review media file has
one coherent timeline for audio, video, transcript markers, and Smart Minutes
markers.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any


MEDIA_EXTENSIONS = ("mp4", "mov", "mkv", "m4a", "mp3", "wav")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("record", nargs="?", type=Path, help="Path to a Record Folder")
    parser.add_argument(
        "--latest-live-video",
        action="store_true",
        help="Use the newest live Record Folder that contains recording.mp4",
    )
    parser.add_argument(
        "--records-root",
        type=Path,
        default=Path.home() / "Documents" / "InsightKit" / "Records",
        help="Records root used when --latest-live-video is set",
    )
    parser.add_argument(
        "--max-stream-delta-sec",
        type=float,
        default=1.0,
        help="Allowed audio/video duration difference for a composed review video",
    )
    parser.add_argument(
        "--max-metadata-delta-sec",
        type=float,
        default=2.0,
        help="Allowed metadata duration difference from playable media duration",
    )
    parser.add_argument(
        "--max-source-stream-delta-sec",
        type=float,
        default=2.0,
        help="Allowed duration difference between capture source video and audio timelines",
    )
    parser.add_argument(
        "--max-source-final-delta-sec",
        type=float,
        default=2.0,
        help="Allowed duration difference between capture source media and final playable media",
    )
    parser.add_argument(
        "--ffprobe",
        default=shutil.which("ffprobe") or "/Users/yann.jy/miniconda3/bin/ffprobe",
        help="ffprobe executable",
    )
    return parser.parse_args()


def load_json(path: Path, fallback: Any) -> Any:
    if not path.exists():
        return fallback
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Invalid JSON in {path}: {exc}") from exc


def find_latest_live_video(records_root: Path) -> Path:
    candidates: list[tuple[float, Path]] = []
    if not records_root.exists():
        raise SystemExit(f"Records root does not exist: {records_root}")
    for record in records_root.iterdir():
        if not record.is_dir() or not record.name.startswith("live-"):
            continue
        media = record / "recording.mp4"
        metadata = record / "metadata.json"
        if media.exists() and metadata.exists():
            candidates.append((max(media.stat().st_mtime, metadata.stat().st_mtime), record))
    if not candidates:
        raise SystemExit(f"No live Record Folder with recording.mp4 under {records_root}")
    return sorted(candidates, reverse=True)[0][1]


def find_media(record: Path) -> Path | None:
    for ext in MEDIA_EXTENSIONS:
        candidate = record / f"recording.{ext}"
        if candidate.exists():
            return candidate
    return None


def ffprobe_media(path: Path, ffprobe: str) -> dict[str, Any]:
    cmd = [
        ffprobe,
        "-v",
        "error",
        "-show_entries",
        "stream=index,codec_type,start_time,duration,avg_frame_rate,nb_frames:format=start_time,duration",
        "-of",
        "json",
        str(path),
    ]
    completed = subprocess.run(cmd, check=True, text=True, capture_output=True)
    return json.loads(completed.stdout)


def to_float(value: Any) -> float | None:
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def timestamp_to_seconds(value: Any) -> float | None:
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    parts = text.split(":")
    try:
        numbers = [float(part) for part in parts]
    except ValueError:
        return None
    if len(numbers) == 1:
        return numbers[0]
    if len(numbers) == 2:
        return numbers[0] * 60 + numbers[1]
    if len(numbers) == 3:
        return numbers[0] * 3600 + numbers[1] * 60 + numbers[2]
    return None


def stream_summary(probe: dict[str, Any]) -> dict[str, dict[str, float | None]]:
    summary: dict[str, dict[str, float | None]] = {}
    for stream in probe.get("streams", []):
        kind = stream.get("codec_type")
        if kind not in {"audio", "video"}:
            continue
        summary[kind] = {
            "start": to_float(stream.get("start_time")),
            "duration": to_float(stream.get("duration")),
            "frames": to_float(stream.get("nb_frames")),
        }
    return summary


def capture_path(value: Any) -> Path | None:
    if not isinstance(value, str) or not value:
        return None
    return Path(value).expanduser()


def primary_stream_duration(probe: dict[str, Any], kind: str) -> float | None:
    stream_duration = stream_summary(probe).get(kind, {}).get("duration")
    return stream_duration if stream_duration is not None else to_float(probe.get("format", {}).get("duration"))


def inspect_capture_sources(
    capture_timeline: dict[str, Any],
    ffprobe: str,
    playable_duration: float | None,
    max_source_stream_delta_sec: float,
    max_source_final_delta_sec: float,
) -> tuple[dict[str, Any] | None, list[str], list[str]]:
    if not isinstance(capture_timeline, dict) or not capture_timeline:
        return None, [], []

    warnings: list[str] = []
    failures: list[str] = []
    video_path = capture_path(capture_timeline.get("videoPath"))
    audio_path = capture_path(capture_timeline.get("audioPath"))
    source_report: dict[str, Any] = {
        "video_path": str(video_path) if video_path else None,
        "audio_path": str(audio_path) if audio_path else None,
    }

    video_duration = None
    audio_duration = None

    if video_path is None:
        warnings.append("capture_timeline.json has no videoPath; source video timeline cannot be checked")
    elif not video_path.exists():
        warnings.append(f"capture source video is missing: {video_path}")
    else:
        video_probe = ffprobe_media(video_path, ffprobe)
        video_duration = primary_stream_duration(video_probe, "video")
        source_report["video_duration_sec"] = video_duration
        source_report["video_format_duration_sec"] = to_float(video_probe.get("format", {}).get("duration"))
        source_report["video_frames"] = stream_summary(video_probe).get("video", {}).get("frames")

    if audio_path is None:
        warnings.append("capture_timeline.json has no audioPath; source audio timeline cannot be checked")
    elif not audio_path.exists():
        warnings.append(f"capture source audio is missing: {audio_path}")
    else:
        audio_probe = ffprobe_media(audio_path, ffprobe)
        audio_duration = primary_stream_duration(audio_probe, "audio")
        source_report["audio_duration_sec"] = audio_duration
        source_report["audio_format_duration_sec"] = to_float(audio_probe.get("format", {}).get("duration"))

    source_window = summarize_composition_window(capture_timeline, video_duration, audio_duration)
    composition_window_matches_final = False
    if source_window is not None:
        source_report["composition_window"] = source_window
        if playable_duration is not None:
            predicted_duration = source_window.get("duration_sec")
            if isinstance(predicted_duration, float):
                prediction_delta = abs(predicted_duration - playable_duration)
                source_report["composition_window_final_delta_sec"] = prediction_delta
                composition_window_matches_final = prediction_delta <= max_source_final_delta_sec
                if not composition_window_matches_final:
                    failures.append(
                        "capture timeline predicts composition duration "
                        f"{predicted_duration:.3f}s, which differs from final media by "
                        f"{prediction_delta:.3f}s"
                    )

    if video_duration is not None and audio_duration is not None:
        source_delta = video_duration - audio_duration
        source_report["source_duration_delta_sec"] = source_delta
        if abs(source_delta) > max_source_stream_delta_sec:
            message = (
                "capture source audio/video duration delta "
                f"{source_delta:.3f}s exceeds {max_source_stream_delta_sec:.3f}s; "
                "final duration equality cannot prove visible AV sync"
            )
            if composition_window_matches_final:
                warnings.append(message)
            else:
                failures.append(message)

    if playable_duration is not None:
        if video_duration is not None:
            video_final_delta = video_duration - playable_duration
            source_report["video_source_final_delta_sec"] = video_final_delta
            if abs(video_final_delta) > max_source_final_delta_sec:
                message = (
                    "capture source video duration differs from final media by "
                    f"{video_final_delta:.3f}s, exceeding {max_source_final_delta_sec:.3f}s"
                )
                if composition_window_matches_final:
                    warnings.append(message)
                else:
                    failures.append(message)
        if audio_duration is not None:
            audio_final_delta = audio_duration - playable_duration
            source_report["audio_source_final_delta_sec"] = audio_final_delta

    return source_report, warnings, failures


def summarize_composition_window(
    capture_timeline: dict[str, Any],
    video_duration: float | None,
    audio_duration: float | None,
) -> dict[str, float] | None:
    if video_duration is None or audio_duration is None:
        return None
    composition = capture_timeline.get("compositionTimeline")
    if not isinstance(composition, dict):
        return None
    video_start = to_float(composition.get("videoStartSec"))
    audio_start = to_float(composition.get("audioStartSec"))
    if video_start is None or audio_start is None:
        return None

    video_timeline_end = video_start + video_duration
    audio_timeline_end = audio_start + audio_duration
    intersection_start = max(video_start, audio_start)
    intersection_end = min(video_timeline_end, audio_timeline_end)
    duration = max(0.0, intersection_end - intersection_start)
    return {
        "timeline_video_start_sec": video_start,
        "timeline_audio_start_sec": audio_start,
        "initial_offset_sec": video_start - audio_start,
        "video_source_start_sec": max(0.0, intersection_start - video_start),
        "audio_source_start_sec": max(0.0, intersection_start - audio_start),
        "duration_sec": duration,
    }


def main() -> int:
    args = parse_args()
    record = find_latest_live_video(args.records_root) if args.latest_live_video else args.record
    if record is None:
        raise SystemExit("Provide a Record Folder path or --latest-live-video")
    record = record.expanduser().resolve()
    if not record.exists() or not record.is_dir():
        raise SystemExit(f"Record Folder does not exist: {record}")

    media = find_media(record)
    if media is None:
        raise SystemExit(f"No recording.* media found in {record}")

    metadata = load_json(record / "metadata.json", {})
    transcript = load_json(record / "transcript.json", [])
    minutes = load_json(record / "minutes.json", {})
    insight_package = load_json(record / "insight_package.json", {})
    capture_timeline = load_json(record / "capture_timeline.json", {})

    probe = ffprobe_media(media, args.ffprobe)
    streams = stream_summary(probe)
    format_duration = to_float(probe.get("format", {}).get("duration"))
    metadata_duration = to_float(metadata.get("duration"))
    playable_duration = format_duration

    transcript_starts = [
        int(row.get("start_ms", 0) or 0) / 1000.0
        for row in transcript
        if isinstance(row, dict)
    ]
    transcript_ends = [
        int(row.get("end_ms", 0) or 0) / 1000.0
        for row in transcript
        if isinstance(row, dict)
    ]
    minute_timestamps = [
        timestamp_to_seconds(row.get("timestamp"))
        for row in minutes.get("timeline_beats", [])
        if isinstance(row, dict)
    ]
    evidence_ends = []
    if isinstance(insight_package, dict):
        for section in ("highlight_insights", "speaker_perspectives"):
            for item in insight_package.get(section, []) or []:
                if not isinstance(item, dict):
                    continue
                span = item.get("evidence_span")
                spans = item.get("evidence_spans")
                if isinstance(span, dict):
                    evidence_ends.append(int(span.get("end_ms", 0) or 0) / 1000.0)
                if isinstance(spans, list):
                    for inner in spans:
                        if isinstance(inner, dict):
                            evidence_ends.append(int(inner.get("end_ms", 0) or 0) / 1000.0)

    failures: list[str] = []
    warnings: list[str] = []

    audio_duration = streams.get("audio", {}).get("duration")
    video_duration = streams.get("video", {}).get("duration")
    if media.suffix.lower() in {".mp4", ".mov", ".mkv"}:
        if audio_duration is None:
            failures.append("video review media has no audio stream")
        if video_duration is None:
            failures.append("video review media has no video stream")
        if audio_duration is not None and video_duration is not None:
            delta = abs(video_duration - audio_duration)
            if delta > args.max_stream_delta_sec:
                failures.append(
                    "audio/video stream duration delta "
                    f"{delta:.3f}s exceeds {args.max_stream_delta_sec:.3f}s"
                )
        if audio_duration is not None and video_duration is not None and not capture_timeline:
            warnings.append(
                "capture_timeline.json is missing; duration equality alone cannot prove audio/video source-window sync"
            )

    if metadata_duration is not None and playable_duration is not None:
        delta = abs(metadata_duration - playable_duration)
        if delta > args.max_metadata_delta_sec:
            failures.append(
                "metadata duration delta from playable media "
                f"{delta:.3f}s exceeds {args.max_metadata_delta_sec:.3f}s"
            )

    marker_limit = min(
        value
        for value in (audio_duration, video_duration, playable_duration)
        if value is not None
    ) if any(value is not None for value in (audio_duration, video_duration, playable_duration)) else None
    if marker_limit is not None:
        last_transcript = max(transcript_ends, default=0)
        last_minute = max((t for t in minute_timestamps if t is not None), default=0)
        last_evidence = max(evidence_ends, default=0)
        for label, value in (
            ("last transcript end", last_transcript),
            ("last Smart Minutes timestamp", last_minute),
            ("last evidence span end", last_evidence),
        ):
            if value > marker_limit + 1.0:
                failures.append(f"{label} {value:.3f}s exceeds shortest playable stream {marker_limit:.3f}s")

    if transcript_starts and transcript_starts[0] > 5:
        warnings.append(
            f"first transcript marker starts at {transcript_starts[0]:.3f}s; "
            "verify whether early real audio/video content is intentionally untranscribed"
        )

    capture_source_report, source_warnings, source_failures = inspect_capture_sources(
        capture_timeline,
        args.ffprobe,
        playable_duration,
        args.max_source_stream_delta_sec,
        args.max_source_final_delta_sec,
    )
    warnings.extend(source_warnings)
    failures.extend(source_failures)

    report = {
        "record": str(record),
        "media": str(media),
        "metadata_duration_sec": metadata_duration,
        "format_duration_sec": format_duration,
        "audio_duration_sec": audio_duration,
        "video_duration_sec": video_duration,
        "capture_timeline": summarize_capture_timeline(capture_timeline),
        "capture_sources": capture_source_report,
        "transcript_segments": len(transcript) if isinstance(transcript, list) else 0,
        "first_transcript_start_sec": min(transcript_starts) if transcript_starts else None,
        "last_transcript_end_sec": max(transcript_ends) if transcript_ends else None,
        "smart_minutes_timestamps_sec": [t for t in minute_timestamps if t is not None],
        "warnings": warnings,
        "failures": failures,
    }
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 1 if failures else 0


def summarize_capture_timeline(value: Any) -> dict[str, Any] | None:
    if not isinstance(value, dict) or not value:
        return None
    composition = value.get("compositionTimeline")
    if not isinstance(composition, dict):
        composition = {}
    pause_intervals = value.get("pauseIntervals")
    if not isinstance(pause_intervals, list):
        pause_intervals = []
    normalized_pause_intervals: list[dict[str, float | None]] = []
    total_pause_duration = 0.0
    for interval in pause_intervals:
        if not isinstance(interval, dict):
            continue
        start = to_float(interval.get("startSec"))
        end = to_float(interval.get("endSec"))
        duration = None
        if start is not None and end is not None:
            duration = max(0.0, end - start)
            total_pause_duration += duration
        normalized_pause_intervals.append({
            "start_sec": start,
            "end_sec": end,
            "duration_sec": duration,
        })
    return {
        "video_start_sec": to_float(value.get("videoStartSec")),
        "audio_start_sec": to_float(value.get("audioStartSec")),
        "pause_interval_count": len(normalized_pause_intervals),
        "pause_duration_sec": total_pause_duration,
        "pause_intervals": normalized_pause_intervals,
        "current_pause_start_sec": to_float(value.get("currentPauseStartSec")),
        "composition_video_start_sec": to_float(composition.get("videoStartSec")),
        "composition_audio_start_sec": to_float(composition.get("audioStartSec")),
        "video_path": value.get("videoPath"),
        "audio_path": value.get("audioPath"),
        "output_path": value.get("outputPath"),
    }


if __name__ == "__main__":
    raise SystemExit(main())
