from __future__ import annotations

import json
import subprocess
from datetime import datetime, timedelta, timezone

import pytest

from scripts import product_iteration as iteration
from scripts.evidence_ledger import EvidenceLedger


REVISION = "a" * 40
OLDER = "b" * 40
NOW = datetime(2026, 9, 5, 8, tzinfo=timezone.utc)


def runtime_payload(**repository_changes):
    return {
        "observed_at": NOW.isoformat(),
        "repository": {"revision": REVISION, "main_revision": REVISION,
                       "main_revision_source": "remote", "dirty": False, **repository_changes},
        "installed_app": {"installed": True, "running": True, "freshness": "current",
                          "git_revision": REVISION, "path": "/Users/private/Applications/InsightKit.app"},
        "symphony": {"healthy": True, "running_count": 0, "blocked_count": 0, "retrying_count": 0},
        "telemetry": {"product_analytics_ledger_exists": True, "sentry_disable_evidence_exists": True},
    }


def ci_run(**changes):
    return {"databaseId": 100, "headSha": REVISION, "status": "completed", "conclusion": "success",
            "updatedAt": NOW.isoformat(), **changes}


def install_sources(monkeypatch, *, runtime=None, runs=None):
    def command(command, *, root):
        if command[0] == "gh":
            return [ci_run()] if runs is None else runs
        return runtime_payload() if runtime is None else runtime
    monkeypatch.setattr(iteration, "_command_json", command)


def write_ledger(path, **changes):
    item = {
        "linear_issue_id": "YAN-50", "github_issue_or_pr_id": "GH-68", "lifecycle_stage": "verification",
        "lifecycle_transition": "journey-completed", "source_type": "repository", "source_id": "journey-101",
        "source_ref": "pilots/evidence/journey-101.json", "revision": REVISION,
        "artifact_sha256": "sha256:" + "c" * 64, "observed_at": NOW.isoformat(), "environment": "owner-pilot",
        "result": "failed", "claim_class": "observed", "promotion_category": "gate",
        "privacy_class": "repository-metadata", "fact": "Recorded workflow failure.",
        "gap_or_decision": "Reproduce one workflow failure.", "owner_action": "AI diagnoses the bounded failure.",
        "recheck_source": "pilots/evidence/journey-101.json", "human_gate": "None.", "unknowns": [],
        **changes,
    }
    EvidenceLedger(path)._collect_normalized([item])


def test_observation_does_not_turn_healthy_infrastructure_into_product_acceptance(monkeypatch, tmp_path):
    raw = runtime_payload()
    raw["installed_app"]["api_key"] = "sk-" + "private" * 8
    install_sources(monkeypatch, runtime=raw)

    packet = iteration.observe(root=tmp_path, now=NOW)

    assert packet["ci"]["result"] == "passed"
    assert packet["investigation_candidates"][-1]["id"] == "product.journey-comparison"
    assert "user-value.unobserved" in packet["coverage_limits"]
    assert "private" not in json.dumps(packet)
    assert "api_key" not in json.dumps(packet)
    assert list(tmp_path.iterdir()) == []


@pytest.mark.parametrize("failure", ["exit", "timeout", "invalid-json"])
def test_remote_failure_is_unknown_without_exporting_error_text(monkeypatch, tmp_path, failure):
    def run(command, **kwargs):
        if command[0] != "gh":
            return subprocess.CompletedProcess(command, 0, json.dumps(runtime_payload()), "")
        if failure == "timeout":
            raise subprocess.TimeoutExpired(command, 30, stderr="Bearer private-access-value")
        return subprocess.CompletedProcess(command, 1 if failure == "exit" else 0,
                                           "not-json", "Bearer private-access-value")
    monkeypatch.setattr(iteration.subprocess, "run", run)

    packet = iteration.observe(root=tmp_path, now=NOW)

    assert packet["ci"]["availability"] == "unavailable"
    assert packet["ci"]["result"] == "unobserved"
    assert "ci.current-failure" not in {item["id"] for item in packet["investigation_candidates"]}
    assert "private-access-value" not in json.dumps(packet)


def test_green_ci_for_an_old_revision_cannot_pass_current_main(monkeypatch, tmp_path):
    install_sources(monkeypatch, runs=[ci_run(headSha=OLDER)])
    packet = iteration.observe(root=tmp_path, now=NOW)
    assert packet["ci"]["result"] == "unobserved"
    assert packet["ci"]["reason"] == "ci.current-revision-unobserved"


@pytest.mark.parametrize(("status", "conclusion", "expected"), [
    ("completed", "failure", "failed"), ("completed", "timed_out", "failed"),
    ("completed", "cancelled", "unobserved"), ("completed", "skipped", "unobserved"),
    ("in_progress", "", "unobserved"),
])
def test_ci_verdict_requires_a_completed_matching_run(monkeypatch, tmp_path, status, conclusion, expected):
    install_sources(monkeypatch, runs=[ci_run(status=status, conclusion=conclusion)])
    packet = iteration.observe(root=tmp_path, now=NOW)
    assert packet["ci"]["result"] == expected
    if status == "in_progress":
        assert "ci.coverage-unknown" not in {item["id"] for item in packet["investigation_candidates"]}


def test_remote_main_fallback_never_claims_ci_for_local_head(monkeypatch, tmp_path):
    calls = []
    def command(command, *, root):
        calls.append(command)
        assert command[0] != "gh"
        return runtime_payload(main_revision_source="local-head-fallback")
    monkeypatch.setattr(iteration, "_command_json", command)
    packet = iteration.observe(root=tmp_path, now=NOW)
    assert packet["ci"]["reason"] == "ci.remote-revision-unavailable"
    assert len(calls) == 1


def test_newer_pending_run_supersedes_prior_green_for_the_same_commit(monkeypatch, tmp_path):
    install_sources(monkeypatch, runs=[
        ci_run(), ci_run(databaseId=101, status="queued", conclusion="",
                         updatedAt=(NOW + timedelta(minutes=1)).isoformat()),
    ])
    assert iteration.observe(root=tmp_path, now=NOW)["ci"]["result"] == "unobserved"


def test_stale_ledger_retains_result_and_marks_comparison_limit(monkeypatch, tmp_path):
    install_sources(monkeypatch)
    write_ledger(tmp_path / "ledger.json", revision=OLDER, observed_at=(NOW - timedelta(days=2)).isoformat())
    packet = iteration.observe(root=tmp_path, ledger_refs=["ledger.json"], now=NOW)
    record = packet["ledgers"][0]["records"][0]
    assert record["result"] == "failed"
    assert record["freshness"] == "stale"
    assert record["revision_matches_checkout"] is False
    assert record["linear_issue_id"] == "YAN-50"
    assert record["source_ref"] == "pilots/evidence/journey-101.json"
    assert "fact" not in record
    candidate = next(item for item in packet["investigation_candidates"] if item["id"] == record["evidence_id"])
    assert candidate["claim_class"] == "inference"
    assert "historical evidence alone" in candidate["question"]


def test_missing_and_invalid_ledgers_do_not_become_product_failure(monkeypatch, tmp_path):
    install_sources(monkeypatch)
    (tmp_path / "invalid.json").write_text('{"transcript":"private meeting text"}')
    packet = iteration.observe(root=tmp_path, ledger_refs=["missing.json", "invalid.json"], now=NOW)
    assert [item["availability"] for item in packet["ledgers"]] == ["unobserved", "unavailable"]
    assert all(item["records"] == [] for item in packet["ledgers"])
    assert "private meeting text" not in json.dumps(packet)
    assert not (tmp_path / "missing.json").exists()


def test_ledger_cannot_follow_a_symlink_outside_the_checkout(monkeypatch, tmp_path):
    install_sources(monkeypatch)
    checkout = tmp_path / "checkout"
    checkout.mkdir()
    (tmp_path / "outside.json").write_text("{}")
    (checkout / "ledger.json").symlink_to(tmp_path / "outside.json")
    with pytest.raises(ValueError, match="inside the checkout"):
        iteration.observe(root=checkout, ledger_refs=["ledger.json"], now=NOW)


def test_cli_writes_only_when_requested_and_preserves_existing_packet(monkeypatch, tmp_path, capsys):
    install_sources(monkeypatch)
    monkeypatch.chdir(tmp_path)
    assert iteration.main(["observe"]) == 0
    assert json.loads(capsys.readouterr().out)["authority"] == "advisory-observation"
    assert list(tmp_path.iterdir()) == []

    output = tmp_path / "observation.json"
    assert iteration.main(["observe", "--output", str(output)]) == 0
    prior = output.read_bytes()
    assert iteration.main(["observe", "--output", str(output)]) == 2
    assert output.read_bytes() == prior


def test_stale_installation_is_comparison_gap_not_claimed_application_failure(monkeypatch, tmp_path):
    raw = runtime_payload()
    raw["installed_app"].update(freshness="stale", git_revision=OLDER)
    install_sources(monkeypatch, runtime=raw)
    packet = iteration.observe(root=tmp_path, now=NOW)
    assert packet["runtime"]["installed_freshness"] == "stale"
    assert "runtime.build-comparison" in {item["id"] for item in packet["investigation_candidates"]}
    assert packet["ci"]["result"] == "passed"


def test_actual_packaged_short_revision_survives_runtime_projection(monkeypatch, tmp_path):
    raw = runtime_payload()
    raw["installed_app"].update(freshness="stale", git_revision="19d19e4")
    install_sources(monkeypatch, runtime=raw)

    packet = iteration.observe(root=tmp_path, now=NOW)

    assert packet["runtime"]["installed_revision"] == "19d19e4"
    assert packet["runtime"]["installed_freshness"] == "stale"
    assert packet["runtime"]["revision"] == REVISION
    assert packet["ci"]["revision"] == REVISION


@pytest.mark.parametrize("invalid", ["19d19e", "a" * 41, "not-hex", None])
def test_installed_revision_remains_bounded_and_main_requires_full_sha(monkeypatch, tmp_path, invalid):
    raw = runtime_payload(revision="19d19e4", main_revision="19d19e4")
    raw["installed_app"]["git_revision"] = invalid
    install_sources(monkeypatch, runtime=raw)

    packet = iteration.observe(root=tmp_path, now=NOW)

    assert packet["runtime"]["installed_revision"] is None
    assert packet["runtime"]["revision"] is None
    assert packet["runtime"]["main_revision"] is None
    assert packet["ci"]["result"] == "unobserved"


def test_external_evidence_queries_and_fragments_never_reach_packet_or_candidates(monkeypatch, tmp_path):
    install_sources(monkeypatch)
    reference = "https://us.posthog.com/project/1/insights/2?auth=sk%2D" + "synthetic" * 5 + "#private-fragment"
    write_ledger(tmp_path / "ledger.json", source_type="analytics", source_ref=reference)

    packet = iteration.observe(root=tmp_path, ledger_refs=["ledger.json"], now=NOW)

    clean = "https://us.posthog.com/project/1/insights/2"
    assert packet["ledgers"][0]["records"][0]["source_ref"] == clean
    candidate = next(item for item in packet["investigation_candidates"] if clean in item["evidence_refs"])
    assert candidate["evidence_refs"] == [clean]
    assert "auth=" not in json.dumps(packet)
    assert "synthetic" not in json.dumps(packet)
    assert "private-fragment" not in json.dumps(packet)
    assert reference in (tmp_path / "ledger.json").read_text()


def test_encoded_secret_in_external_path_is_unavailable_without_leaking(monkeypatch, tmp_path):
    install_sources(monkeypatch)
    reference = "https://us.posthog.com/project/1/insights/sk%252D" + "synthetic" * 5
    write_ledger(tmp_path / "ledger.json", source_type="analytics", source_ref=reference)

    packet = iteration.observe(root=tmp_path, ledger_refs=["ledger.json"], now=NOW)

    assert packet["ledgers"][0]["availability"] == "unavailable"
    assert packet["ledgers"][0]["records"] == []
    assert "synthetic" not in json.dumps(packet)
