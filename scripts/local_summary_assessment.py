"""Frozen synthetic inputs, bounded structural checks, and unscored review sheets.

This module never runs a model or treats lexical matches as semantic approval.
"""

from __future__ import annotations

import copy
import hashlib
import json
import re
from pathlib import Path
from typing import Any, Literal

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DATASET = ROOT / "evals/local_summary/v1/dataset.json"
PRODUCT_SCHEMA = ROOT / "insightkit/schemas/insight_package_v1.json"
MODULES = (
    "session_overview", "highlight_insights", "speaker_perspectives",
    "decision_ledger", "action_tracks", "timeline_beats", "provenance_links",
)
Stage = Literal["raw", "postprocessed"]


def _hash(value: Any) -> str:
    encoded = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)
    return hashlib.sha256(encoded.encode()).hexdigest()


def _validate_segments(segments: list[dict[str, Any]]) -> None:
    previous_end = -1
    for segment in segments:
        start, end = segment.get("start_ms"), segment.get("end_ms")
        if (type(start) is not int or type(end) is not int
                or not 0 <= start < end <= 120_000 or start < previous_end
                or not isinstance(segment.get("text"), str) or not segment["text"].strip()
                or not isinstance(segment.get("speaker"), str)):
            raise ValueError("fixture must contain ordered complete segments within 120 seconds")
        previous_end = end


def load_contract(dataset_path: Path | None = None) -> dict[str, Any]:
    """Resolve source references and validate all eight complete synthetic inputs.

    Legacy transcript rows have no native IDs. Their adapter IDs are deterministically
    derived from the locked case ID and one-based row position, never from model output.
    """
    path = Path(dataset_path) if dataset_path is not None else DEFAULT_DATASET
    dataset = json.loads(path.read_text(encoding="utf-8"))
    cases = copy.deepcopy(dataset["cases"])
    if (dataset.get("max_generation_requests") != 8 or len(cases) != 8
            or len({case["id"] for case in cases}) != 8
            or [case["mode"] for case in cases] != ["final"] * 4 + ["live"] * 3 + ["final"]):
        raise ValueError("contract requires four final, three live prefixes, one final request")
    for case in cases:
        if case.get("safety", {}).get("synthetic") is not True:
            raise ValueError("only synthetic fixtures are permitted")
        if "source_ref" in case:
            ref = case["source_ref"]
            if ref["path"] != "evals/smart_minutes/v1/dataset.json":
                raise ValueError("source reference is outside the approved synthetic dataset")
            source_bytes = (ROOT / ref["path"]).read_bytes()
            if hashlib.sha256(source_bytes).hexdigest() != ref["sha256"]:
                raise ValueError("legacy source SHA256 changed; freeze a new contract version")
            source = json.loads(source_bytes)
            matches = [row for row in source["cases"] if row["id"] == ref["case_id"]]
            if len(matches) != 1 or matches[0].get("safety", {}).get("synthetic") is not True:
                raise ValueError("legacy source must resolve to one synthetic case")
            transcript = copy.deepcopy(matches[0]["transcript"])
            expected_ids = [f"{ref['case_id']}:s{index:02}" for index in range(1, len(transcript) + 1)]
            if case["stable_segment_ids"] != expected_ids:
                raise ValueError("legacy segment IDs must cover every locked source row in order")
            case["source"] = {**ref, "synthetic": True, "segment_id_origin": "case ID plus one-based source row"}
        else:
            story = dataset["stories"][case["story_ref"]]
            segments = story["segments"]
            if (story.get("safety", {}).get("synthetic") is not True
                    or any(segment.get("stable") is not True for segment in segments)
                    or len({segment["id"] for segment in segments}) != len(segments)):
                raise ValueError("story requires unique stable synthetic segments")
            _validate_segments(segments)
            count = len(case["stable_segment_ids"])
            if not count or case["stable_segment_ids"] != [segment["id"] for segment in segments[:count]]:
                raise ValueError("live input must be an exact complete prefix, without skipped segments")
            if case["mode"] == "final" and count != len(segments):
                raise ValueError("story final input must contain the full stable transcript")
            transcript = [{key: segment[key] for key in ("start_ms", "end_ms", "speaker", "text")}
                          for segment in segments[:count]]
            case["source"] = {"story_id": case["story_ref"], "description": story["source"], "synthetic": True}
        if not transcript:
            raise ValueError("fixture transcript must not be empty")
        _validate_segments(transcript)
        case["transcript"] = transcript
        case["visible_end_ms"] = transcript[-1]["end_ms"]
        case["transcript_sha256"] = _hash(transcript)
        case["expectations"]["checkpoints"] = copy.deepcopy(dataset["common_checkpoints"]) + case["expectations"]["facts"]
        visible_ids = set(case["stable_segment_ids"])
        for checkpoint in case["expectations"]["checkpoints"]:
            if not set(checkpoint["source_segment_ids"]).issubset(visible_ids):
                raise ValueError("checkpoint references hidden future evidence")
    story_cases = cases[4:]
    if (len({case.get("story_ref") for case in story_cases}) != 1
            or not len(story_cases[0]["transcript"]) < len(story_cases[1]["transcript"]) < len(story_cases[2]["transcript"])
            or story_cases[2]["transcript"] != story_cases[3]["transcript"]):
        raise ValueError("story must progress through three cumulative prefixes then the same full final input")
    return {"dataset_version": dataset["dataset_version"], "dataset_sha256": _hash({"dataset": dataset, "cases": cases}),
            "max_generation_requests": 8, "cases": cases}


def _select(payload: Any, path: str) -> list[dict[str, Any]]:
    """Return only values at a field path; never search serialized whole-package text."""
    selected = [("", payload)]
    for token in path.split("."):
        is_array = token.endswith("[]")
        key = token[:-2] if is_array else token
        next_selected = []
        for prefix, value in selected:
            if not isinstance(value, dict) or key not in value:
                continue
            field_path = f"{prefix}.{key}" if prefix else key
            if is_array and isinstance(value[key], list):
                next_selected.extend((f"{field_path}[{index}]", item) for index, item in enumerate(value[key]))
            elif not is_array:
                next_selected.append((field_path, value[key]))
        selected = next_selected
    return [{"path": field_path, "value": copy.deepcopy(value)} for field_path, value in selected]


def _valid_span(span: dict[str, Any], transcript: list[dict[str, Any]]) -> bool:
    start, end = span["start_ms"], span["end_ms"]
    return (type(start) is int and type(end) is int and 0 <= start < end <= transcript[-1]["end_ms"]
            and any(start < row["end_ms"] and end > row["start_ms"] for row in transcript))


def _timestamp_ms(value: str) -> int | None:
    if not re.fullmatch(r"\d{1,2}:\d{2}(?::\d{2})?", value):
        return None
    parts = [int(part) for part in value.split(":")]
    if parts[-1] >= 60 or (len(parts) == 3 and parts[-2] >= 60):
        return None
    seconds = parts[0] * 60 + parts[1] if len(parts) == 2 else parts[0] * 3600 + parts[1] * 60 + parts[2]
    return seconds * 1000


def assess_payload(case: dict[str, Any], payload: Any, *, stage: Stage) -> dict[str, Any]:
    """Check structure, visible evidence range, and frozen literal field domains.

    A pass here is NEVER semantic approval. None means no parsed payload available;
    other JSON values are validated as supplied and cannot become an empty success.
    """
    if stage not in ("raw", "postprocessed"):
        raise ValueError("stage must explicitly identify raw or postprocessed payload")
    result: dict[str, Any] = {
        "case_id": case["id"], "stage": stage, "payload_sha256": _hash(payload),
        "parse_status": "unavailable" if payload is None else "supplied_json_value",
        "schema": {"status": "not_available", "issues": []},
        "evidence_scope": {"status": "not_checked", "issues": []},
        "field_domains": {"status": "not_checked", "issues": []},
        "semantic_status": "not_reviewed", "semantic_pass": None,
    }
    if payload is None:
        return result
    try:
        from jsonschema import Draft202012Validator
    except ImportError:
        result["schema"]["status"] = "validator_unavailable"
        return result
    schema = json.loads(PRODUCT_SCHEMA.read_text(encoding="utf-8"))
    errors = [{"path": ".".join(map(str, error.absolute_path)), "message": error.message}
              for error in Draft202012Validator(schema).iter_errors(payload)]
    result["schema"] = {"status": "fail" if errors else "pass", "issues": errors}
    if errors:
        return result
    scope_issues = []
    for path in ("highlight_insights[].evidence_span", "decision_ledger[].evidence_span",
                 "action_tracks[].evidence_span", "speaker_perspectives[].evidence_spans[]"):
        for selected in _select(payload, path):
            if not _valid_span(selected["value"], case["transcript"]):
                scope_issues.append({"path": selected["path"], "code": "outside_visible_source_or_invalid_span"})
    for selected in _select(payload, "speaker_perspectives[].evidence_spans"):
        if not selected["value"]:
            scope_issues.append({"path": selected["path"], "code": "missing_perspective_evidence"})
    for selected in _select(payload, "timeline_beats[].timestamp"):
        timestamp = _timestamp_ms(selected["value"])
        if timestamp is None or timestamp > case["visible_end_ms"]:
            scope_issues.append({"path": selected["path"], "code": "invalid_or_future_timestamp"})
    result["evidence_scope"] = {"status": "fail" if scope_issues else "pass", "issues": scope_issues,
                                "meaning": "Range/link checks only; cited text may still not support the claim."}
    field_issues = []
    for module in case["expectations"]["empty_modules"]:
        if payload[module]:
            field_issues.append({"path": module, "code": "claims_in_explicitly_empty_module"})
    for constraint in case["expectations"]["field_constraints"]:
        allowed = {value.strip().casefold() for value in constraint["allowed_values"]}
        for selected in _select(payload, constraint["path"]):
            if selected["value"].strip().casefold() not in allowed:
                field_issues.append({"path": selected["path"], "code": "value_outside_frozen_literal_domain",
                                     "value": selected["value"], "allowed_values": constraint["allowed_values"]})
    result["field_domains"] = {"status": "requires_review" if field_issues else "within_literal_domains", "issues": field_issues,
                               "meaning": "Literal domain only; omissions, wrong-task assignments and unlisted equivalent expressions require semantic review."}
    return result


def make_review_template(case: dict[str, Any], payload: Any, *, stage: Stage) -> dict[str, Any]:
    """Produce field-bound observations and blank human semantic verdicts."""
    if stage not in ("raw", "postprocessed"):
        raise ValueError("stage must explicitly identify raw or postprocessed payload")
    rows = []
    for checkpoint in case["expectations"]["checkpoints"]:
        ids = checkpoint["source_segment_ids"] or case["stable_segment_ids"]
        rows.append({**copy.deepcopy(checkpoint),
                     "source": [{"id": segment_id, **copy.deepcopy(segment)}
                                for segment_id, segment in zip(case["stable_segment_ids"], case["transcript"])
                                if segment_id in ids],
                     "observed_fields": [value for path in checkpoint["paths"] for value in _select(payload, path)],
                     "verdict": None, "output_evidence_paths": [], "rationale": ""})
    return {"case_id": case["id"], "stage": stage, "payload_sha256": _hash(payload),
            "semantic_status": "not_reviewed", "reviewer": "", "reviewed_at": "",
            "verdict_options": ["pass", "fail", "not_applicable", "unobserved"],
            "instructions": "Read visible source and every generated claim. Cite output paths and explain each verdict. Missing required substantive facts fail recall. Abstention/unknown checks may be satisfied by absence; empty optional modules do not force invention. Never infer a pass from field-domain or span checks.",
            "checkpoints": rows}


def assess_pair(case: dict[str, Any], *, raw_payload: Any, postprocessed_payload: Any) -> dict[str, Any]:
    """Snapshot and assess both stages without using postprocessed data as raw proof.

    The caller must snapshot the parsed model value before any in-place product
    postprocessing. None is retained when parsing/postprocessing did not happen.
    """
    stages = {}
    for stage, payload in (("raw", raw_payload), ("postprocessed", postprocessed_payload)):
        snapshot = copy.deepcopy(payload)
        stages[stage] = {"payload": snapshot, "assessment": assess_payload(case, snapshot, stage=stage),
                         "review": make_review_template(case, snapshot, stage=stage)}
    return {"assessment_version": "local-summary-assessment-v1", "case_id": case["id"],
            "semantic_status": "not_reviewed", "stages": stages}
