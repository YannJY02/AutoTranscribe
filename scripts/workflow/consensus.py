"""Multi-reviewer consensus for each iteration round."""

from __future__ import annotations

from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
import json
from typing import Any


@dataclass
class ReviewFinding:
    reviewer: str
    review_round: int
    title: str
    detail: str
    evidence: str
    blocking: bool
    gap_id: str = ""


def _failed_gates(gates: dict[str, Any]) -> list[str]:
    failed: list[str] = []
    for key in ("swift_test", "python_test", "package_smoke", "runtime_smoke", "compliance_scan"):
        payload = gates.get(key, {})
        if not payload.get("ok", False):
            failed.append(key)
    return failed


def _security_review(
    review_round: int,
    gates: dict[str, Any],
    target_results: list[dict[str, Any]],
) -> list[ReviewFinding]:
    findings: list[ReviewFinding] = []
    failed = _failed_gates(gates)
    if failed:
        findings.append(
            ReviewFinding(
                reviewer="security",
                review_round=review_round,
                title="Core gates failed",
                detail=f"Blocking due to failed gates: {', '.join(failed)}",
                evidence=f"failed_gates={','.join(failed)}",
                blocking=True,
            )
        )

    blocked_targets = [x for x in target_results if x.get("status") == "blocked"]
    for item in blocked_targets:
        findings.append(
            ReviewFinding(
                reviewer="security",
                review_round=review_round,
                title="Gap marked blocked",
                detail=item.get("notes", "gap unresolved"),
                evidence=f"gap_id={item.get('gap_id', '')}",
                blocking=True,
                gap_id=item.get("gap_id", ""),
            )
        )

    fallback_count = int(gates.get("fallback_review_items", 0))
    if fallback_count > 0:
        findings.append(
            ReviewFinding(
                reviewer="security",
                review_round=review_round,
                title="Fallback review required",
                detail=f"{fallback_count} item(s) marked needs_review=true.",
                evidence=f"fallback_review_items={fallback_count}",
                blocking=False,
            )
        )
    return findings


def _policy_review(
    review_round: int,
    gates: dict[str, Any],
) -> list[ReviewFinding]:
    findings: list[ReviewFinding] = []
    compliance = gates.get("compliance_scan", {})
    if not compliance.get("ok", False):
        findings.append(
            ReviewFinding(
                reviewer="policy",
                review_round=review_round,
                title="Compliance scan failed",
                detail=f"{compliance.get('finding_count', 0)} banned-term hit(s).",
                evidence=f"finding_count={compliance.get('finding_count', 0)}",
                blocking=True,
            )
        )
    return findings


def _execution_review(
    review_round: int,
    target_results: list[dict[str, Any]],
    unresolved_after: dict[str, int],
) -> list[ReviewFinding]:
    findings: list[ReviewFinding] = []
    unresolved_targets = [x for x in target_results if x.get("status") != "resolved"]
    if unresolved_targets:
        findings.append(
            ReviewFinding(
                reviewer="execution",
                review_round=review_round,
                title="Round targets not closed",
                detail=f"{len(unresolved_targets)} target gap(s) are still unresolved.",
                evidence=f"unresolved_targets={len(unresolved_targets)}",
                blocking=True,
            )
        )

    if int(unresolved_after.get("P0", 0)) > 0 and any(x.get("severity") == "P1" for x in target_results):
        findings.append(
            ReviewFinding(
                reviewer="execution",
                review_round=review_round,
                title="P1 started before P0 clear",
                detail="P0 gaps still unresolved while P1 target selected.",
                evidence="phase_violation=P1_before_P0_clear",
                blocking=True,
            )
        )
    return findings


def run_two_round_consensus(
    round_id: int,
    gates: dict[str, Any],
    target_results: list[dict[str, Any]],
    unresolved_after: dict[str, int],
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    findings: list[ReviewFinding] = []
    for review_round in (1, 2):
        security_findings = _security_review(review_round, gates, target_results)
        policy_findings = _policy_review(review_round, gates)
        execution_findings = _execution_review(review_round, target_results, unresolved_after)

        if not security_findings:
            security_findings = [
                ReviewFinding(
                    reviewer="security",
                    review_round=review_round,
                    title="No blocking findings",
                    detail="Security checks passed in this review round.",
                    evidence=f"review_round={review_round}",
                    blocking=False,
                )
            ]
        if not policy_findings:
            policy_findings = [
                ReviewFinding(
                    reviewer="policy",
                    review_round=review_round,
                    title="No blocking findings",
                    detail="Policy checks passed in this review round.",
                    evidence=f"review_round={review_round}",
                    blocking=False,
                )
            ]
        if not execution_findings:
            execution_findings = [
                ReviewFinding(
                    reviewer="execution",
                    review_round=review_round,
                    title="No blocking findings",
                    detail="Execution checks passed in this review round.",
                    evidence=f"review_round={review_round}",
                    blocking=False,
                )
            ]

        findings.extend(security_findings)
        findings.extend(policy_findings)
        findings.extend(execution_findings)

    blocking_round_2 = any(f.review_round == 2 and f.blocking for f in findings)
    consensus = {
        "round": round_id,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "reviewers": ["security", "policy", "execution"],
        "review_rounds": 2,
        "blocking_in_round_2": blocking_round_2,
        "decision": "blocked" if blocking_round_2 else "approved",
    }
    return [asdict(x) for x in findings], consensus


def save_consensus_outputs(
    findings_path: Path,
    consensus_path: Path,
    findings: list[dict[str, Any]],
    consensus: dict[str, Any],
) -> None:
    findings_path.parent.mkdir(parents=True, exist_ok=True)
    findings_path.write_text(json.dumps(findings, ensure_ascii=False, indent=2), encoding="utf-8")
    consensus_path.parent.mkdir(parents=True, exist_ok=True)
    consensus_path.write_text(json.dumps(consensus, ensure_ascii=False, indent=2), encoding="utf-8")
