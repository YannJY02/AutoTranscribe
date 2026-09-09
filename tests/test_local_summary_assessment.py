"""Regression coverage for false fidelity conclusions in the local summary screen."""

from __future__ import annotations

import copy
import json

import pytest

from scripts import local_summary_assessment as assessment


@pytest.fixture
def cases():
    return assessment.load_contract()["cases"]


def empty_package():
    return {
        "session_overview": {"title": "Synthetic fixture", "overview": "Brief synthetic input.", "topics": []},
        "highlight_insights": [], "speaker_perspectives": [], "decision_ledger": [],
        "action_tracks": [], "timeline_beats": [], "provenance_links": [],
    }


def action(owner, due_at, start=14_000, end=28_000):
    return {"task": "Prepare risk list", "owner": owner, "due_at": due_at,
            "priority": "medium", "status": "draft", "evidence_span": {"start_ms": start, "end_ms": end}}


def test_contract_reuses_all_legacy_rows_and_only_complete_visible_prefixes(cases):
    legacy = json.loads((assessment.ROOT / "evals/smart_minutes/v1/dataset.json").read_text())
    assert len(cases) == 8
    for case, original in zip(cases[:4], legacy["cases"]):
        assert case["transcript"] == original["transcript"]
        assert case["source"]["sha256"]
    assert [case["visible_end_ms"] for case in cases[4:]] == [28_000, 64_000, 110_000, 110_000]
    assert cases[4]["transcript"] == cases[5]["transcript"][:2]
    assert cases[5]["transcript"] == cases[6]["transcript"][:4]
    assert cases[6]["transcript"] == cases[7]["transcript"]
    assert "Ren" not in json.dumps(cases[4]["transcript"])


def test_changed_source_cannot_silently_redefine_frozen_reference(tmp_path, monkeypatch):
    dataset = assessment.DEFAULT_DATASET
    source = tmp_path / "evals/smart_minutes/v1/dataset.json"
    source.parent.mkdir(parents=True)
    source.write_bytes((assessment.ROOT / source.relative_to(tmp_path)).read_bytes() + b"\n")
    monkeypatch.setattr(assessment, "ROOT", tmp_path)
    with pytest.raises(ValueError, match="SHA256 changed"):
        assessment.load_contract(dataset)


@pytest.mark.parametrize("corruption", ["skip_segment", "future_checkpoint", "partial_final"])
def test_fixture_rejects_future_or_nonprefix_evidence(tmp_path, corruption):
    dataset = json.loads(assessment.DEFAULT_DATASET.read_text())
    if corruption == "skip_segment":
        dataset["cases"][4]["stable_segment_ids"][1] = "bilingual-plan-correction:s03"
    elif corruption == "future_checkpoint":
        dataset["cases"][4]["expectations"]["facts"][0]["source_segment_ids"] = ["bilingual-plan-correction:s06"]
    else:
        dataset["cases"][7]["stable_segment_ids"].pop()
    path = tmp_path / "dataset.json"
    path.write_text(json.dumps(dataset))
    with pytest.raises(ValueError):
        assessment.load_contract(path)


def test_decision_in_overview_does_not_count_as_ledger_evidence(cases):
    package = empty_package()
    package["session_overview"]["overview"] = "We decided to keep the pilot offline because the sample data is synthetic."
    review = assessment.make_review_template(cases[1], package, stage="raw")
    decision = next(row for row in review["checkpoints"] if row["id"] == "decision")
    assert decision["required"] is True
    assert decision["observed_fields"] == []
    assert decision["verdict"] is None
    report = assessment.assess_payload(cases[1], package, stage="raw")
    assert report["semantic_status"] == "not_reviewed"
    assert report["semantic_pass"] is None


def test_unknown_owner_and_deadline_cannot_be_filled_from_speaker_or_clock(cases):
    package = empty_package()
    package["action_tracks"] = [action("Mei", "2026-09-11")]
    result = assessment.assess_payload(cases[4], package, stage="raw")
    assert result["schema"]["status"] == "pass"
    assert result["field_domains"]["status"] == "requires_review"
    assert {issue["path"] for issue in result["field_domains"]["issues"]} == {
        "action_tracks[0].owner", "action_tracks[0].due_at",
    }
    assert result["semantic_pass"] is None


def test_assignment_to_wrong_task_is_not_auto_approved_by_allowed_owner(cases):
    package = empty_package()
    # Mei/Friday are valid only for the checklist, not this unassigned risk list.
    package["action_tracks"] = [action("Mei", "Friday")]
    result = assessment.assess_payload(cases[5], package, stage="raw")
    assert result["field_domains"]["status"] == "within_literal_domains"
    assert result["semantic_pass"] is None
    review = assessment.make_review_template(cases[5], package, stage="raw")
    row = next(row for row in review["checkpoints"] if row["id"] == "risk-list-unknowns")
    assert row["verdict"] is None
    assert {value["path"] for value in row["observed_fields"]} == {
        "action_tracks[0].task", "action_tracks[0].owner", "action_tracks[0].due_at",
    }


def test_stale_current_values_flagged_but_corrected_history_needs_semantic_review(cases):
    package = empty_package()
    package["timeline_beats"] = [{"timestamp": "01:08", "title": "Correction", "summary": "Mei and Friday were superseded by Ren and Monday."}]
    package["action_tracks"] = [action("Ren", "Monday", 89_000, 110_000)]
    result = assessment.assess_payload(cases[7], package, stage="raw")
    assert result["field_domains"]["status"] == "within_literal_domains"
    package["action_tracks"][0].update(owner="Mei", due_at="Friday")
    result = assessment.assess_payload(cases[7], package, stage="raw")
    assert {issue["path"] for issue in result["field_domains"]["issues"]} == {
        "action_tracks[0].owner", "action_tracks[0].due_at",
    }


def test_raw_range_failure_survives_product_repair_and_input_mutation(cases):
    raw = empty_package()
    raw["highlight_insights"] = [{"quote": "今天讨论虚构的星河项目发布方案。", "reason": "Context", "speaker": "甲",
                                  "evidence_span": {"start_ms": 0, "end_ms": 100_000}}]
    postprocessed = copy.deepcopy(raw)
    postprocessed["highlight_insights"][0]["evidence_span"]["end_ms"] = 4_200
    report = assessment.assess_pair(cases[0], raw_payload=raw, postprocessed_payload=postprocessed)
    original = report["stages"]["raw"]
    repaired = report["stages"]["postprocessed"]
    assert original["assessment"]["evidence_scope"]["status"] == "fail"
    assert repaired["assessment"]["evidence_scope"]["status"] == "pass"
    assert original["assessment"]["payload_sha256"] != repaired["assessment"]["payload_sha256"]
    raw["highlight_insights"].clear()
    assert original["payload"]["highlight_insights"][0]["evidence_span"]["end_ms"] == 100_000
    assert original["review"]["stage"] == "raw"
    assert repaired["review"]["stage"] == "postprocessed"


@pytest.mark.parametrize("raw_payload", [None, [], "truncated JSON", {"session_overview": {}}])
def test_missing_or_invalid_raw_does_not_become_empty_success(cases, raw_payload):
    report = assessment.assess_pair(cases[3], raw_payload=raw_payload, postprocessed_payload=None)
    raw = report["stages"]["raw"]["assessment"]
    assert raw["schema"]["status"] in {"not_available", "fail"}
    assert raw["semantic_pass"] is None
    assert report["stages"]["postprocessed"]["payload"] is None
    assert report["stages"]["postprocessed"]["assessment"]["schema"]["status"] == "not_available"


def test_insufficient_input_allows_empty_arrays_without_fabricated_review_claims(cases):
    result = assessment.assess_payload(cases[3], empty_package(), stage="raw")
    assert result["schema"]["status"] == "pass"
    assert result["field_domains"]["status"] == "within_literal_domains"
    assert result["semantic_pass"] is None


def test_point_span_in_a_gap_is_not_source_evidence(cases):
    package = empty_package()
    package["highlight_insights"] = [{"quote": "Invented", "reason": "Invented", "speaker": "甲",
                                      "evidence_span": {"start_ms": 4_500, "end_ms": 4_500}}]
    result = assessment.assess_payload(cases[0], package, stage="raw")
    assert result["schema"]["status"] == "pass"
    assert result["evidence_scope"]["status"] == "fail"
