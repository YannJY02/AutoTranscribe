"""Post-processing for insight payloads."""

from __future__ import annotations

from typing import Any


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



def postprocess_insight_package(payload: dict[str, Any]) -> dict[str, Any]:
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
        if not item.get("due_at"):
            item["needs_review"] = True

    for item in payload.get("speaker_perspectives", []):
        spans = item.get("evidence_spans") or []
        item["evidence_spans"] = [
            _normalize_span({"evidence_span": span})["evidence_span"] for span in spans
        ]

    return payload
