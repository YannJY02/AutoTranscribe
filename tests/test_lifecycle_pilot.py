import hashlib
import json
import shutil
import subprocess
from pathlib import Path
from types import SimpleNamespace

import pytest

from scripts.lifecycle_pilot import (
    ATTEMPT_ORDER,
    ROLLBACK_SOURCE_REFS,
    PilotValidationError,
    main,
    run_attempts,
    validate_rollback_proof,
    verify_manifest,
)

ROOT = Path(__file__).resolve().parents[1]
HEAD = "83746318b85db3b0882e467401e1f1ec5d5b1eaa"
PILOT = ROOT / "pilots/gh-73-owner-lifecycle.json"


def manifest():
    return json.loads(PILOT.read_text())


def copy_repository_evidence(destination: Path) -> None:
    subprocess.run(
        ["git", "clone", "--shared", "--no-checkout", str(ROOT), str(destination)],
        check=True,
        capture_output=True,
    )
    value = manifest()
    refs = [
        value["build"]["proof_ref"],
        value["evidence_ledger_ref"],
        *value["configuration"]["sql_refs"],
    ]
    refs += [ref for attempt in value["attempts"] for ref in attempt["evidence_refs"]]
    refs += [
        item["evidence_ref"]
        for item in value["reconciliation"].values()
        if item.get("evidence_ref")
    ]
    refs += value["rollback"]["evidence_refs"]
    refs += list(ROLLBACK_SOURCE_REFS)
    refs += [value["reconciliation"]["repository"]["harness_manifest_ref"]]
    refs += [
        json.loads((ROOT / value["build"]["proof_ref"]).read_text())["app_archive_ref"]
    ]
    for ref in refs:
        target = destination / ref
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / ref, target)


def test_truthful_manifest_is_partial_not_completed():
    proof = verify_manifest(
        manifest(), expected_commit=HEAD, now="2026-09-01T23:00:00Z"
    )

    assert proof["pilot_outcome"] == "partial"
    assert proof["attempt_counts"] == {"observed": 1, "inference": 0, "unobserved": 3}
    assert proof["production_readiness_claimed"] is False


def test_failed_observed_attempt_cannot_be_promoted_to_completed():
    value = manifest()
    value["attempts"][0]["result"] = "passed"

    with pytest.raises(PilotValidationError, match="every stage"):
        verify_manifest(value, expected_commit=HEAD, now="2026-09-01T23:00:00Z")


def test_completed_requires_all_four_paths_and_all_provider_readbacks():
    value = manifest()
    for attempt in value["attempts"]:
        attempt.update(classification="observed", result="passed", unknowns=[])
        attempt["stages"] = {stage: "observed" for stage in attempt["stages"]}
        attempt["evidence_refs"] = ["pilots/evidence/GH-73/live-local-proof.json"]
    for provider in ("posthog", "sentry", "langfuse"):
        value["reconciliation"][provider]["scope"] = "pilot-attempt"

    assert (
        verify_manifest(value, expected_commit=HEAD, now="2026-09-01T23:00:00Z")[
            "pilot_outcome"
        ]
        == "completed"
    )

    value["reconciliation"]["sentry"] = {
        "classification": "unobserved",
        "evidence_ref": None,
        "unknowns": ["readback.unavailable"],
    }
    value["claims"]["observed"].remove("reconciliation.sentry")
    assert (
        verify_manifest(value, expected_commit=HEAD, now="2026-09-01T23:00:00Z")[
            "pilot_outcome"
        ]
        == "partial"
    )


def test_prerequisite_readbacks_do_not_close_current_pilot():
    value = manifest()
    for attempt in value["attempts"]:
        attempt.update(classification="observed", result="passed", unknowns=[])
        attempt["stages"] = {stage: "observed" for stage in attempt["stages"]}
        attempt["evidence_refs"] = ["pilots/evidence/GH-73/live-local-proof.json"]

    proof = verify_manifest(value, expected_commit=HEAD, now="2026-09-01T23:00:00Z")

    assert proof["pilot_outcome"] == "partial"
    assert proof["external_readbacks"]["langfuse"] == {
        "classification": "observed",
        "scope": "prerequisite-synthetic",
    }


@pytest.mark.parametrize(
    "mutation",
    [
        lambda value: value.update(api_key="do-not-accept"),
        lambda value: value["attempts"][0].update(detail="api_key=do-not-accept"),
    ],
)
def test_shared_privacy_boundary_rejects_secret_fields_and_values(mutation):
    value = manifest()
    mutation(value)

    with pytest.raises(PilotValidationError, match="shared privacy boundary"):
        verify_manifest(value, expected_commit=HEAD, now="2026-09-01T23:00:00Z")


def test_posthog_requires_non_empty_exact_counts():
    value = manifest()
    value["reconciliation"]["posthog"]["remote_event_counts"]["workflow_started"] = 3
    with pytest.raises(PilotValidationError, match="counts do not reconcile"):
        verify_manifest(value, expected_commit=HEAD, now="2026-09-01T23:00:00Z")

    value = manifest()
    value["reconciliation"]["posthog"]["local_event_counts"] = {}
    value["reconciliation"]["posthog"]["remote_event_counts"] = {}
    with pytest.raises(PilotValidationError, match="non-empty"):
        verify_manifest(value, expected_commit=HEAD, now="2026-09-01T23:00:00Z")


def test_langfuse_preserves_score_and_observation_environment_distinction():
    value = manifest()
    value["reconciliation"]["langfuse"]["observation_environment"] = "owner-pilot"

    with pytest.raises(PilotValidationError, match="environment distinction"):
        verify_manifest(value, expected_commit=HEAD, now="2026-09-01T23:00:00Z")


def test_sentry_release_must_bind_the_read_back_build():
    value = manifest()
    value["reconciliation"]["sentry"]["build"] = "20260902000000"

    with pytest.raises(PilotValidationError, match="Sentry readback identity"):
        verify_manifest(value, expected_commit=HEAD, now="2026-09-01T23:00:00Z")


def test_fresh_checkout_verifies_committed_proof_without_ignored_app(tmp_path: Path):
    copy_repository_evidence(tmp_path)

    proof = verify_manifest(
        manifest(),
        expected_commit=HEAD,
        repository_root=tmp_path,
        now="2026-09-01T23:00:00Z",
    )

    assert proof["pilot_outcome"] == "partial"
    assert not (tmp_path / manifest()["build"]["app_bundle_ref"]).exists()


def test_repository_harness_commit_is_bound_separately_from_build(tmp_path: Path):
    copy_repository_evidence(tmp_path)
    value = manifest()
    value["reconciliation"]["repository"]["harness_commit"] = "0" * 40

    with pytest.raises(PilotValidationError, match="provider evidence is unrelated"):
        verify_manifest(
            value,
            expected_commit=HEAD,
            repository_root=tmp_path,
            now="2026-09-01T23:00:00Z",
        )


def test_local_artifact_verification_is_explicit_and_hash_bound(tmp_path: Path):
    copy_repository_evidence(tmp_path)
    with pytest.raises(PilotValidationError, match="app artifact hash"):
        verify_manifest(
            manifest(),
            expected_commit=HEAD,
            repository_root=tmp_path,
            now="2026-09-01T23:00:00Z",
            verify_app_artifact=True,
        )

    app = tmp_path / manifest()["build"]["app_bundle_ref"]
    app.mkdir(parents=True)
    (app / "marker").write_text("wrong")
    with pytest.raises(PilotValidationError, match="app artifact hash"):
        verify_manifest(
            manifest(),
            expected_commit=HEAD,
            repository_root=tmp_path,
            now="2026-09-01T23:00:00Z",
            verify_app_artifact=True,
        )


def test_shared_evidence_ledger_schema_is_enforced(tmp_path: Path):
    copy_repository_evidence(tmp_path)
    ledger = tmp_path / manifest()["evidence_ledger_ref"]
    ledger.write_text(
        '{"schema_version":1,"records":[{"source_id":"gh-73-owner-three-day-v1"}]}'
    )

    with pytest.raises(PilotValidationError, match="shared schema"):
        verify_manifest(
            manifest(),
            expected_commit=HEAD,
            repository_root=tmp_path,
            now="2026-09-01T23:00:00Z",
        )


def test_referenced_evidence_rejects_unknown_content_fields(tmp_path: Path):
    copy_repository_evidence(tmp_path)
    evidence = tmp_path / manifest()["reconciliation"]["langfuse"]["evidence_ref"]
    payload = json.loads(evidence.read_text())
    payload["detail"] = "arbitrary content is outside the evidence schema"
    evidence.write_text(json.dumps(payload))

    with pytest.raises(PilotValidationError, match="langfuse evidence fields"):
        verify_manifest(
            manifest(),
            expected_commit=HEAD,
            repository_root=tmp_path,
            now="2026-09-01T23:00:00Z",
        )


@pytest.mark.parametrize(
    "provider,field,value,message",
    [
        ("posthog", "event_count", 0, "PostHog evidence"),
        ("sentry", "project_id", "unrelated", "Sentry evidence"),
        ("langfuse", "score_count", 0, "Langfuse evidence"),
    ],
)
def test_provider_evidence_must_match_manifest_readback(
    tmp_path: Path, provider, field, value, message
):
    copy_repository_evidence(tmp_path)
    evidence = tmp_path / manifest()["reconciliation"][provider]["evidence_ref"]
    payload = json.loads(evidence.read_text())
    payload[field] = value
    evidence.write_text(json.dumps(payload))

    with pytest.raises(PilotValidationError, match=message):
        verify_manifest(
            manifest(),
            expected_commit=HEAD,
            repository_root=tmp_path,
            now="2026-09-01T23:00:00Z",
        )


def test_durable_app_archive_binds_default_fresh_checkout(tmp_path: Path):
    copy_repository_evidence(tmp_path)
    proof_path = tmp_path / manifest()["build"]["proof_ref"]
    proof = json.loads(proof_path.read_text())
    proof["app_bundle_sha256"] = "0" * 64
    proof_path.write_text(json.dumps(proof))

    with pytest.raises(PilotValidationError, match="exact build identity"):
        verify_manifest(
            manifest(),
            expected_commit=HEAD,
            repository_root=tmp_path,
            now="2026-09-01T23:00:00Z",
        )


def test_rollback_source_hash_comes_from_frozen_git_commit(tmp_path: Path):
    copy_repository_evidence(tmp_path)
    changed = tmp_path / ROLLBACK_SOURCE_REFS[0]
    changed.write_text(changed.read_text() + "\n// tampered after frozen commit\n")
    digest = hashlib.sha256()
    for ref in ROLLBACK_SOURCE_REFS:
        digest.update(ref.encode())
        digest.update(b"\0")
        digest.update((tmp_path / ref).read_bytes())
    rollback = tmp_path / manifest()["rollback"]["evidence_refs"][0]
    proof = json.loads(rollback.read_text())
    proof["test_source_sha256"] = digest.hexdigest()
    rollback.write_text(json.dumps(proof))

    with pytest.raises(PilotValidationError, match="test source changed"):
        verify_manifest(
            manifest(),
            expected_commit=HEAD,
            repository_root=tmp_path,
            now="2026-09-01T23:00:00Z",
        )


def test_rollback_binds_target_test_source_and_unchanged_evidence():
    value = manifest()
    proof = json.loads((ROOT / value["rollback"]["evidence_refs"][0]).read_text())
    app_sha = json.loads((ROOT / value["build"]["proof_ref"]).read_text())[
        "app_bundle_sha256"
    ]

    validate_rollback_proof(
        proof,
        rollback=value["rollback"],
        app_bundle_ref=value["build"]["app_bundle_ref"],
        app_sha=app_sha,
    )

    broken = dict(proof, evidence_sha256_after="0" * 64)
    with pytest.raises(PilotValidationError, match="preserve evidence"):
        validate_rollback_proof(
            broken,
            rollback=value["rollback"],
            app_bundle_ref=value["build"]["app_bundle_ref"],
            app_sha=app_sha,
        )


def test_runner_executes_exact_locked_order_and_records_each_exit(
    tmp_path: Path, monkeypatch
):
    commands = []
    lock = [
        "python3.11",
        "scripts/agent_harness.py",
        "lock",
        "--resource",
        "installed-app",
        "--timeout",
        "1800",
        "--",
    ]
    monkeypatch.setattr(
        "scripts.lifecycle_pilot.subprocess.run",
        lambda command, **kwargs: (
            commands.append(command) or SimpleNamespace(returncode=0)
        ),
    )

    proof = run_attempts(manifest(), repository_root=tmp_path)

    assert proof["status"] == "executed"
    assert [item["id"] for item in proof["results"]] == list(ATTEMPT_ORDER)
    assert all(command[: len(lock)] == lock for command in commands)
    assert all(item["execution"] == "succeeded" for item in proof["results"])
    assert all(item["attempt_result_claimed"] is False for item in proof["results"])
    assert any(
        "LiveWorkspaceTests/testSingleEntryGeneratedReviewFlowCoversPrimaryInteractions"
        in part
        for part in commands[0]
    )
    assert any(
        "TranscriptionWorkspaceTests/testTranscriptionWorkspaceVisible" in part
        for part in commands[2]
    )
    assert all(
        any(
            "NavigationTests/testRunnerAnalysisModeOverride" in part for part in command
        )
        for command in commands
    )


def test_runner_rejects_manifest_command_injection_and_secret_like_values(
    tmp_path: Path,
):
    value = manifest()
    value["attempts"][0]["command"] = ["bash", "-c", "touch escaped"]
    with pytest.raises(PilotValidationError, match="attempt fields"):
        run_attempts(value, repository_root=tmp_path)

    value = manifest()
    value["attempts"][0]["api_key"] = "do-not-accept"
    with pytest.raises(PilotValidationError, match="shared privacy boundary"):
        run_attempts(value, repository_root=tmp_path)


def test_runner_cli_derives_commands_from_frozen_manifest(tmp_path: Path, monkeypatch):
    monkeypatch.setattr(
        "scripts.lifecycle_pilot.subprocess.run",
        lambda command, **kwargs: SimpleNamespace(returncode=0),
    )
    output = tmp_path / "runner-proof.json"

    assert main(["run-attempts", str(PILOT), "--output", str(output)]) == 0
    assert json.loads(output.read_text())["status"] == "executed"


def test_cli_writes_canonical_proof_from_a_fresh_checkout(tmp_path: Path, monkeypatch):
    copy_repository_evidence(tmp_path)
    source = tmp_path / "pilots/gh-73-owner-lifecycle.json"
    source.parent.mkdir(parents=True, exist_ok=True)
    source.write_text(PILOT.read_text())
    output = tmp_path / "pilot-proof.json"
    monkeypatch.chdir(tmp_path)

    assert (
        main(
            ["verify", str(source), "--expected-commit", HEAD, "--output", str(output)]
        )
        == 0
    )
    assert json.loads(output.read_text())["pilot_outcome"] == "partial"


def test_cli_failure_is_bounded_and_does_not_echo_private_input(tmp_path: Path, capsys):
    source = tmp_path / "pilot.json"
    source.write_text(json.dumps({"api_key": "DO-NOT-REFLECT"}))

    assert (
        main(
            [
                "verify",
                str(source),
                "--expected-commit",
                HEAD,
                "--output",
                str(tmp_path / "proof.json"),
            ]
        )
        == 2
    )
    stderr = capsys.readouterr().err
    assert "shared privacy boundary" in stderr
    assert "DO-NOT-REFLECT" not in stderr


def test_manifest_rejects_future_end():
    with pytest.raises(PilotValidationError, match="has not ended"):
        verify_manifest(manifest(), expected_commit=HEAD, now="2026-09-01T21:00:00Z")
