#!/usr/bin/env python3
"""Read bounded product evidence for an AI investigation; never dispatch or mutate a task."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlsplit, urlunsplit

if __package__:
    from .evidence_ledger import EvidenceLedger, ValidationError, _load_json, _walk
else:
    from evidence_ledger import EvidenceLedger, ValidationError, _load_json, _walk


ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "YannJY02/AutoTranscribe"
SHA = re.compile(r"^[0-9a-f]{40}$")
INSTALLED_SHA = re.compile(r"^[0-9a-f]{7,40}$")
MAX_BYTES = 2_000_000
MAX_RECORDS = 100


class ObservationUnavailable(ValueError):
    """A source cannot be read or trusted; its contents must not reach the packet."""


def _timestamp(value: Any) -> datetime:
    if not isinstance(value, str):
        raise ValueError("invalid timestamp")
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("timestamp lacks timezone")
    return parsed.astimezone(timezone.utc)


def _revision(value: Any) -> str | None:
    return value if isinstance(value, str) and SHA.fullmatch(value) else None


def _installed_revision(value: Any) -> str | None:
    # The packaged app records git rev-parse --short HEAD; CI requires a full SHA.
    return value if isinstance(value, str) and INSTALLED_SHA.fullmatch(value) else None


def _safe_reference(value: str) -> str:
    parsed = urlsplit(value)
    reference = urlunsplit((parsed.scheme, parsed.netloc, parsed.path, "", "")) if parsed.scheme else value
    # Query/fragment data is unnecessary for evidence identity. Decode only for
    # privacy validation, keeping the approved host/path and repository refs intact.
    decoded = reference
    while True:
        _walk(decoded)
        unescaped = unquote(decoded, errors="strict")
        if unescaped == decoded:
            return reference
        decoded = unescaped


def _boolean(value: Any) -> bool | None:
    return value if type(value) is bool else None


def _count(value: Any) -> int | None:
    return value if type(value) is int and 0 <= value <= 1_000_000 else None


def _command_json(command: list[str], *, root: Path) -> Any:
    try:
        result = subprocess.run(command, cwd=root, capture_output=True, text=True, timeout=30, check=False)
        if result.returncode or len(result.stdout.encode()) > MAX_BYTES:
            raise ObservationUnavailable("source request failed")
        return _load_json(result.stdout)
    except (OSError, subprocess.TimeoutExpired, ValueError) as error:
        # Do not include stderr, arbitrary remote fields, or environment values.
        raise ObservationUnavailable("source unavailable") from error


def collect_runtime(root: Path) -> dict[str, Any]:
    try:
        raw = _command_json(
            [sys.executable, str(root / "scripts/agent_harness.py"), "runtime-status", "--json"], root=root
        )
        repository, installed, symphony, telemetry = (
            raw[key] for key in ("repository", "installed_app", "symphony", "telemetry")
        )
        observed_at = _timestamp(raw["observed_at"]).isoformat()
        freshness = installed.get("freshness")
        if freshness not in {"current", "stale", "missing", "unknown"}:
            freshness = "unknown"
        # runtime-status knows the private app path; this projection never exports it.
        return {
            "availability": "available",
            "observed_at": observed_at,
            "revision": _revision(repository.get("revision")),
            "main_revision": _revision(repository.get("main_revision")),
            "main_revision_source": "remote" if repository.get("main_revision_source") == "remote" else "unavailable",
            "checkout_dirty": _boolean(repository.get("dirty")),
            "installed_revision": _installed_revision(installed.get("git_revision")),
            "installed": _boolean(installed.get("installed")),
            "installed_freshness": freshness,
            "running": _boolean(installed.get("running")),
            "symphony_reachable": _boolean(symphony.get("healthy")),
            "symphony_running_count": _count(symphony.get("running_count")),
            "symphony_blocked_count": _count(symphony.get("blocked_count")),
            "symphony_retrying_count": _count(symphony.get("retrying_count")),
            "telemetry_file_presence": {
                name: _boolean(telemetry.get(name))
                for name in ("product_analytics_ledger_exists", "sentry_disable_evidence_exists")
            },
        }
    except (ObservationUnavailable, KeyError, TypeError, AttributeError, ValueError):
        return {"availability": "unavailable", "reason": "runtime.observation-unavailable"}


def collect_ci(root: Path, *, main_revision: str | None) -> dict[str, Any]:
    if not main_revision:
        return {"availability": "unobserved", "result": "unobserved", "reason": "ci.remote-revision-unavailable"}
    try:
        runs = _command_json(
            ["gh", "run", "list", "--repo", REPOSITORY, "--branch", "main", "--workflow", "CI",
             "--limit", "10", "--json", "databaseId,headSha,status,conclusion,updatedAt"], root=root
        )
        if not isinstance(runs, list) or any(not isinstance(run, dict) for run in runs):
            raise ObservationUnavailable("invalid runs")
        matching = [run for run in runs if run.get("headSha") == main_revision]
        if not matching:
            return {"availability": "available", "result": "unobserved", "reason": "ci.current-revision-unobserved"}
        run = max(matching, key=lambda item: _timestamp(item["updatedAt"]))
        run_id = run["databaseId"]
        if type(run_id) is not int or run_id <= 0:
            raise ObservationUnavailable("invalid run identifier")
        if run["status"] != "completed":
            result, reason = "unobserved", "ci.not-completed"
        elif run["conclusion"] == "success":
            result, reason = "passed", "ci.completed"
        elif run["conclusion"] in {"failure", "timed_out", "startup_failure"}:
            result, reason = "failed", "ci.completed"
        else:
            result, reason = "unobserved", "ci.no-verdict"
        return {
            "availability": "available", "result": result, "reason": reason,
            "revision": main_revision, "run_id": run_id,
            "source_ref": f"https://github.com/{REPOSITORY}/actions/runs/{run_id}",
            "observed_at": _timestamp(run["updatedAt"]).isoformat(),
        }
    except (ObservationUnavailable, KeyError, TypeError, ValueError):
        return {"availability": "unavailable", "result": "unobserved", "reason": "ci.observation-unavailable"}


def collect_ledger(root: Path, ref: str, *, revision: str | None, now: datetime, max_age: timedelta) -> dict[str, Any]:
    """Use the existing ledger schema, then export only metadata, never claim prose."""
    path = (root / ref).resolve()
    if not path.is_relative_to(root.resolve()) or Path(ref).is_absolute():
        raise ValueError("ledger must be a repository-relative path inside the checkout")
    safe_ref = _safe_reference(path.relative_to(root.resolve()).as_posix())
    base = {"source_ref": safe_ref}
    if not path.is_file():
        return base | {"availability": "unobserved", "reason": "ledger.missing", "records": []}
    try:
        with path.open("rb") as stream:
            encoded = stream.read(MAX_BYTES + 1)
        if len(encoded) > MAX_BYTES:
            raise ValidationError("ledger too large")
        ledger = EvidenceLedger._validate_ledger(_load_json(encoded))
        records = [record for record in ledger["records"] if record["result"] != "superseded"]
        records.sort(key=lambda item: _timestamp(item["observed_at"]), reverse=True)
        selected = []
        for record in records[:MAX_RECORDS]:
            age = now - _timestamp(record["observed_at"])
            freshness = "current" if timedelta(0) <= age <= max_age else "stale" if age > max_age else "unverifiable"
            selected.append({
                key: record[key] for key in (
                    "evidence_id", "linear_issue_id", "github_issue_or_pr_id", "source_type",
                    "revision", "observed_at", "result", "claim_class", "lifecycle_stage", "unknowns",
                )
            } | {
                "source_ref": _safe_reference(record["source_ref"]),
                "freshness": freshness,
                "revision_matches_checkout": bool(revision and record["revision"] == revision),
            })
        return base | {"availability": "available", "records": selected, "active_record_count": len(records),
                       "truncated": len(records) > MAX_RECORDS}
    except (OSError, ValueError, KeyError, TypeError):
        return base | {"availability": "unavailable", "reason": "ledger.invalid-or-unreadable", "records": []}


def investigation_candidates(runtime: dict[str, Any], ci: dict[str, Any], ledgers: list[dict[str, Any]]) -> list[dict[str, Any]]:
    candidates: list[dict[str, Any]] = []

    def add(code: str, question: str, refs: list[str]) -> None:
        candidates.append({"id": code, "claim_class": "inference", "question": question, "evidence_refs": refs})

    if ci["result"] == "failed":
        add("ci.current-failure", "Inspect current main CI and reproduce one failing check; classify product, test, or environment cause.", [ci["source_ref"]])
    elif ci.get("reason") != "ci.not-completed" and ci["result"] == "unobserved":
        add("ci.coverage-unknown", "Restore current-main CI observation before making a build-health claim.", [])
    if runtime.get("availability") != "available":
        add("runtime.coverage-unknown", "Read the bounded runtime status before selecting a build for comparison.", [])
    elif runtime.get("installed_freshness") in {"stale", "missing", "unknown"}:
        add("runtime.build-comparison", "Establish which installed build can exercise the chosen journey before comparing behavior.", ["scripts/agent_harness.py"])
    for ledger in ledgers:
        if ledger["availability"] != "available":
            add("ledger.coverage-unknown", "Recover or replace the missing evidence reference; do not interpret absent evidence as a failed product.", [ledger["source_ref"]])
            continue
        for record in ledger["records"]:
            if record["result"] in {"failed", "blocked", "unobserved"}:
                add(record["evidence_id"], "Recheck one recorded gap against the current task and exact build; historical evidence alone does not establish a current defect.", [record["source_ref"]])
    # Healthy infrastructure never establishes usefulness or visual quality.
    add("product.journey-comparison", "Choose one accepted user journey, explore it with CUA and representative data, and compare actual behavior with its requirements; preserve before evidence for one bounded improvement.", [])
    return candidates


def observe(*, root: Path = ROOT, ledger_refs: list[str] | None = None,
            now: datetime | None = None, max_age_hours: int = 24) -> dict[str, Any]:
    now = now or datetime.now(timezone.utc)
    if now.tzinfo is None or not 1 <= max_age_hours <= 8760:
        raise ValueError("timezone-aware observation and freshness window of 1..8760 hours required")
    runtime = collect_runtime(root)
    main_revision = runtime.get("main_revision") if runtime.get("main_revision_source") == "remote" else None
    ci = collect_ci(root, main_revision=main_revision)
    ledgers = [collect_ledger(root, ref, revision=runtime.get("revision"), now=now,
                              max_age=timedelta(hours=max_age_hours)) for ref in dict.fromkeys(ledger_refs or [])]
    packet = {
        "schema_version": 1, "observed_at": now.isoformat(), "authority": "advisory-observation",
        "task_source": "linear", "delivery_source": "github", "freshness_window_hours": max_age_hours,
        "runtime": runtime, "ci": ci, "ledgers": ledgers,
        "investigation_candidates": investigation_candidates(runtime, ci, ledgers),
        "coverage_limits": ["task-priority.not-read", "subjective-quality.unobserved", "user-value.unobserved",
                            "telemetry-delivery.not-proven", "runtime-file-presence.not-functional-proof"],
    }
    _walk(packet)
    return packet


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("observe",))
    parser.add_argument("--ledger", action="append", default=[], help="Existing repository-relative evidence ledger; repeatable.")
    parser.add_argument("--max-age-hours", type=int, default=24, help="Metadata freshness window, not a product quality threshold.")
    parser.add_argument("--output", type=Path, help="Explicitly save a new local packet; existing files are never overwritten.")
    args = parser.parse_args(argv)
    try:
        packet = observe(ledger_refs=args.ledger, max_age_hours=args.max_age_hours)
        encoded = json.dumps(packet, indent=2, ensure_ascii=False) + "\n"
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            with args.output.open("x", encoding="utf-8") as stream:
                stream.write(encoded)
        else:
            print(encoded, end="")
        return 0
    except (OSError, ValueError):
        print("product observation could not be produced; check input paths and output availability", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
