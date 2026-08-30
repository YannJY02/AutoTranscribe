import json
import subprocess
import sys
from pathlib import Path

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
    assert report["metrics"]["evidence_linkage"]["linked_items"] > 0


def test_local_smart_minutes_eval_runs_as_a_script():
    completed = subprocess.run(
        [sys.executable, "scripts/evaluate_local_smart_minutes.py"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )

    assert json.loads(completed.stdout)["build"]["provider"] == "local"
