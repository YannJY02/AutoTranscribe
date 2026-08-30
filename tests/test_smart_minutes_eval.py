import json
import math
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
    bounded = next(case for case in report["cases"] if case["case"] == "insufficient-transcript")
    assert bounded["diagnostics"]["bounded_failure_observation"] == {
        "generated_decisions": 1,
        "generated_actions": 1,
        "all_generated_claims_need_review": True,
    }


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


def test_generated_evidence_without_any_source_fails_linkage_gate():
    case = {"id": "empty-source", "expected_behavior": "bounded_failure", "transcript": []}

    result = evaluate_package(case, _valid_package(case), latency_ms=1.0)

    failure = next(item for item in result["failures"] if item["metric"] == "source_evidence_linkage")
    assert failure["expected_contract"] == "every generated evidence span overlaps a source transcript segment"
    assert failure["actual_observation"] == "highlight_insights[0] span 0-1000 has no source overlap"
    assert failure["evidence_reference"] == "output.highlight_insights[0].evidence_span"


def test_malformed_evidence_bounds_produce_structured_linkage_failure():
    case = {
        "id": "malformed-evidence",
        "expected_behavior": "success",
        "transcript": [{"start_ms": 0, "end_ms": 1000, "speaker": "A", "text": "Synthetic"}],
    }
    package = _valid_package(case)
    package["highlight_insights"][0]["evidence_span"]["start_ms"] = "not-a-number"

    result = evaluate_package(case, package, latency_ms=1.0)

    failure = next(item for item in result["failures"] if item["metric"] == "source_evidence_linkage")
    assert failure["actual_observation"] == "highlight_insights[0] span not-a-number-1000 has invalid bounds or no source overlap"
    assert failure["evidence_reference"] == "output.highlight_insights[0].evidence_span"


def test_non_mapping_evidence_span_produces_structured_linkage_failure():
    case = {
        "id": "non-mapping-evidence",
        "expected_behavior": "success",
        "transcript": [{"start_ms": 0, "end_ms": 1000, "speaker": "A", "text": "Synthetic"}],
    }
    package = _valid_package(case)
    package["highlight_insights"][0]["evidence_span"] = "bad"

    result = evaluate_package(case, package, latency_ms=1.0)

    failure = next(item for item in result["failures"] if item["metric"] == "source_evidence_linkage")
    assert failure["actual_observation"] == "highlight_insights[0] span None-None has invalid bounds or no source overlap"
    assert failure["evidence_reference"] == "output.highlight_insights[0].evidence_span"


def test_non_list_schema_section_returns_structured_schema_failure():
    case = {"id": "bad-section", "expected_behavior": "success", "transcript": []}
    package = _valid_package(case)
    package["highlight_insights"] = 1

    result = evaluate_package(case, package, latency_ms=1.0)

    assert result["gate_result"] == "fail"
    assert result["failures"] == [{
        "case": "bad-section",
        "metric": "schema",
        "expected_contract": "valid InsightPackageV1",
        "actual_observation": "SchemaValidationError",
        "evidence_reference": "output",
    }]


def test_reversed_evidence_bounds_produce_structured_linkage_failure():
    case = {
        "id": "reversed-evidence",
        "expected_behavior": "success",
        "transcript": [{"start_ms": 0, "end_ms": 1000, "speaker": "A", "text": "Synthetic"}],
    }
    package = _valid_package(case)
    package["highlight_insights"][0]["evidence_span"] = {"start_ms": 900, "end_ms": 100}

    result = evaluate_package(case, package, latency_ms=1.0)

    failure = next(item for item in result["failures"] if item["metric"] == "source_evidence_linkage")
    assert failure["actual_observation"] == "highlight_insights[0] span 900-100 has invalid bounds or no source overlap"


def test_negative_or_missing_evidence_bounds_produce_structured_linkage_failures():
    case = {
        "id": "incomplete-evidence",
        "expected_behavior": "success",
        "transcript": [{"start_ms": 0, "end_ms": 1000, "speaker": "A", "text": "Synthetic"}],
    }

    for span in ({"start_ms": -1, "end_ms": 100}, {"end_ms": 100}):
        package = _valid_package(case)
        package["highlight_insights"][0]["evidence_span"] = span

        result = evaluate_package(case, package, latency_ms=1.0)

        failure = next(item for item in result["failures"] if item["metric"] == "source_evidence_linkage")
        assert "has invalid bounds or no source overlap" in failure["actual_observation"]


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
    assert report["legs"]["external"]["implementation_version"] == f"{bad_external.__module__}:{bad_external.__qualname__}"
    markdown = (tmp_path / "smart-minutes-eval.md").read_text(encoding="utf-8")
    assert "test-cloud" in markdown
    assert "source_evidence_linkage" in markdown
    external_markdown = markdown.split("## External cases", 1)[1]
    assert "latency" in external_markdown
    assert "module counts:" in external_markdown
    assert "decision/action fidelity:" in external_markdown
    assert "forbidden claims observed:" in external_markdown


def test_custom_external_builder_identity_survives_missing_credentials(tmp_path: Path):
    def missing_credentials(_case):
        raise RuntimeError("missing API key")

    report = run_eval(
        ROOT / "evals/smart_minutes/v1",
        tmp_path,
        external={"vendor": "test-cloud", "model": "test-v1", "builder": missing_credentials},
    )

    assert report["legs"]["external"]["status"] == "unobserved"
    assert report["legs"]["external"]["implementation_version"] == (
        f"{missing_credentials.__module__}:{missing_credentials.__qualname__}"
    )


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
    assert report["legs"]["semantic"] == {
        "status": "observed",
        "adapter": f"{semantic.__module__}:{semantic.__qualname__}",
    }
    markdown = (tmp_path / "smart-minutes-eval.md").read_text(encoding="utf-8")
    assert "Semantic adapter:" in markdown
    assert "module counts:" in markdown
    assert "decision/action fidelity:" in markdown
    assert "forbidden claims observed:" in markdown
    assert "semantic diagnostics:" in markdown


def test_semantic_adapter_failure_is_explicit_without_becoming_an_accepted_gate(tmp_path: Path):
    def broken_semantic(_payload):
        raise RuntimeError("private provider payload")

    report = run_eval(
        ROOT / "evals/smart_minutes/v1",
        tmp_path,
        semantic_adapter=broken_semantic,
    )

    assert report["gate_result"] == "pass"
    assert report["legs"]["semantic"] == {
        "status": "failed",
        "adapter": f"{broken_semantic.__module__}:{broken_semantic.__qualname__}",
        "missing_prerequisite": "configured semantic adapter failed without payload capture",
        "failures": [
            {
                "case": case_id,
                "metric": "semantic_evaluation",
                "expected_contract": "configured semantic adapter returns bounded rubric diagnostics",
                "actual_observation": "semantic adapter raised RuntimeError",
                "evidence_reference": "semantic.local.execution",
            }
            for case_id in (
                "zh-release-decision",
                "en-launch-plan",
                "mixed-design-review",
                "insufficient-transcript",
            )
        ],
    }
    markdown = (tmp_path / "smart-minutes-eval.md").read_text(encoding="utf-8")
    assert "Semantic evaluation: failed" in markdown
    assert "configured semantic adapter failed without payload capture" in markdown


def test_invalid_semantic_adapter_result_is_explicit_and_report_json_is_strict(tmp_path: Path):
    report = run_eval(
        ROOT / "evals/smart_minutes/v1",
        tmp_path,
        semantic_adapter=lambda _payload: {"completeness": 0.5, "hallucination": math.nan},
    )

    semantic = report["legs"]["semantic"]
    assert semantic["status"] == "failed"
    assert semantic["missing_prerequisite"] == "configured semantic adapter returned no valid diagnostics"
    assert semantic["failures"][0] == {
        "case": "zh-release-decision",
        "metric": "semantic_evaluation",
        "expected_contract": "configured semantic adapter returns bounded rubric diagnostics",
        "actual_observation": "semantic adapter returned no valid diagnostics",
        "evidence_reference": "semantic.local.result",
    }
    json.loads(
        (tmp_path / "smart-minutes-eval.json").read_text(encoding="utf-8"),
        parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)),
    )


def test_semantic_adapter_value_error_is_an_execution_failure(tmp_path: Path):
    def broken_semantic(_payload):
        raise ValueError("private provider payload")

    report = run_eval(
        ROOT / "evals/smart_minutes/v1",
        tmp_path,
        semantic_adapter=broken_semantic,
    )

    semantic = report["legs"]["semantic"]
    assert semantic["status"] == "failed"
    assert semantic["missing_prerequisite"] == "configured semantic adapter failed without payload capture"
    assert semantic["failures"][0]["actual_observation"] == "semantic adapter raised ValueError"


def test_semantic_adapter_load_failure_still_emits_explicit_reports(tmp_path: Path):
    report = run_eval(
        ROOT / "evals/smart_minutes/v1",
        tmp_path,
        semantic_adapter="synthetic_missing_eval_adapter:evaluate",
    )

    assert report["gate_result"] == "pass"
    assert report["legs"]["semantic"] == {
        "status": "failed",
        "missing_prerequisite": "configured semantic adapter could not be loaded",
        "failures": [{
            "case": "<configuration>",
            "metric": "semantic_evaluation",
            "expected_contract": "configured semantic adapter can be loaded",
            "actual_observation": "semantic adapter could not be loaded",
            "evidence_reference": "semantic.configuration",
        }],
    }
    assert json.loads((tmp_path / "smart-minutes-eval.json").read_text(encoding="utf-8"))["legs"]["semantic"] == report["legs"]["semantic"]
    assert "configured semantic adapter could not be loaded" in (tmp_path / "smart-minutes-eval.md").read_text(encoding="utf-8")


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
    contract = load_eval_contract(ROOT / "evals/smart_minutes/v1")
    assert [case["case"] for case in external["cases"]] == [case["id"] for case in contract["cases"]]
    assert all(case["gate_result"] == "fail" for case in external["cases"])
    failure = external["cases"][0]["failures"][0]
    assert failure["metric"] == "failure_behavior"
    serialized = (tmp_path / "smart-minutes-eval.json").read_text(encoding="utf-8")
    assert "/Users/private" not in serialized
    assert "sk-secret" not in serialized


def test_external_named_error_satisfies_bounded_failure_contract(tmp_path: Path):
    import scripts.smart_minutes_eval as eval_module

    def bounded_builder(case):
        if case["expected_behavior"] == "bounded_failure":
            raise eval_module.BoundedFailureError("private provider payload /Users/private sk-secret-value")
        return _valid_package(case)

    report = run_eval(
        ROOT / "evals/smart_minutes/v1",
        tmp_path,
        external={"vendor": "test-cloud", "model": "bounded-v1", "builder": bounded_builder},
    )

    external = report["legs"]["external"]
    bounded = next(case for case in external["cases"] if case["case"] == "insufficient-transcript")
    assert report["gate_result"] == "pass"
    assert external["gate_result"] == "pass"
    assert bounded == {
        "case": "insufficient-transcript",
        "gate_result": "pass",
        "failures": [],
        "diagnostics": {
            "latency_ms": bounded["diagnostics"]["latency_ms"],
            "bounded_failure_observation": {"named_error": "BoundedFailureError"},
        },
    }
    serialized = (tmp_path / "smart-minutes-eval.json").read_text(encoding="utf-8")
    assert "/Users/private" not in serialized
    assert "sk-secret" not in serialized
    markdown = (tmp_path / "smart-minutes-eval.md").read_text(encoding="utf-8")
    assert "bounded failure:" in markdown
    assert '"named_error": "BoundedFailureError"' in markdown


def test_arbitrary_external_error_does_not_satisfy_bounded_failure_contract(tmp_path: Path):
    def broken_builder(case):
        if case["expected_behavior"] == "bounded_failure":
            raise TimeoutError("private network failure")
        return _valid_package(case)

    report = run_eval(
        ROOT / "evals/smart_minutes/v1",
        tmp_path,
        external={"vendor": "test-cloud", "model": "broken-v1", "builder": broken_builder},
    )

    bounded = next(
        case for case in report["legs"]["external"]["cases"]
        if case["case"] == "insufficient-transcript"
    )
    assert report["gate_result"] == "fail"
    assert bounded["gate_result"] == "fail"
    assert bounded["failures"][0]["actual_observation"] == "external baseline raised TimeoutError"


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
