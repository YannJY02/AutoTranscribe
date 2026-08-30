#!/usr/bin/env python3
"""Run the privacy-safe, informational Smart Minutes parity evaluation."""

from __future__ import annotations

import json
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


def evaluate_fixture() -> dict[str, Any]:
    service = InsightService()
    started = time.perf_counter()
    package = attach_transcript_provenance(
        service.build_final(FIXTURE, provider_vendor="local"),
        "synthetic-staged-launch-v1",
    )
    latency_ms = round((time.perf_counter() - started) * 1000, 3)

    evidenced = [
        *package["highlight_insights"],
        *package["decision_ledger"],
        *package["action_tracks"],
    ]
    linked = sum(
        1 for item in evidenced
        if item.get("evidence_span", {}).get("end_ms", 0) > item.get("evidence_span", {}).get("start_ms", 0)
    )

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
            "evidenced_items": len(evidenced),
            "ratio": linked / len(evidenced) if evidenced else 1.0,
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
            "expected_condition": "every extracted highlight, decision, and action has a non-empty evidence span and the package has meeting-specific transcript provenance",
            "observed": metrics["evidence_linkage"],
            "outcome": linked == len(evidenced) and bool(package["provenance_links"]),
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
