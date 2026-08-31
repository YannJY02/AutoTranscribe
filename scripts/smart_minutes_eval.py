#!/usr/bin/env python3
"""Run the privacy-safe Smart Minutes evaluation contract."""

from __future__ import annotations

import argparse
import hashlib
import importlib
import json
import math
import os
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from insightkit.insights.schema_validator import validate_insight_package
from insightkit.insights.service import InsightService

DEFAULT_DATASET = ROOT / "evals/smart_minutes/v1"
LANGFUSE_DATASET = "insightkit-smart-minutes-v1-metadata"


class BoundedFailureError(Exception):
    """Deliberate adapter signal that a bounded-failure case was rejected safely."""


class LangfusePrerequisiteError(Exception):
    """Langfuse was requested but its local setup is incomplete."""


def _canonical_hash(values: list[dict[str, Any]]) -> str:
    payload = json.dumps(values, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def load_eval_contract(dataset_dir: Path) -> dict[str, Any]:
    dataset = json.loads((dataset_dir / "dataset.json").read_text(encoding="utf-8"))
    rubric = json.loads((dataset_dir / "rubric.json").read_text(encoding="utf-8"))
    cases = dataset.get("cases") or []
    if not cases or any(case.get("safety", {}).get("synthetic") is not True for case in cases):
        raise ValueError("dataset safety contract requires non-empty synthetic cases")
    if {case.get("language") for case in cases} != {"zh", "en", "mixed"}:
        raise ValueError("dataset must cover zh, en, and mixed language cases")
    return {
        "dataset_version": dataset["dataset_version"],
        "dataset_sha256": _canonical_hash(cases),
        "cases": cases,
        "rubric": rubric,
    }


def _span_bounds(span: Any) -> tuple[int, int] | None:
    if not isinstance(span, dict):
        return None
    try:
        start, end = int(span.get("start_ms", -1)), int(span.get("end_ms", -1))
    except (TypeError, ValueError):
        return None
    return (start, end) if 0 <= start <= end else None


def _overlaps_source(span: Any, transcript: list[dict[str, Any]]) -> bool:
    bounds = _span_bounds(span)
    if bounds is None:
        return False
    start, end = bounds
    try:
        return any(start <= int(row["end_ms"]) and end >= int(row["start_ms"]) for row in transcript)
    except (KeyError, TypeError, ValueError):
        return False


def _span_member(span: Any, key: str) -> Any:
    return span.get(key) if isinstance(span, dict) else None


def _linkage_failure_detail(span: Any) -> str:
    return "has no source overlap" if _span_bounds(span) is not None else "has invalid bounds or no source overlap"


def _failure(case_id: str, metric: str, expected: str, actual: str, evidence: str) -> dict[str, str]:
    return {
        "case": case_id,
        "metric": metric,
        "expected_contract": expected,
        "actual_observation": actual,
        "evidence_reference": evidence,
    }


def evaluate_package(case: dict[str, Any], package: dict[str, Any], latency_ms: float) -> dict[str, Any]:
    failures: list[dict[str, str]] = []
    try:
        validate_insight_package(package)
    except Exception as exc:
        failures.append(_failure(case["id"], "schema", "valid InsightPackageV1", type(exc).__name__, "output"))
        list_sections = ("highlight_insights", "speaker_perspectives", "decision_ledger", "action_tracks", "timeline_beats", "provenance_links")
        if not isinstance(package, dict) or any(section in package and not isinstance(package[section], list) for section in list_sections):
            return {"case": case["id"], "gate_result": "fail", "failures": failures, "diagnostics": {"latency_ms": latency_ms}}

    transcript = case.get("transcript") or []
    evidence_sections = (("highlight_insights", "evidence_span"), ("decision_ledger", "evidence_span"), ("action_tracks", "evidence_span"))
    for section, field in evidence_sections:
        for index, raw_item in enumerate(package.get(section) or []):
            item = raw_item if isinstance(raw_item, dict) else {}
            span = item.get(field) or {}
            if not _overlaps_source(span, transcript):
                failures.append(_failure(
                    case["id"], "source_evidence_linkage",
                    "every generated evidence span overlaps a source transcript segment",
                    f"{section}[{index}] span {_span_member(span, 'start_ms')}-{_span_member(span, 'end_ms')} {_linkage_failure_detail(span)}",
                    f"output.{section}[{index}].{field}",
                ))

    for item_index, raw_item in enumerate(package.get("speaker_perspectives") or []):
        item = raw_item if isinstance(raw_item, dict) else {}
        raw_spans = item.get("evidence_spans") or []
        spans = raw_spans if isinstance(raw_spans, list) else [{}]
        for span_index, span in enumerate(spans):
            if not _overlaps_source(span, transcript):
                failures.append(_failure(
                    case["id"], "source_evidence_linkage",
                    "every generated evidence span overlaps a source transcript segment",
                    f"speaker_perspectives[{item_index}] evidence_spans[{span_index}] "
                    f"span {_span_member(span, 'start_ms')}-{_span_member(span, 'end_ms')} {_linkage_failure_detail(span)}",
                    f"output.speaker_perspectives[{item_index}].evidence_spans[{span_index}]",
                ))

    if case["expected_behavior"] == "bounded_failure":
        generated_claims = [
            item
            for section in ("decision_ledger", "action_tracks")
            for item in package.get(section) or []
            if isinstance(item, dict)
        ]
        all_review_marked = bool(generated_claims) and all(item.get("needs_review") is True for item in generated_claims)
        if not all_review_marked:
            failures.append(_failure(case["id"], "failure_behavior", "fallback output is explicitly marked needs_review", "no review marker found", "output.decision_ledger|action_tracks"))

    rendered = json.dumps(package, ensure_ascii=False).lower()
    forbidden = [claim for claim in case.get("reference", {}).get("forbidden_claims", []) if claim.lower() in rendered]
    fidelity: dict[str, dict[str, list[str]]] = {}
    for output_name, reference_name in (("decisions", "decisions"), ("actions", "actions")):
        claims = case.get("reference", {}).get(reference_name, [])
        fidelity[output_name] = {
            "matched": [claim for claim in claims if claim.lower() in rendered],
            "missing": [claim for claim in claims if claim.lower() not in rendered],
        }
    diagnostics = {
        "latency_ms": round(latency_ms, 3),
        "module_counts": {name: len(package.get(name) or []) for name in ("highlight_insights", "speaker_perspectives", "decision_ledger", "action_tracks", "timeline_beats")},
        "forbidden_claims_observed": forbidden,
        "decision_action_fidelity": fidelity,
        "semantic_scores": "unscored_without_approved_adapter",
    }
    if case["expected_behavior"] == "bounded_failure":
        diagnostics["bounded_failure_observation"] = {
            "generated_decisions": len(package.get("decision_ledger") or []),
            "generated_actions": len(package.get("action_tracks") or []),
            "all_generated_claims_need_review": all_review_marked,
        }
    return {"case": case["id"], "gate_result": "fail" if failures else "pass", "failures": failures, "diagnostics": diagnostics}


def _load_adapter(spec: str | Callable[[dict[str, Any]], dict[str, Any]]) -> Callable[[dict[str, Any]], dict[str, Any]]:
    if callable(spec):
        return spec
    module_name, separator, function_name = spec.partition(":")
    if not separator:
        raise ValueError("adapter must use module:function syntax")
    return getattr(importlib.import_module(module_name), function_name)


def _callable_identity(value: str | Callable[..., Any]) -> str:
    if isinstance(value, str):
        return value
    return f"{value.__module__}:{value.__qualname__}"


def _bounded_semantic_result(result: Any, metric_ids: set[str]) -> dict[str, float | bool | None]:
    if not isinstance(result, dict):
        raise ValueError("semantic adapter result must be a mapping")
    bounded = {key: value for key, value in result.items() if key in metric_ids}
    if not bounded or any(
        not (value is None or isinstance(value, (int, float, bool)))
        or (isinstance(value, float) and not math.isfinite(value))
        for value in bounded.values()
    ):
        raise ValueError("semantic adapter returned no valid diagnostics")
    return bounded


def _apply_semantic_adapter(
    adapter: Callable[[dict[str, Any]], dict[str, Any]] | None,
    *,
    leg: str,
    case: dict[str, Any],
    package: dict[str, Any],
    result: dict[str, Any],
    metric_ids: set[str],
) -> dict[str, str] | None:
    if adapter is None:
        return None
    try:
        observation = adapter({"leg": leg, "case": case, "output": package})
    except Exception as exc:
        result["diagnostics"]["semantic_adapter"] = {"status": "adapter_failed_without_payload_capture"}
        return _failure(
            case["id"],
            "semantic_evaluation",
            "configured semantic adapter returns bounded rubric diagnostics",
            f"semantic adapter raised {type(exc).__name__}",
            f"semantic.{leg}.execution",
        )
    try:
        result["diagnostics"]["semantic_adapter"] = _bounded_semantic_result(observation, metric_ids)
        return None
    except ValueError:
        result["diagnostics"]["semantic_adapter"] = {"status": "adapter_returned_no_valid_diagnostics"}
        return _failure(
            case["id"],
            "semantic_evaluation",
            "configured semantic adapter returns bounded rubric diagnostics",
            "semantic adapter returned no valid diagnostics",
            f"semantic.{leg}.result",
        )


def _markdown_diagnostics(diagnostics: dict[str, Any]) -> list[str]:
    lines = [f"  - latency: `{diagnostics['latency_ms']} ms`"]
    lines.append(f"  - module counts: `{json.dumps(diagnostics.get('module_counts', {}), ensure_ascii=False, sort_keys=True)}`")
    lines.append(f"  - decision/action fidelity: `{json.dumps(diagnostics.get('decision_action_fidelity', {}), ensure_ascii=False, sort_keys=True)}`")
    lines.append(f"  - forbidden claims observed: `{json.dumps(diagnostics.get('forbidden_claims_observed', []), ensure_ascii=False)}`")
    if "bounded_failure_observation" in diagnostics:
        lines.append(f"  - bounded failure: `{json.dumps(diagnostics['bounded_failure_observation'], ensure_ascii=False, sort_keys=True)}`")
    if "semantic_adapter" in diagnostics:
        lines.append(f"  - semantic diagnostics: `{json.dumps(diagnostics['semantic_adapter'], ensure_ascii=False, sort_keys=True)}`")
    return lines


def _markdown(report: dict[str, Any]) -> str:
    external = report["legs"]["external"]
    semantic = report["legs"]["semantic"]
    langfuse = report["legs"]["langfuse"]
    lines = [
        "# Smart Minutes evaluation report", "",
        f"- Dataset: `{report['dataset']['version']}` (`{report['dataset']['sha256']}`)",
        f"- Gate result: **{report['gate_result'].upper()}**",
        f"- Local baseline: {report['legs']['local']['status']} (`local-extractive` / `heuristic-v1`)",
        f"- External baseline: {'Unobserved' if external['status'] == 'unobserved' else external['status']}",
        f"- Semantic evaluation: {semantic['status']}",
        f"- Langfuse experiment: {langfuse['status']}",
    ]
    if external.get("missing_prerequisite"):
        lines.append(f"- External prerequisite: {external['missing_prerequisite']}")
    if semantic.get("missing_prerequisite"):
        lines.append(f"- Semantic prerequisite: {semantic['missing_prerequisite']}")
    if semantic.get("adapter"):
        lines.append(f"- Semantic adapter: `{semantic['adapter']}`")
    for failure in semantic.get("failures", []):
        lines.append(f"- Semantic failure `{failure['case']}` / `{failure['metric']}`: expected {failure['expected_contract']}; actual {failure['actual_observation']}; evidence `{failure['evidence_reference']}`")
    lines.extend(["", "## Cases", ""])
    for case in report["cases"]:
        lines.append(f"- `{case['case']}`: {case['gate_result'].upper()}")
        lines.extend(_markdown_diagnostics(case["diagnostics"]))
        for failure in case["failures"]:
            lines.append(f"  - {failure['metric']}: expected {failure['expected_contract']}; actual {failure['actual_observation']}; evidence `{failure['evidence_reference']}`")
    if external.get("cases"):
        lines.extend(["", f"## External cases ({external.get('provider', '')} / {external.get('model', '')})", ""])
        for case in external["cases"]:
            lines.append(f"- `{case['case']}`: {case['gate_result'].upper()}")
            lines.extend(_markdown_diagnostics(case["diagnostics"]))
            for failure in case["failures"]:
                lines.append(f"  - {failure['metric']}: expected {failure['expected_contract']}; actual {failure['actual_observation']}; evidence `{failure['evidence_reference']}`")
    lines.extend(["", "> Semantic and latency observations are diagnostic; no numeric quality threshold is accepted.", ""])
    return "\n".join(lines)


def _new_langfuse_client() -> Any:
    if not os.getenv("LANGFUSE_PUBLIC_KEY") or not os.getenv("LANGFUSE_SECRET_KEY"):
        raise LangfusePrerequisiteError("Langfuse credentials are not configured")
    if not os.getenv("LANGFUSE_BASE_URL") and not os.getenv("LANGFUSE_HOST"):
        raise LangfusePrerequisiteError("Langfuse base URL is not configured")
    from langfuse import Langfuse

    return Langfuse(environment="owner-pilot")


def _sync_langfuse(contract: dict[str, Any], report: dict[str, Any], client: Any) -> dict[str, Any]:
    try:
        client.get_dataset(LANGFUSE_DATASET)
    except Exception:
        client.create_dataset(
            name=LANGFUSE_DATASET,
            description="Synthetic Smart Minutes gate metadata; no meeting content.",
            metadata={
                "dataset_version": contract["dataset_version"],
                "dataset_sha256": contract["dataset_sha256"],
                "rubric_version": contract["rubric"]["rubric_version"],
                "synthetic": True,
            },
            input_schema={
                "type": "object",
                "properties": {"case_id": {"type": "string"}},
                "required": ["case_id"],
                "additionalProperties": False,
            },
            expected_output_schema={
                "type": "object",
                "properties": {"expected_behavior": {"enum": ["success", "bounded_failure"]}},
                "required": ["expected_behavior"],
                "additionalProperties": False,
            },
        )

    case_by_item_id = {}
    for case in contract["cases"]:
        item_id = str(uuid.uuid5(uuid.NAMESPACE_URL, f"{LANGFUSE_DATASET}:{case['id']}"))
        case_by_item_id[item_id] = case["id"]
        client.create_dataset_item(
            dataset_name=LANGFUSE_DATASET,
            id=item_id,
            input={"case_id": case["id"]},
            expected_output={"expected_behavior": case["expected_behavior"]},
            metadata={
                "dataset_version": contract["dataset_version"],
                "language": case["language"],
                "synthetic": True,
            },
        )

    results_by_case = {item["case"]: item for item in report["cases"]}

    def task(*, item: Any, **_kwargs: Any) -> dict[str, Any]:
        result = results_by_case[item.input["case_id"]]
        return {
            "case_id": result["case"],
            "gate_result": result["gate_result"],
            "failed_metrics": sorted({failure["metric"] for failure in result["failures"]}),
            "latency_ms": result["diagnostics"]["latency_ms"],
        }

    def source_evidence_linkage(*, output: dict[str, Any], **_kwargs: Any) -> dict[str, Any]:
        return {"name": "source_evidence_linkage", "value": "source_evidence_linkage" not in output["failed_metrics"], "data_type": "BOOLEAN"}

    def failure_behavior(*, output: dict[str, Any], expected_output: dict[str, Any], **_kwargs: Any) -> Any:
        if expected_output["expected_behavior"] != "bounded_failure":
            return []
        return {"name": "failure_behavior", "value": "failure_behavior" not in output["failed_metrics"], "data_type": "BOOLEAN"}

    def latency(*, output: dict[str, Any], **_kwargs: Any) -> dict[str, Any]:
        return {"name": "latency", "value": output["latency_ms"], "data_type": "NUMERIC"}

    run_name = f"{contract['dataset_version']}-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')}"
    experiment = client.get_dataset(LANGFUSE_DATASET).run_experiment(
        name="Smart Minutes synthetic metadata gate",
        run_name=run_name,
        description="Owner-pilot replay of deterministic Smart Minutes gates without meeting content.",
        task=task,
        evaluators=[source_evidence_linkage, failure_behavior, latency],
        max_concurrency=1,
        metadata={
            "dataset_version": contract["dataset_version"],
            "dataset_sha256": contract["dataset_sha256"],
            "rubric_version": contract["rubric"]["rubric_version"],
            "provider": "local-extractive",
            "model": "heuristic-v1",
            "synthetic": True,
        },
    )
    client.flush()
    run_deadline = time.monotonic() + 35
    while True:
        readback = client.get_dataset_run(dataset_name=LANGFUSE_DATASET, run_name=run_name)
        run_item_count = len(readback.dataset_run_items)
        if run_item_count == len(contract["cases"]):
            break
        remaining = run_deadline - time.monotonic()
        if run_item_count > len(contract["cases"]) or remaining <= 0:
            raise RuntimeError("Langfuse readback did not reconcile with the local report")
        time.sleep(min(2, remaining))

    expected_scores = {}
    for run_item in readback.dataset_run_items:
        case_id = case_by_item_id.get(run_item.dataset_item_id)
        if case_id is None:
            raise RuntimeError("Langfuse readback contained an unexpected dataset item")
        result = results_by_case[case_id]
        failed_metrics = {failure["metric"] for failure in result["failures"]}
        expected_scores[(run_item.trace_id, "source_evidence_linkage")] = float("source_evidence_linkage" not in failed_metrics)
        expected_scores[(run_item.trace_id, "latency")] = float(result["diagnostics"]["latency_ms"])
        if next(case for case in contract["cases"] if case["id"] == case_id)["expected_behavior"] == "bounded_failure":
            expected_scores[(run_item.trace_id, "failure_behavior")] = float("failure_behavior" not in failed_metrics)

    remote_scores = []
    score_deadline = time.monotonic() + 35
    while True:
        remote_scores = [
            (run_item.trace_id, score)
            for run_item in readback.dataset_run_items
            for score in client.api.scores_v3.get_many_v3(trace_id=run_item.trace_id, limit=10).data
        ]
        remote_values = {(trace_id, score.name): float(score.value) for trace_id, score in remote_scores}
        if (
            len(remote_scores) == len(expected_scores)
            and remote_values.keys() == expected_scores.keys()
            and all(math.isclose(remote_values[key], value) for key, value in expected_scores.items())
        ):
            break
        remaining = score_deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError("Langfuse score readback did not reconcile with the local report")
        time.sleep(min(2, remaining))
    return {
        "status": "observed",
        "dataset": LANGFUSE_DATASET,
        "dataset_item_count": len(contract["cases"]),
        "dataset_run_id": experiment.dataset_run_id,
        "dataset_run_url": experiment.dataset_run_url,
        "dataset_run_item_count": run_item_count,
        "remote_score_count": len(remote_scores),
        "remote_score_names": sorted({score.name for _trace_id, score in remote_scores}),
    }


def run_eval(
    dataset_dir: Path,
    output_dir: Path,
    external: dict[str, Any] | None = None,
    semantic_adapter: str | Callable[[dict[str, Any]], dict[str, Any]] | None = None,
    *,
    langfuse: bool = False,
    langfuse_client: Any = None,
) -> dict[str, Any]:
    contract = load_eval_contract(dataset_dir)
    metric_ids = {metric["id"] for metric in contract["rubric"]["metrics"]}
    adapter = None
    semantic_leg: dict[str, Any] = {
        "status": "unobserved",
        "missing_prerequisite": "approved semantic adapter configuration (--semantic-adapter) was not provided",
    }
    if semantic_adapter:
        try:
            adapter = _load_adapter(semantic_adapter)
            semantic_leg = {
                "status": "observed",
                "adapter": _callable_identity(semantic_adapter),
            }
        except Exception:
            semantic_leg = {
                "status": "failed",
                "missing_prerequisite": "configured semantic adapter could not be loaded",
                "failures": [_failure(
                    "<configuration>",
                    "semantic_evaluation",
                    "configured semantic adapter can be loaded",
                    "semantic adapter could not be loaded",
                    "semantic.configuration",
                )],
            }
    service = InsightService()
    results = []
    for case in contract["cases"]:
        started = time.perf_counter()
        package = service.build_local_extractive(case["transcript"])
        elapsed = (time.perf_counter() - started) * 1000
        result = evaluate_package(case, package, elapsed)
        semantic_failure = _apply_semantic_adapter(adapter, leg="local", case=case, package=package, result=result, metric_ids=metric_ids)
        if semantic_failure:
            semantic_leg["status"] = "failed"
            semantic_leg["missing_prerequisite"] = (
                "configured semantic adapter returned no valid diagnostics"
                if semantic_failure["evidence_reference"].endswith(".result")
                else "configured semantic adapter failed without payload capture"
            )
            semantic_leg.setdefault("failures", []).append(semantic_failure)
        results.append(result)

    external_leg: dict[str, Any] = {
        "status": "unobserved",
        "missing_prerequisite": "explicit adapter configuration (--external-vendor) was not provided",
    }
    if external:
        implementation_version = external.get("implementation_version") or (
            _callable_identity(external["builder"])
            if external.get("builder") is not None
            else "InsightService.build_final"
        )
        external_leg = {
            "status": "observed",
            "provider": external["vendor"],
            "model": external.get("model", ""),
            "implementation_version": implementation_version,
            "gate_result": "pass",
            "cases": [],
        }
        cloud_service = InsightService(default_vendor=external["vendor"], model=external.get("model"))
        builder = external.get("builder")
        uses_service_builder = builder is None
        if builder is None:
            builder = lambda case: cloud_service.build_final(case["transcript"])
        for case in contract["cases"]:
            started = time.perf_counter()
            try:
                package = builder(case)
                if uses_service_builder:
                    external_leg["provider"] = cloud_service.last_call_meta.get("vendor") or external_leg["provider"]
                    external_leg["model"] = cloud_service.last_call_meta.get("model") or external_leg["model"]
                case_result = evaluate_package(case, package, (time.perf_counter() - started) * 1000)
                semantic_failure = _apply_semantic_adapter(adapter, leg="external", case=case, package=package, result=case_result, metric_ids=metric_ids)
                if semantic_failure:
                    semantic_leg["status"] = "failed"
                    semantic_leg["missing_prerequisite"] = (
                        "configured semantic adapter returned no valid diagnostics"
                        if semantic_failure["evidence_reference"].endswith(".result")
                        else "configured semantic adapter failed without payload capture"
                    )
                    semantic_leg.setdefault("failures", []).append(semantic_failure)
                external_leg["cases"].append(case_result)
            except Exception as exc:
                lower = str(exc).lower()
                if not external_leg["cases"] and any(marker in lower for marker in ("missing api key", "未配置 api key", "credential")):
                    external_leg = {
                        "status": "unobserved",
                        "provider": external["vendor"],
                        "model": external.get("model", ""),
                        "implementation_version": implementation_version,
                        "missing_prerequisite": "provider credentials are not configured",
                    }
                    break
                elapsed = (time.perf_counter() - started) * 1000
                if case["expected_behavior"] == "bounded_failure" and isinstance(exc, BoundedFailureError):
                    external_leg["cases"].append({
                        "case": case["id"],
                        "gate_result": "pass",
                        "failures": [],
                        "diagnostics": {
                            "latency_ms": round(elapsed, 3),
                            "bounded_failure_observation": {"named_error": type(exc).__name__},
                        },
                    })
                    continue
                external_leg["cases"].append({
                    "case": case["id"],
                    "gate_result": "fail",
                    "failures": [_failure(case["id"], "failure_behavior", "configured baseline returns a valid InsightPackageV1 or an explicit prerequisite is absent", f"external baseline raised {type(exc).__name__}", "external.execution")],
                    "diagnostics": {"latency_ms": round(elapsed, 3)},
                })
                continue
        if external_leg["status"] == "observed" and any(case["gate_result"] == "fail" for case in external_leg["cases"]):
            external_leg["gate_result"] = "fail"

    report = {
        "report_version": "smart-minutes-eval-report-v1",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "dataset": {"version": contract["dataset_version"], "sha256": contract["dataset_sha256"]},
        "rubric": {"version": contract["rubric"]["rubric_version"], "policy": contract["rubric"]["policy"]},
        "gate_result": "fail" if any(item["gate_result"] == "fail" for item in results) or external_leg.get("gate_result") == "fail" else "pass",
        "legs": {
            "local": {"status": "observed", "provider": "local-extractive", "model": "heuristic-v1", "implementation_version": "InsightService.build_local_extractive"},
            "external": external_leg,
            "semantic": semantic_leg,
            "langfuse": {
                "status": "unobserved",
                "missing_prerequisite": "explicit --langfuse upload was not requested",
            },
        },
        "cases": results,
    }
    if langfuse:
        try:
            client = langfuse_client if langfuse_client is not None else _new_langfuse_client()
            report["legs"]["langfuse"] = _sync_langfuse(contract, report, client)
        except (LangfusePrerequisiteError, ModuleNotFoundError) as exc:
            report["legs"]["langfuse"] = {
                "status": "unobserved",
                "missing_prerequisite": (
                    str(exc)
                    if isinstance(exc, LangfusePrerequisiteError)
                    else "langfuse optional dependency is not installed"
                ),
            }
        except Exception as exc:
            report["legs"]["langfuse"] = {
                "status": "failed",
                "failure": f"Langfuse sync raised {type(exc).__name__}",
            }
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "smart-minutes-eval.json").write_text(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    (output_dir / "smart-minutes-eval.md").write_text(_markdown(report), encoding="utf-8")
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-dir", type=Path, default=DEFAULT_DATASET)
    parser.add_argument("--output-dir", type=Path, default=ROOT / "logs/smart-minutes-eval/local")
    parser.add_argument("--external-vendor")
    parser.add_argument("--external-model", default="")
    parser.add_argument("--semantic-adapter", help="approved synthetic-only evaluator as module:function")
    parser.add_argument("--langfuse", action="store_true", help="upload allowlisted synthetic metadata and read back the dataset run")
    args = parser.parse_args()
    external = {"vendor": args.external_vendor, "model": args.external_model} if args.external_vendor else None
    report = run_eval(
        args.dataset_dir,
        args.output_dir,
        external=external,
        semantic_adapter=args.semantic_adapter,
        langfuse=args.langfuse,
    )
    print(json.dumps({"gate_result": report["gate_result"], "dataset": report["dataset"], "langfuse": report["legs"]["langfuse"]["status"], "output_dir": str(args.output_dir)}, ensure_ascii=False))
    langfuse_ok = not args.langfuse or report["legs"]["langfuse"]["status"] == "observed"
    return 0 if report["gate_result"] == "pass" and langfuse_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
