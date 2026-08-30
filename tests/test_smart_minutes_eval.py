import json
import subprocess
from pathlib import Path

from scripts.smart_minutes_eval import evaluate_package, load_eval_contract, run_eval


ROOT = Path(__file__).resolve().parents[1]


def test_versioned_contract_is_synthetic_multilingual_and_complete():
    contract = load_eval_contract(ROOT / "evals/smart_minutes/v1")

    assert contract["dataset_version"] == "smart-minutes-v1"
    assert len(contract["dataset_sha256"]) == 64
    assert {case["language"] for case in contract["cases"]} == {"zh", "en", "mixed"}
    assert {case["expected_behavior"] for case in contract["cases"]} == {"success", "bounded_failure"}
    assert all(case["safety"]["synthetic"] is True for case in contract["cases"])
    assert {metric["id"] for metric in contract["rubric"]["metrics"]} == {
        "completeness",
        "source_evidence_linkage",
        "decision_action_fidelity",
        "hallucination",
        "latency",
        "failure_behavior",
    }


def test_local_run_is_reproducible_and_external_leg_is_unknown(tmp_path: Path):
    report = run_eval(
        dataset_dir=ROOT / "evals/smart_minutes/v1",
        output_dir=tmp_path,
        external=None,
    )

    assert report["dataset"]["version"] == "smart-minutes-v1"
    assert report["gate_result"] == "pass"
    assert report["legs"]["local"]["status"] == "observed"
    assert report["legs"]["external"]["status"] == "unobserved"
    assert "explicit adapter configuration" in report["legs"]["external"]["missing_prerequisite"]
    assert (tmp_path / "smart-minutes-eval.json").exists()
    assert (tmp_path / "smart-minutes-eval.md").exists()

    machine = json.loads((tmp_path / "smart-minutes-eval.json").read_text(encoding="utf-8"))
    assert machine["dataset"]["sha256"] == report["dataset"]["sha256"]
    assert "Unobserved" in (tmp_path / "smart-minutes-eval.md").read_text(encoding="utf-8")


def test_cli_runs_from_clean_checkout_without_credentials(tmp_path: Path):
    completed = subprocess.run(
        ["python3.11", "scripts/smart_minutes_eval.py", "--output-dir", str(tmp_path)],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )

    assert completed.returncode == 0, completed.stderr
    assert json.loads(completed.stdout)["gate_result"] == "pass"


def test_gate_failure_names_contract_actual_and_evidence_reference():
    case = {
        "id": "bad-evidence",
        "expected_behavior": "success",
        "transcript": [{"start_ms": 1000, "end_ms": 2000, "speaker": "A", "text": "Ship Friday"}],
    }
    package = {
        "session_overview": {"title": "x", "overview": "x", "topics": []},
        "highlight_insights": [{
            "quote": "invented",
            "reason": "x",
            "speaker": "A",
            "evidence_span": {"start_ms": 9000, "end_ms": 10000},
        }],
        "speaker_perspectives": [],
        "decision_ledger": [],
        "action_tracks": [],
        "timeline_beats": [{"timestamp": "00:01", "title": "x", "summary": "x"}],
        "provenance_links": [],
    }

    result = evaluate_package(case, package, latency_ms=1.0)

    failure = next(item for item in result["failures"] if item["metric"] == "source_evidence_linkage")
    assert failure == {
        "case": "bad-evidence",
        "metric": "source_evidence_linkage",
        "expected_contract": "every generated evidence span overlaps a source transcript segment",
        "actual_observation": "highlight_insights[0] span 9000-10000 has no source overlap",
        "evidence_reference": "output.highlight_insights[0].evidence_span",
    }


def test_schema_failure_does_not_capture_rejected_provider_content():
    case = {"id": "invalid-schema", "expected_behavior": "success", "transcript": []}
    package = {"private": "/Users/private sk-secret-value"}

    result = evaluate_package(case, package, latency_ms=1.0)

    serialized = json.dumps(result)
    assert result["failures"][0]["actual_observation"] == "SchemaValidationError"
    assert "/Users/private" not in serialized
    assert "sk-secret" not in serialized


def test_speaker_perspective_evidence_must_overlap_source():
    case = {
        "id": "bad-perspective-evidence",
        "expected_behavior": "success",
        "transcript": [{"start_ms": 1000, "end_ms": 2000, "speaker": "A", "text": "Synthetic"}],
    }
    package = _valid_package(case)
    package["speaker_perspectives"] = [{
        "speaker": "A",
        "viewpoints": ["Synthetic"],
        "evidence_spans": [{"start_ms": 9000, "end_ms": 10000}],
    }]

    result = evaluate_package(case, package, latency_ms=1.0)

    failure = next(item for item in result["failures"] if item["metric"] == "source_evidence_linkage")
    assert failure["evidence_reference"] == "output.speaker_perspectives[0].evidence_spans[0]"


def test_fidelity_diagnostic_names_matched_and_missing_reference_claims():
    contract = load_eval_contract(ROOT / "evals/smart_minutes/v1")
    case = next(item for item in contract["cases"] if item["id"] == "en-launch-plan")
    from insightkit.insights.service import InsightService

    result = evaluate_package(case, InsightService().build_local_extractive(case["transcript"]), 1.0)

    fidelity = result["diagnostics"]["decision_action_fidelity"]
    assert fidelity["decisions"]["matched"] == ["keep the pilot offline"]
    assert fidelity["actions"]["matched"] == ["Blair owns the checklist"]
    assert fidelity["decisions"]["missing"] == []


def test_external_gate_failure_fails_global_report_and_is_rendered(tmp_path: Path):
    def bad_external(_case):
        package = _valid_package()
        package["highlight_insights"][0]["evidence_span"] = {"start_ms": 90000, "end_ms": 91000}
        return package

    report = run_eval(
        ROOT / "evals/smart_minutes/v1",
        tmp_path,
        external={"vendor": "test-cloud", "model": "bad-v1", "builder": bad_external},
    )

    assert report["gate_result"] == "fail"
    assert report["legs"]["external"]["status"] == "observed"
    assert report["legs"]["external"]["gate_result"] == "fail"
    assert report["legs"]["external"]["implementation_version"] == "InsightService.build_final"
    markdown = (tmp_path / "smart-minutes-eval.md").read_text(encoding="utf-8")
    assert "test-cloud" in markdown
    assert "source_evidence_linkage" in markdown


def test_semantic_adapter_receives_local_and_external_outputs_and_is_bounded(tmp_path: Path):
    observed_legs = []

    def semantic(payload):
        observed_legs.append(payload["leg"])
        return {"completeness": 0.5, "private_payload": "sk-secret-that-must-not-be-written"}

    report = run_eval(
        ROOT / "evals/smart_minutes/v1",
        tmp_path,
        external={"vendor": "test-cloud", "model": "ok-v1", "builder": lambda case: _valid_package(case)},
        semantic_adapter=semantic,
    )

    assert set(observed_legs) == {"local", "external"}
    serialized = (tmp_path / "smart-minutes-eval.json").read_text(encoding="utf-8")
    assert "private_payload" not in serialized
    assert "sk-secret" not in serialized
    assert report["cases"][0]["diagnostics"]["semantic_adapter"] == {"completeness": 0.5}


def test_external_runtime_failure_is_named_without_raw_exception_content(tmp_path: Path):
    def broken(_case):
        raise RuntimeError("provider payload /Users/private sk-secret-value")

    report = run_eval(
        ROOT / "evals/smart_minutes/v1",
        tmp_path,
        external={"vendor": "test-cloud", "model": "broken-v1", "builder": broken},
    )

    external = report["legs"]["external"]
    assert external["status"] == "observed"
    assert external["gate_result"] == "fail"
    failure = external["cases"][0]["failures"][0]
    assert failure["metric"] == "failure_behavior"
    serialized = (tmp_path / "smart-minutes-eval.json").read_text(encoding="utf-8")
    assert "/Users/private" not in serialized
    assert "sk-secret" not in serialized


def test_external_leg_records_resolved_provider_and_model(monkeypatch, tmp_path: Path):
    from insightkit.insights.service import InsightService as RealInsightService
    import scripts.smart_minutes_eval as eval_module

    class ResolvingService:
        def __init__(self, **_kwargs):
            self.local = RealInsightService()
            self.last_call_meta = {}

        def build_local_extractive(self, transcript):
            return self.local.build_local_extractive(transcript)

        def build_final(self, transcript):
            self.last_call_meta = {"vendor": "resolved-cloud", "model": "resolved-model-v2"}
            return _valid_package({"transcript": transcript})

    monkeypatch.setattr(eval_module, "InsightService", ResolvingService)

    report = run_eval(
        ROOT / "evals/smart_minutes/v1",
        tmp_path,
        external={"vendor": "configured-cloud", "model": ""},
    )

    assert report["legs"]["external"]["provider"] == "resolved-cloud"
    assert report["legs"]["external"]["model"] == "resolved-model-v2"


def _valid_package(case=None):
    transcript = (case or {}).get("transcript") or [{"start_ms": 0, "end_ms": 1000}]
    row = transcript[0] if transcript else {"start_ms": 0, "end_ms": 0}
    span = {"start_ms": row["start_ms"], "end_ms": row["end_ms"]}
    return {
        "session_overview": {"title": "Synthetic", "overview": "Synthetic", "topics": []},
        "highlight_insights": [{"quote": "Synthetic", "reason": "Synthetic", "speaker": "A", "evidence_span": span}],
        "speaker_perspectives": [],
        "decision_ledger": [{"problem": "Synthetic", "options": [], "decision": "Synthetic", "rationale": "Synthetic", "owner": "A", "needs_review": True, "evidence_span": span}],
        "action_tracks": [{"task": "Synthetic", "owner": "A", "due_at": "", "priority": "medium", "status": "open", "needs_review": True, "evidence_span": span}],
        "timeline_beats": [{"timestamp": "00:00", "title": "Synthetic", "summary": "Synthetic"}],
        "provenance_links": [],
    }
