#!/usr/bin/env python3
"""Run the privacy-safe, informational Smart Minutes parity evaluation."""

from __future__ import annotations

import json
import re
import sys
import time
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from insightkit.insights.service import InsightService, attach_transcript_provenance


FIXTURE = [
    {"start_ms": 0, "end_ms": 3500, "speaker": "Speaker 1", "text": "We need to choose a privacy-safe launch plan."},
    {"start_ms": 3500, "end_ms": 7000, "speaker": "Speaker 2", "text": "We decided on a staged launch because rollback remains available."},
    {"start_ms": 7000, "end_ms": 10500, "speaker": "Speaker 1", "text": "Speaker 1 owns the checklist and will finish it by Friday."},
]

MODULES = (
    "session_overview",
    "highlight_insights",
    "speaker_perspectives",
    "decision_ledger",
    "action_tracks",
    "timeline_beats",
    "provenance_links",
)


def _timestamp_ms(value: Any) -> int | None:
    if not isinstance(value, str) or not re.fullmatch(r"\d{2}:\d{2}(?::\d{2})?", value):
        return None
    parts = [int(part) for part in value.split(":")]
    if parts[-1] >= 60 or (len(parts) == 3 and parts[-2] >= 60):
        return None
    return (parts[0] * 60 + parts[1]) * 1000 if len(parts) == 2 else (parts[0] * 3600 + parts[1] * 60 + parts[2]) * 1000


def evaluate_fixture() -> dict[str, Any]:
    service = InsightService()
    started = time.perf_counter()
    package = attach_transcript_provenance(
        service.build_final(FIXTURE, provider_vendor="local"),
        "synthetic-staged-launch-v1",
    )
    latency_ms = round((time.perf_counter() - started) * 1000, 3)

    item_spans = [
        item.get("evidence_span", {})
        for module in ("highlight_insights", "decision_ledger", "action_tracks")
        for item in package[module]
    ]
    perspective_spans = [perspective.get("evidence_spans", []) for perspective in package["speaker_perspectives"]]
    chapter_links = [item.get("timestamp") for item in package["timeline_beats"]]
    fixture_duration_ms = max(segment["end_ms"] for segment in FIXTURE)

    def span_is_linked(span: dict[str, Any]) -> bool:
        start_ms = span.get("start_ms")
        end_ms = span.get("end_ms")
        return isinstance(start_ms, (int, float)) and isinstance(end_ms, (int, float)) and 0 <= start_ms < end_ms <= fixture_duration_ms

    linked_spans = sum(
        1 for span in item_spans
        if span_is_linked(span)
    )
    linked_perspectives = sum(
        1 for spans in perspective_spans
        if spans and all(span_is_linked(span) for span in spans)
    )
    linked_chapters = sum(
        1 for timestamp in chapter_links
        if (timestamp_ms := _timestamp_ms(timestamp)) is not None and timestamp_ms <= fixture_duration_ms
    )
    linked = linked_spans + linked_perspectives + linked_chapters
    evidenced_items = len(item_spans) + len(perspective_spans) + len(chapter_links)

    try:
        empty = service.build_final([], provider_vendor="local")
        failure_behavior = {
            "empty_transcript": "canonical_reviewable_fallback",
            "schema_preserved": all(module in empty for module in MODULES),
        }
    except Exception as exc:  # pragma: no cover - reported, not promoted to a gate
        failure_behavior = {"empty_transcript": "error", "error_type": type(exc).__name__}

    metrics = {
        "completeness": {
            "present_modules": sum(module in package for module in MODULES),
            "total_modules": len(MODULES),
            "item_counts": {
                module: len(package[module]) if isinstance(package[module], list) else 1
                for module in MODULES
            },
        },
        "evidence_linkage": {
            "linked_items": linked,
            "evidenced_items": evidenced_items,
            "ratio": linked / evidenced_items if evidenced_items else 1.0,
            "semantics": {
                "speaker_perspectives": "each perspective must have at least one valid span and no invalid spans",
                "timeline_beats": "timestamp is a direct media-timeline link",
            },
        },
        "latency_ms": latency_ms,
        "failure_behavior": failure_behavior,
    }
    contract_comparison = {
        "completeness": {
            "gh_50_dimension": "canonical Smart Minutes module coverage",
            "expected_condition": "all 7 canonical modules are present",
            "observed": metrics["completeness"],
            "outcome": metrics["completeness"]["present_modules"] == len(MODULES),
            "release_threshold": None,
        },
        "evidence_linkage": {
            "gh_50_dimension": "generated items trace back to transcript evidence",
            "expected_condition": "every extracted highlight, speaker perspective, decision, and action has valid transcript evidence; every timeline beat has a media timestamp; and the package has meeting-specific transcript provenance",
            "observed": metrics["evidence_linkage"],
            "outcome": linked == evidenced_items and bool(package["provenance_links"]),
            "release_threshold": None,
        },
        "latency_ms": {
            "gh_50_dimension": "generation latency is measured on the declared fixture/build",
            "expected_condition": "latency is recorded as a non-negative duration for the declared fixture",
            "observed": latency_ms,
            "outcome": latency_ms >= 0,
            "release_threshold": None,
        },
        "failure_behavior": {
            "gh_50_dimension": "failure preserves a reviewable canonical result or reports an explicit error",
            "expected_condition": "empty input preserves the canonical schema as a reviewable fallback",
            "observed": failure_behavior,
            "outcome": failure_behavior.get("schema_preserved") is True,
            "release_threshold": None,
        },
    }
    return {
        "comparison_contract": "GH-50",
        "release_gate": False,
        "fixture": {
            "id": "synthetic-staged-launch-v1",
            "privacy_safe": True,
            "segments": len(FIXTURE),
        },
        "build": {
            "provider": "local",
            "model": "extractive-v1",
            "schema": "insight_package_v1",
        },
        "metrics": metrics,
        "contract_comparison": contract_comparison,
    }


if __name__ == "__main__":
    print(json.dumps(evaluate_fixture(), ensure_ascii=False, indent=2))
