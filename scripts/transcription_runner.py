"""Transcription job runner used by InsightKit sidecar."""

from __future__ import annotations

import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

import os

try:
    from scripts.transcriber import transcribe
except ModuleNotFoundError:
    from transcriber import transcribe

from insightkit.records.record_writer import RecordWriter, detect_media_type, detect_duration
from insightkit.insights.service import attach_transcript_provenance
from insightkit.phase_timing import Phase, phase

_DEFAULT_RECORDS_ROOT = str(Path.home() / "Documents" / "InsightKit" / "Records")

ProgressCallback = Callable[[int, str], None]


class JobCancelled(RuntimeError):
    pass


def run_transcription_job(
    *,
    file_path: str,
    meeting_id: str,
    store,
    insight_service,
    cancel_event: threading.Event | None = None,
    on_progress: ProgressCallback | None = None,
    provider_vendor: str | None = None,
    provider_model: str | None = None,
    strict_mode: bool | None = None,
) -> dict[str, Any]:
    """Run one file-based transcription pipeline into InsightKit store."""

    def check_cancel() -> None:
        if cancel_event is not None and cancel_event.is_set():
            raise JobCancelled("job cancelled")

    def progress(value: int, stage: str) -> None:
        if on_progress is not None:
            on_progress(max(0, min(100, value)), stage)

    src = Path(file_path).expanduser().resolve()
    if not src.exists() or not src.is_file():
        raise FileNotFoundError(str(src))

    check_cancel()
    progress(5, "starting")
    title = src.stem
    store.upsert_meeting(meeting_id, title, "file", status="processing")

    check_cancel()
    progress(25, "transcribing")
    with phase(Phase.TRANSCRIPTION):
        result = transcribe(src)
    segments = result.get("segments", [])

    check_cancel()
    progress(60, "persisting")
    transcript_rows: list[dict[str, Any]] = []
    with phase(Phase.PERSIST_SEGMENTS):
        for seg in segments:
            text = str(seg.get("text", "") or "").strip()
            if not text:
                continue
            start_ms = int(seg.get("start", 0) or 0)
            end_ms = int(seg.get("end", 0) or 0)
            if end_ms <= start_ms:
                end_ms = start_ms + 1200
            speaker = str(seg.get("speaker", "") or "")
            store.insert_segment(
                meeting_id=meeting_id,
                start_ms=start_ms,
                end_ms=end_ms,
                speaker=speaker,
                source="file",
                text=text,
                confidence=float(seg.get("confidence", 0.0) or 0.0),
            )
            transcript_rows.append(
                {
                    "start_ms": start_ms,
                    "end_ms": end_ms,
                    "speaker": speaker,
                    "source": "file",
                    "text": text,
                }
            )

    check_cancel()
    progress(82, "building_final")
    try:
        with phase(Phase.FINAL_GENERATION):
            package = insight_service.build_final(
                transcript_rows,
                provider_vendor=provider_vendor,
                provider_model=provider_model,
                strict_mode=strict_mode,
            )
    except Exception:
        with phase(Phase.FINAL_GENERATION_FALLBACK):
            package = insight_service.build_local_extractive(transcript_rows)
    with phase(Phase.PERSIST_FINAL):
        package = attach_transcript_provenance(package, meeting_id)
        call_meta = insight_service.last_call_meta
        store.upsert_insight_package(
            meeting_id,
            package,
            datetime.now(timezone.utc).isoformat(),
        )

    # ── Write record folder ───────────────────────────────────────────────
    records_root = os.getenv("INSIGHTKIT_RECORDS_ROOT", _DEFAULT_RECORDS_ROOT)
    media_type = detect_media_type(str(src))
    duration_sec = detect_duration(segs=transcript_rows)
    with phase(Phase.RECORD_WRITE):
        record_path = RecordWriter().write_record(
            root_dir=records_root,
            meeting_id=meeting_id,
            title=title,
            source_path=str(src),
            segments=transcript_rows,
            insight_package=package,
            media_type=media_type,
            record_source="imported",
            duration_sec=duration_sec,
            analysis_meta={
                "provider": str(call_meta.get("vendor", "")),
                "model": str(call_meta.get("model", "")),
                "strict_mode": bool(call_meta.get("strict_mode", False)),
                "source": "final",
            },
        )

    progress(100, "completed")
    store.update_meeting_status(meeting_id, "stopped")
    return {
        "meeting_id": meeting_id,
        "title": title,
        "source_path": str(src),
        "segments_count": len(transcript_rows),
        "insight_package": package,
        "record_path": str(record_path),
    }
