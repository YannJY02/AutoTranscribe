import json
import subprocess
import sys
from pathlib import Path
from unittest import mock

from scripts import evaluate_local_smart_minutes as local_eval
from scripts.evaluate_local_smart_minutes import evaluate_fixture


ROOT = Path(__file__).resolve().parents[1]


def test_local_smart_minutes_eval_reports_quality_dimensions_without_release_gate():
    report = evaluate_fixture()

    assert report["fixture"]["privacy_safe"] is True
    assert report["build"] == {
        "provider": "local",
        "model": "extractive-v1",
        "schema": "insight_package_v1",
    }
    assert report["comparison_contract"] == "GH-50"
    assert set(report["contract_comparison"]) == set(report["metrics"])
    assert all(row["observed"] is not None for row in report["contract_comparison"].values())
    assert all(row["expected_condition"] for row in report["contract_comparison"].values())
    assert all(row["outcome"] is True for row in report["contract_comparison"].values())
    assert all(row["release_threshold"] is None for row in report["contract_comparison"].values())
    assert report["release_gate"] is False
    assert set(report["metrics"]) == {
        "completeness",
        "evidence_linkage",
        "latency_ms",
        "failure_behavior",
    }
    assert report["metrics"]["completeness"]["present_modules"] == 7
    assert report["metrics"]["evidence_linkage"] == {
        "linked_items": 10,
        "evidenced_items": 10,
        "ratio": 1.0,
        "semantics": {
            "speaker_perspectives": "each perspective must have at least one valid span and no invalid spans",
            "timeline_beats": "timestamp is a direct media-timeline link",
        },
    }


def test_local_smart_minutes_eval_runs_as_a_script():
    completed = subprocess.run(
        [sys.executable, "scripts/evaluate_local_smart_minutes.py"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )

    assert json.loads(completed.stdout)["build"]["provider"] == "local"


def test_local_smart_minutes_eval_rejects_perspective_without_evidence():
    attach = local_eval.attach_transcript_provenance

    def drop_perspective_evidence(package, meeting_id):
        enriched = attach(package, meeting_id)
        enriched["speaker_perspectives"][0]["evidence_spans"] = []
        return enriched

    with mock.patch.object(local_eval, "attach_transcript_provenance", side_effect=drop_perspective_evidence):
        report = local_eval.evaluate_fixture()

    assert report["metrics"]["evidence_linkage"]["linked_items"] == 9
    assert report["metrics"]["evidence_linkage"]["evidenced_items"] == 10
    assert report["contract_comparison"]["evidence_linkage"]["outcome"] is False


def test_local_smart_minutes_eval_rejects_evidence_outside_fixture_timeline():
    attach = local_eval.attach_transcript_provenance

    def move_evidence_outside_fixture(package, meeting_id):
        enriched = attach(package, meeting_id)
        enriched["speaker_perspectives"][0]["evidence_spans"][0] = {
            "start_ms": 999_000,
            "end_ms": 1_000_000,
        }
        enriched["timeline_beats"][0]["timestamp"] = "99:99"
        return enriched

    with mock.patch.object(local_eval, "attach_transcript_provenance", side_effect=move_evidence_outside_fixture):
        report = local_eval.evaluate_fixture()

    assert report["metrics"]["evidence_linkage"]["linked_items"] == 8
    assert report["metrics"]["evidence_linkage"]["evidenced_items"] == 10
    assert report["contract_comparison"]["evidence_linkage"]["outcome"] is False
