"""Post-processing for insight payloads."""

from __future__ import annotations

import re
from typing import Any


ACTION_OWNER_FALLBACK = "待分配"


def _normalize_span(item: dict[str, Any], key: str = "evidence_span") -> dict[str, Any]:
    span = item.get(key) or {}
    start = int(span.get("start_ms", 0) or 0)
    end = int(span.get("end_ms", start) or start)
    if end < start:
        end = start
    item[key] = {"start_ms": start, "end_ms": end}
    return item



def _dedupe(items: list[dict[str, Any]], unique_key: str) -> list[dict[str, Any]]:
    seen: set[str] = set()
    out: list[dict[str, Any]] = []
    for item in items:
        value = str(item.get(unique_key, "")).strip()
        if not value:
            continue
        sig = value.lower()
        if sig in seen:
            continue
        seen.add(sig)
        out.append(item)
    return out


def _transcript_duration_seconds(full_transcript: list[dict[str, Any]] | None) -> float:
    if not full_transcript:
        return 0.0
    duration_ms = 0
    for row in full_transcript:
        try:
            end = int(row.get("end_ms", row.get("start_ms", 0)) or 0)
        except (TypeError, ValueError):
            continue
        duration_ms = max(duration_ms, end)
    return max(0.0, duration_ms / 1000.0)


def _parse_timestamp_seconds(value: str) -> tuple[int, int] | None:
    text = str(value or "").strip()
    if not re.fullmatch(r"\d{1,2}:\d{2}(?::\d{2})?", text):
        return None
    parts = [int(part) for part in text.split(":")]
    if len(parts) == 2:
        minutes, seconds = parts
        return minutes * 60 + seconds, seconds
    hours, minutes, seconds = parts
    return hours * 3600 + minutes * 60 + seconds, seconds


def _format_timestamp(seconds: float) -> str:
    total = max(0, int(seconds))
    hours = total // 3600
    minutes = (total % 3600) // 60
    secs = total % 60
    if hours:
        return f"{hours:02d}:{minutes:02d}:{secs:02d}"
    return f"{minutes:02d}:{secs:02d}"


def _normalize_timeline_timestamps(
    payload: dict[str, Any],
    full_transcript: list[dict[str, Any]] | None,
) -> None:
    duration = _transcript_duration_seconds(full_transcript)
    if duration <= 0:
        return
    for beat in payload.get("timeline_beats", []):
        parsed = _parse_timestamp_seconds(str(beat.get("timestamp", "")))
        if parsed is None:
            continue
        total, seconds_component = parsed
        if total <= duration + 1:
            continue
        if duration < 60 and seconds_component <= duration + 1:
            beat["timestamp"] = _format_timestamp(seconds_component)
        else:
            beat["timestamp"] = _format_timestamp(duration)



def postprocess_insight_package(
    payload: dict[str, Any],
    full_transcript: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    """Apply dedupe, span normalization and confidence tagging."""
    payload["highlight_insights"] = _dedupe(payload.get("highlight_insights", []), "quote")
    payload["decision_ledger"] = _dedupe(payload.get("decision_ledger", []), "decision")
    payload["action_tracks"] = _dedupe(payload.get("action_tracks", []), "task")

    for item in payload["highlight_insights"]:
        _normalize_span(item)

    for item in payload["decision_ledger"]:
        _normalize_span(item)
        if not item.get("owner"):
            item["needs_review"] = True

    for item in payload["action_tracks"]:
        _normalize_span(item)
        if not str(item.get("owner", "") or "").strip():
            item["owner"] = ACTION_OWNER_FALLBACK
            item["needs_review"] = True
        if not item.get("due_at"):
            item["needs_review"] = True

    for item in payload.get("speaker_perspectives", []):
        spans = item.get("evidence_spans") or []
        item["evidence_spans"] = [
            _normalize_span({"evidence_span": span})["evidence_span"] for span in spans
        ]

    _normalize_timeline_timestamps(payload, full_transcript)
    return payload
