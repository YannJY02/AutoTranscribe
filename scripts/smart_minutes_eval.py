#!/usr/bin/env python3
"""Run the privacy-safe Smart Minutes evaluation contract."""

from __future__ import annotations

import argparse
import hashlib
import importlib
import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from insightkit.insights.schema_validator import validate_insight_package
from insightkit.insights.service import InsightService

DEFAULT_DATASET = ROOT / "evals/smart_minutes/v1"


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


def _overlaps_source(span: dict[str, Any], transcript: list[dict[str, Any]]) -> bool:
    start, end = int(span.get("start_ms", -1)), int(span.get("end_ms", -1))
    return any(start <= int(row["end_ms"]) and end >= int(row["start_ms"]) for row in transcript)


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
        return {"case": case["id"], "gate_result": "fail", "failures": failures, "diagnostics": {"latency_ms": latency_ms}}

    transcript = case.get("transcript") or []
    evidence_sections = (("highlight_insights", "evidence_span"), ("decision_ledger", "evidence_span"), ("action_tracks", "evidence_span"))
    for section, field in evidence_sections:
        for index, item in enumerate(package.get(section) or []):
            span = item.get(field) or {}
            if transcript and not _overlaps_source(span, transcript):
                failures.append(_failure(
                    case["id"], "source_evidence_linkage",
                    "every generated evidence span overlaps a source transcript segment",
                    f"{section}[{index}] span {span.get('start_ms')}-{span.get('end_ms')} has no source overlap",
                    f"output.{section}[{index}].{field}",
                ))

    for item_index, item in enumerate(package.get("speaker_perspectives") or []):
        for span_index, span in enumerate(item.get("evidence_spans") or []):
            if transcript and not _overlaps_source(span, transcript):
                failures.append(_failure(
                    case["id"], "source_evidence_linkage",
                    "every generated evidence span overlaps a source transcript segment",
                    f"speaker_perspectives[{item_index}] evidence_spans[{span_index}] "
                    f"span {span.get('start_ms')}-{span.get('end_ms')} has no source overlap",
                    f"output.speaker_perspectives[{item_index}].evidence_spans[{span_index}]",
                ))

    if case["expected_behavior"] == "bounded_failure":
        review_marked = any(item.get("needs_review") is True for section in ("decision_ledger", "action_tracks") for item in package.get(section) or [])
        if not review_marked:
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
    return {"case": case["id"], "gate_result": "fail" if failures else "pass", "failures": failures, "diagnostics": diagnostics}


def _load_adapter(spec: str | Callable[[dict[str, Any]], dict[str, Any]]) -> Callable[[dict[str, Any]], dict[str, Any]]:
    if callable(spec):
        return spec
    module_name, separator, function_name = spec.partition(":")
    if not separator:
        raise ValueError("adapter must use module:function syntax")
    return getattr(importlib.import_module(module_name), function_name)


def _bounded_semantic_result(result: Any, metric_ids: set[str]) -> dict[str, float | bool | None]:
    if not isinstance(result, dict):
        return {}
    return {
        key: value
        for key, value in result.items()
        if key in metric_ids and (value is None or isinstance(value, (int, float, bool)))
    }


def _apply_semantic_adapter(
    adapter: Callable[[dict[str, Any]], dict[str, Any]] | None,
    *,
    leg: str,
    case: dict[str, Any],
    package: dict[str, Any],
    result: dict[str, Any],
    metric_ids: set[str],
) -> None:
    if adapter is None:
        return
    try:
        observation = adapter({"leg": leg, "case": case, "output": package})
        result["diagnostics"]["semantic_adapter"] = _bounded_semantic_result(observation, metric_ids)
    except Exception:
        result["diagnostics"]["semantic_adapter"] = {"status": "adapter_failed_without_payload_capture"}


def _markdown(report: dict[str, Any]) -> str:
    external = report["legs"]["external"]
    lines = [
        "# Smart Minutes evaluation report", "",
        f"- Dataset: `{report['dataset']['version']}` (`{report['dataset']['sha256']}`)",
        f"- Gate result: **{report['gate_result'].upper()}**",
        f"- Local baseline: {report['legs']['local']['status']} (`local-extractive` / `heuristic-v1`)",
        f"- External baseline: {'Unobserved' if external['status'] == 'unobserved' else external['status']}",
    ]
    if external.get("missing_prerequisite"):
        lines.append(f"- External prerequisite: {external['missing_prerequisite']}")
    lines.extend(["", "## Cases", ""])
    for case in report["cases"]:
        lines.append(f"- `{case['case']}`: {case['gate_result'].upper()}, latency `{case['diagnostics']['latency_ms']} ms`")
        for failure in case["failures"]:
            lines.append(f"  - {failure['metric']}: expected {failure['expected_contract']}; actual {failure['actual_observation']}; evidence `{failure['evidence_reference']}`")
    if external.get("cases"):
        lines.extend(["", f"## External cases ({external.get('provider', '')} / {external.get('model', '')})", ""])
        for case in external["cases"]:
            lines.append(f"- `{case['case']}`: {case['gate_result'].upper()}")
            for failure in case["failures"]:
                lines.append(f"  - {failure['metric']}: expected {failure['expected_contract']}; actual {failure['actual_observation']}; evidence `{failure['evidence_reference']}`")
    lines.extend(["", "> Semantic and latency observations are diagnostic; no numeric quality threshold is accepted.", ""])
    return "\n".join(lines)


def run_eval(dataset_dir: Path, output_dir: Path, external: dict[str, Any] | None = None, semantic_adapter: str | Callable[[dict[str, Any]], dict[str, Any]] | None = None) -> dict[str, Any]:
    contract = load_eval_contract(dataset_dir)
    metric_ids = {metric["id"] for metric in contract["rubric"]["metrics"]}
    adapter = _load_adapter(semantic_adapter) if semantic_adapter else None
    service = InsightService()
    results = []
    for case in contract["cases"]:
        started = time.perf_counter()
        package = service.build_local_extractive(case["transcript"])
        elapsed = (time.perf_counter() - started) * 1000
        result = evaluate_package(case, package, elapsed)
        _apply_semantic_adapter(adapter, leg="local", case=case, package=package, result=result, metric_ids=metric_ids)
        results.append(result)

    external_leg: dict[str, Any] = {
        "status": "unobserved",
        "missing_prerequisite": "explicit adapter configuration (--external-vendor) was not provided",
    }
    if external:
        external_leg = {
            "status": "observed",
            "provider": external["vendor"],
            "model": external.get("model", ""),
            "implementation_version": external.get("implementation_version", "InsightService.build_final"),
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
                _apply_semantic_adapter(adapter, leg="external", case=case, package=package, result=case_result, metric_ids=metric_ids)
                external_leg["cases"].append(case_result)
            except Exception as exc:
                lower = str(exc).lower()
                if not external_leg["cases"] and any(marker in lower for marker in ("missing api key", "未配置 api key", "credential")):
                    external_leg = {
                        "status": "unobserved",
                        "provider": external["vendor"],
                        "model": external.get("model", ""),
                        "implementation_version": external.get("implementation_version", "InsightService.build_final"),
                        "missing_prerequisite": "provider credentials are not configured",
                    }
                    break
                elapsed = (time.perf_counter() - started) * 1000
                external_leg["cases"].append({
                    "case": case["id"],
                    "gate_result": "fail",
                    "failures": [_failure(case["id"], "failure_behavior", "configured baseline returns a valid InsightPackageV1 or an explicit prerequisite is absent", f"external baseline raised {type(exc).__name__}", "external.execution")],
                    "diagnostics": {"latency_ms": round(elapsed, 3)},
                })
                break
        if external_leg["status"] == "observed" and any(case["gate_result"] == "fail" for case in external_leg["cases"]):
            external_leg["gate_result"] = "fail"

    report = {
        "report_version": "smart-minutes-eval-report-v1",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "dataset": {"version": contract["dataset_version"], "sha256": contract["dataset_sha256"]},
        "rubric": {"version": contract["rubric"]["rubric_version"], "policy": contract["rubric"]["policy"]},
        "gate_result": "fail" if any(item["gate_result"] == "fail" for item in results) or external_leg.get("gate_result") == "fail" else "pass",
        "legs": {"local": {"status": "observed", "provider": "local-extractive", "model": "heuristic-v1", "implementation_version": "InsightService.build_local_extractive"}, "external": external_leg},
        "cases": results,
    }
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "smart-minutes-eval.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (output_dir / "smart-minutes-eval.md").write_text(_markdown(report), encoding="utf-8")
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-dir", type=Path, default=DEFAULT_DATASET)
    parser.add_argument("--output-dir", type=Path, default=ROOT / "logs/smart-minutes-eval/local")
    parser.add_argument("--external-vendor")
    parser.add_argument("--external-model", default="")
    parser.add_argument("--semantic-adapter", help="approved synthetic-only evaluator as module:function")
    args = parser.parse_args()
    external = {"vendor": args.external_vendor, "model": args.external_model} if args.external_vendor else None
    report = run_eval(args.dataset_dir, args.output_dir, external=external, semantic_adapter=args.semantic_adapter)
    print(json.dumps({"gate_result": report["gate_result"], "dataset": report["dataset"], "output_dir": str(args.output_dir)}, ensure_ascii=False))
    return 0 if report["gate_result"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
