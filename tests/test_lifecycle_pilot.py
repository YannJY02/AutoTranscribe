import hashlib
import json
import shutil
import subprocess
import zipfile
from pathlib import Path

import pytest

from scripts.lifecycle_pilot import (
    POST_HARNESS_EVIDENCE_REFS,
    PilotValidationError,
    _archive_bundle_sha,
    _run_frozen_rollback_checks,
    generate_rollback_proof,
    main,
    validate_rollback_proof,
    verify_manifest,
)

ROOT = Path(__file__).resolve().parents[1]
HEAD = "83746318b85db3b0882e467401e1f1ec5d5b1eaa"
PILOT = ROOT / "pilots/gh-73-owner-lifecycle.json"


def test_post_harness_changes_are_limited_to_bound_evidence():
    assert POST_HARNESS_EVIDENCE_REFS == {
        "pilots/evidence/GH-73/full-harness-manifest.json",
        "pilots/evidence/GH-73/repository-proof.json",
        "pilots/gh-73-owner-lifecycle.json",
    }


def manifest():
    return json.loads(PILOT.read_text())


def promote_attempts(value):
    for attempt in value["attempts"]:
        attempt.update(classification="observed", result="passed", unknowns=[])
        attempt["stages"] = {stage: "observed" for stage in attempt["stages"]}
        attempt["evidence_refs"] = ["pilots/evidence/GH-73/live-local-proof.json"]
    value["claims"]["observed"] += [
        "attempt.live-cloud",
        "attempt.import-local",
        "attempt.import-cloud",
    ]
    value["claims"]["unobserved"] = [
        "production-readiness",
        "external-user-validation",
    ]


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
        json.loads((ROOT / ref).read_text())["visual"]["artifact_ref"]
        for attempt in value["attempts"]
        for ref in attempt["evidence_refs"]
    ]
    refs += [
        item["evidence_ref"]
        for item in value["reconciliation"].values()
        if item.get("evidence_ref")
    ]
    refs += value["rollback"]["evidence_refs"]
    refs += [value["reconciliation"]["repository"]["harness_manifest_ref"]]
    ledger = json.loads((ROOT / value["evidence_ledger_ref"]).read_text())
    refs += [record["source_ref"] for record in ledger["records"]]
    build_proof = json.loads((ROOT / value["build"]["proof_ref"]).read_text())
    refs += [
        build_proof["app_archive_ref"],
        build_proof["source_attestation_ref"],
        build_proof["source_attestation_signature_ref"],
    ]
    for ref in refs:
        target = destination / ref
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / ref, target)


def test_truthful_manifest_is_partial_not_completed():
    proof = verify_manifest(
        manifest(), expected_commit=HEAD, now="2026-09-02T04:00:00Z"
    )

    assert proof["pilot_outcome"] == "partial"
    assert proof["attempt_counts"] == {"observed": 1, "inference": 0, "unobserved": 3}
    assert proof["production_readiness_claimed"] is False


def test_failed_observed_attempt_cannot_be_promoted_to_completed():
    value = manifest()
    value["attempts"][0]["result"] = "passed"

    with pytest.raises(PilotValidationError, match="every stage"):
        verify_manifest(value, expected_commit=HEAD, now="2026-09-02T04:00:00Z")


def test_pilot_readbacks_fail_closed_without_pilot_specific_schemas():
    value = manifest()
    promote_attempts(value)
    for provider in ("posthog", "sentry", "langfuse"):
        value["reconciliation"][provider]["scope"] = "pilot-attempt"

    with pytest.raises(PilotValidationError, match="segmented lifecycle evidence"):
        verify_manifest(value, expected_commit=HEAD, now="2026-09-02T04:00:00Z")


def test_prerequisite_readbacks_do_not_close_current_pilot():
    value = manifest()
    promote_attempts(value)

    proof = verify_manifest(value, expected_commit=HEAD, now="2026-09-02T04:00:00Z")

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
        verify_manifest(value, expected_commit=HEAD, now="2026-09-02T04:00:00Z")


def test_posthog_requires_non_empty_exact_counts():
    value = manifest()
    value["reconciliation"]["posthog"]["remote_event_counts"]["workflow_started"] = 3
    with pytest.raises(PilotValidationError, match="counts do not reconcile"):
        verify_manifest(value, expected_commit=HEAD, now="2026-09-02T04:00:00Z")


def test_posthog_rejects_events_outside_the_closed_contract():
    value = manifest()
    value["reconciliation"]["posthog"]["local_event_counts"] = {"irrelevant_event": 1}
    value["reconciliation"]["posthog"]["remote_event_counts"] = {"irrelevant_event": 1}

    with pytest.raises(PilotValidationError, match="counts do not reconcile"):
        verify_manifest(value, expected_commit=HEAD, now="2026-09-02T04:00:00Z")

    value = manifest()
    value["reconciliation"]["posthog"]["local_event_counts"] = {}
    value["reconciliation"]["posthog"]["remote_event_counts"] = {}
    with pytest.raises(PilotValidationError, match="non-empty"):
        verify_manifest(value, expected_commit=HEAD, now="2026-09-02T04:00:00Z")


def test_langfuse_preserves_score_and_observation_environment_distinction():
    value = manifest()
    value["reconciliation"]["langfuse"]["observation_environment"] = "owner-pilot"

    with pytest.raises(PilotValidationError, match="environment distinction"):
        verify_manifest(value, expected_commit=HEAD, now="2026-09-02T04:00:00Z")


def test_sentry_release_must_bind_the_read_back_build():
    value = manifest()
    value["reconciliation"]["sentry"]["build"] = "20260902000000"

    with pytest.raises(PilotValidationError, match="Sentry readback identity"):
        verify_manifest(value, expected_commit=HEAD, now="2026-09-02T04:00:00Z")


def test_pilot_scoped_sentry_readback_binds_the_frozen_app_build(tmp_path: Path):
    copy_repository_evidence(tmp_path)
    value = manifest()
    sentry = value["reconciliation"]["sentry"]
    sentry.update(scope="pilot-attempt")
    evidence_path = tmp_path / sentry["evidence_ref"]
    evidence = json.loads(evidence_path.read_text())
    evidence.update(
        scope="pilot-attempt",
        observed_at="2026-09-02T03:26:00Z",
        event_created_at="2026-09-02T03:26:00Z",
    )
    evidence_path.write_text(json.dumps(evidence))

    with pytest.raises(PilotValidationError, match="frozen build"):
        verify_manifest(
            value,
            expected_commit=HEAD,
            repository_root=tmp_path,
            now="2026-09-02T04:00:00Z",
        )


def test_prerequisite_sentry_event_cannot_be_relabelled_as_current_pilot(
    tmp_path: Path,
):
    copy_repository_evidence(tmp_path)
    value = manifest()
    build_proof = json.loads((tmp_path / value["build"]["proof_ref"]).read_text())
    build_version = build_proof["build_version"]
    release = f"com.yannjy.insightkit@1.0+{build_version}"
    sentry = value["reconciliation"]["sentry"]
    sentry.update(scope="pilot-attempt", build=build_version, release=release)
    evidence_path = tmp_path / sentry["evidence_ref"]
    evidence = json.loads(evidence_path.read_text())
    evidence.update(
        scope="pilot-attempt",
        release=release,
        observed_at="2026-09-02T03:26:00Z",
        event_created_at="2026-09-02T03:26:00Z",
    )
    evidence_path.write_text(json.dumps(evidence))

    with pytest.raises(PilotValidationError, match="pilot-specific immutable event"):
        verify_manifest(
            value,
            expected_commit=HEAD,
            repository_root=tmp_path,
            now="2026-09-02T04:00:00Z",
        )


def test_fresh_checkout_verifies_committed_proof_without_ignored_app(tmp_path: Path):
    copy_repository_evidence(tmp_path)

    proof = verify_manifest(
        manifest(),
        expected_commit=HEAD,
        repository_root=tmp_path,
        now="2026-09-02T04:00:00Z",
    )

    assert proof["pilot_outcome"] == "partial"
    assert not (tmp_path / manifest()["build"]["app_bundle_ref"]).exists()


def test_fresh_checkout_does_not_require_origin_main_ref(tmp_path: Path):
    copy_repository_evidence(tmp_path)
    subprocess.run(
        ["git", "update-ref", "-d", "refs/remotes/origin/main"],
        cwd=tmp_path,
        check=True,
    )

    proof = verify_manifest(
        manifest(),
        expected_commit=HEAD,
        repository_root=tmp_path,
        now="2026-09-02T04:00:00Z",
    )

    assert proof["pilot_outcome"] == "partial"


def test_repository_harness_commit_is_bound_separately_from_build(tmp_path: Path):
    copy_repository_evidence(tmp_path)
    value = manifest()
    value["reconciliation"]["repository"]["harness_commit"] = "0" * 40

    with pytest.raises(PilotValidationError, match="provider evidence is unrelated"):
        verify_manifest(
            value,
            expected_commit=HEAD,
            repository_root=tmp_path,
            now="2026-09-02T04:00:00Z",
        )


def test_non_string_repository_harness_commit_is_a_bounded_validation_error():
    value = manifest()
    value["reconciliation"]["repository"]["harness_commit"] = 42

    with pytest.raises(PilotValidationError, match="repository readback"):
        verify_manifest(value, expected_commit=HEAD, now="2026-09-02T04:00:00Z")


@pytest.mark.parametrize(
    "mutation",
    [
        "empty-commands",
        "empty-changed-files",
        "failed-command-marked-passed",
        "self-selected-base",
        "unavailable-commit",
    ],
)
def test_repository_harness_must_match_the_executed_plan(tmp_path: Path, mutation):
    copy_repository_evidence(tmp_path)
    value = manifest()
    harness_ref = value["reconciliation"]["repository"]["harness_manifest_ref"]
    harness_path = tmp_path / harness_ref
    harness = json.loads(harness_path.read_text())
    if mutation == "empty-commands":
        for gate in harness["gates"]:
            gate["commands"] = []
    elif mutation == "empty-changed-files":
        harness["changed_files"] = []
        harness["gates"] = harness["gates"][:1]
        harness["gates"][0]["commands"] = []
    elif mutation == "failed-command-marked-passed":
        harness["gates"][0]["commands"][0].update(exit_code=1, ok=False)
    elif mutation == "self-selected-base":
        harness["base"] = "HEAD"
        harness["changed_files"] = []
        harness["gates"] = harness["gates"][:1]
        harness["gates"][0]["commands"][2]["command"][3] = "HEAD...HEAD"
    else:
        harness["commit"] = "f" * 40
        value["reconciliation"]["repository"]["harness_commit"] = "f" * 40
    harness_path.write_text(json.dumps(harness))
    harness_sha = hashlib.sha256(harness_path.read_bytes()).hexdigest()
    value["reconciliation"]["repository"]["harness_manifest_sha256"] = harness_sha
    repository_proof = tmp_path / value["reconciliation"]["repository"]["evidence_ref"]
    proof = json.loads(repository_proof.read_text())
    proof["harness_manifest_sha256"] = harness_sha
    if mutation == "unavailable-commit":
        proof["commit"] = "f" * 40
    repository_proof.write_text(json.dumps(proof))

    with pytest.raises(PilotValidationError, match="repository Harness evidence"):
        verify_manifest(
            value,
            expected_commit=HEAD,
            repository_root=tmp_path,
            now="2026-09-02T04:00:00Z",
        )


def test_repository_harness_accepts_a_failure_at_an_early_planned_gate(
    tmp_path: Path,
):
    copy_repository_evidence(tmp_path)
    value = manifest()
    repository = value["reconciliation"]["repository"]
    repository["status"] = "failed"
    harness_path = tmp_path / repository["harness_manifest_ref"]
    harness = json.loads(harness_path.read_text())
    harness["status"] = "failed"
    harness["gates"] = harness["gates"][:2]
    harness["gates"][-1]["status"] = "failed"
    harness["gates"][-1]["commands"][0].update(exit_code=1, ok=False)
    harness_path.write_text(json.dumps(harness))
    harness_sha = hashlib.sha256(harness_path.read_bytes()).hexdigest()
    repository["harness_manifest_sha256"] = harness_sha
    proof_path = tmp_path / repository["evidence_ref"]
    proof = json.loads(proof_path.read_text())
    proof.update(status="failed", harness_manifest_sha256=harness_sha)
    proof_path.write_text(json.dumps(proof))

    result = verify_manifest(
        value,
        expected_commit=HEAD,
        repository_root=tmp_path,
        now="2026-09-02T04:00:00Z",
    )

    assert result["external_readbacks"]["repository"]["status"] == "failed"


def test_harness_manifest_uses_the_shared_privacy_boundary(tmp_path: Path):
    copy_repository_evidence(tmp_path)
    value = manifest()
    harness_ref = value["reconciliation"]["repository"]["harness_manifest_ref"]
    harness_path = tmp_path / harness_ref
    harness = json.loads(harness_path.read_text())
    harness["api_key"] = "sk-" + "example-secret-value-that-must-not-pass"
    harness_path.write_text(json.dumps(harness))
    harness_sha = hashlib.sha256(harness_path.read_bytes()).hexdigest()
    value["reconciliation"]["repository"]["harness_manifest_sha256"] = harness_sha
    repository_proof = tmp_path / value["reconciliation"]["repository"]["evidence_ref"]
    proof = json.loads(repository_proof.read_text())
    proof["harness_manifest_sha256"] = harness_sha
    repository_proof.write_text(json.dumps(proof))

    with pytest.raises(PilotValidationError, match="shared privacy boundary"):
        verify_manifest(
            value,
            expected_commit=HEAD,
            repository_root=tmp_path,
            now="2026-09-02T04:00:00Z",
        )


def test_harness_manifest_cannot_resolve_outside_the_repository(tmp_path: Path):
    copy_repository_evidence(tmp_path)
    value = manifest()
    harness_path = tmp_path / value["reconciliation"]["repository"][
        "harness_manifest_ref"
    ]
    external = tmp_path.parent / f"{tmp_path.name}-external-harness.json"
    shutil.copy2(harness_path, external)
    harness_path.unlink()
    harness_path.symlink_to(external)

    with pytest.raises(PilotValidationError, match="repository Harness evidence"):
        verify_manifest(
            value,
            expected_commit=HEAD,
            repository_root=tmp_path,
            now="2026-09-02T04:00:00Z",
        )


def test_attempt_evidence_semantics_must_match_manifest(tmp_path: Path):
    copy_repository_evidence(tmp_path)
    value = manifest()
    attempt = value["attempts"][0]
    attempt.update(result="passed", unknowns=[])
    attempt["stages"] = {stage: "observed" for stage in attempt["stages"]}

    with pytest.raises(PilotValidationError, match="attempt evidence does not match"):
        verify_manifest(
            value,
            expected_commit=HEAD,
            repository_root=tmp_path,
            now="2026-09-02T04:00:00Z",
        )


@pytest.mark.parametrize(
    "field,value",
    [("evidence_kind", "inference"), ("unknowns", {})],
)
def test_attempt_evidence_kind_and_unknowns_are_bound(tmp_path: Path, field, value):
    copy_repository_evidence(tmp_path)
    evidence = tmp_path / manifest()["attempts"][0]["evidence_refs"][0]
    payload = json.loads(evidence.read_text())
    payload[field] = value
    evidence.write_text(json.dumps(payload))

    with pytest.raises(PilotValidationError, match="attempt evidence does not match"):
        verify_manifest(
            manifest(),
            expected_commit=HEAD,
            repository_root=tmp_path,
            now="2026-09-02T04:00:00Z",
        )


@pytest.mark.parametrize("mutation", ["missing-visual", "wrong-app-build"])
def test_attempt_attachments_are_bound_to_the_frozen_build(tmp_path: Path, mutation):
    copy_repository_evidence(tmp_path)
    evidence_path = tmp_path / manifest()["attempts"][0]["evidence_refs"][0]
    evidence = json.loads(evidence_path.read_text())
    if mutation == "missing-visual":
        (tmp_path / evidence["visual"]["artifact_ref"]).unlink()
    else:
        evidence["app"]["build"] = "unrelated"
        evidence_path.write_text(json.dumps(evidence))
        evidence_sha = hashlib.sha256(evidence_path.read_bytes()).hexdigest()
        rollback_path = tmp_path / manifest()["rollback"]["evidence_refs"][0]
        rollback = json.loads(rollback_path.read_text())
        rollback["evidence_sha256_before"] = evidence_sha
        rollback["evidence_sha256_after"] = evidence_sha
        rollback_path.write_text(json.dumps(rollback))

    with pytest.raises(PilotValidationError, match="attempt attachment"):
        verify_manifest(
            manifest(),
            expected_commit=HEAD,
            repository_root=tmp_path,
            now="2026-09-02T04:00:00Z",
        )


@pytest.mark.parametrize(
    "field,value",
    [
        ("observed_at", "1999-01-01T00:00:00Z"),
        ("host_attempts", ["private meeting: Alice discussed acquisition"]),
    ],
)
def test_attempt_metadata_is_bounded_and_inside_the_pilot_window(
    tmp_path: Path, field, value
):
    copy_repository_evidence(tmp_path)
    evidence_path = tmp_path / manifest()["attempts"][0]["evidence_refs"][0]
    evidence = json.loads(evidence_path.read_text())
    evidence[field] = value
    evidence_path.write_text(json.dumps(evidence))
    evidence_sha = hashlib.sha256(evidence_path.read_bytes()).hexdigest()
    rollback_path = tmp_path / manifest()["rollback"]["evidence_refs"][0]
    rollback = json.loads(rollback_path.read_text())
    rollback["evidence_sha256_before"] = evidence_sha
    rollback["evidence_sha256_after"] = evidence_sha
    rollback_path.write_text(json.dumps(rollback))

    with pytest.raises(PilotValidationError, match="attempt metadata"):
        verify_manifest(
            manifest(),
            expected_commit=HEAD,
            repository_root=tmp_path,
            now="2026-09-02T04:00:00Z",
        )


def test_claims_exactly_match_attempt_and_reconciliation_classifications():
    value = manifest()
    value["claims"]["observed"].append("attempt.live-cloud")

    with pytest.raises(PilotValidationError, match="claim classifications"):
        verify_manifest(value, expected_commit=HEAD, now="2026-09-02T04:00:00Z")


def test_claim_codes_reject_non_strings_with_a_validation_error():
    value = manifest()
    value["claims"]["observed"][0] = 42

    with pytest.raises(PilotValidationError, match="bounded metadata codes"):
        verify_manifest(value, expected_commit=HEAD, now="2026-09-02T04:00:00Z")


@pytest.mark.parametrize(
    "mutation",
    [
        lambda value: value["attempts"][0].update(classification=[]),
        lambda value: value["attempts"][0].update(result=[]),
        lambda value: value["reconciliation"]["posthog"].update(classification=[]),
        lambda value: value["reconciliation"]["posthog"].update(scope=[]),
        lambda value: value["reconciliation"]["posthog"].update(
            local_event_counts={"workflow_started": "1"},
            remote_event_counts={"workflow_started": "1"},
        ),
        lambda value: value["reconciliation"]["sentry"].update(event_id=[]),
        lambda value: value["reconciliation"]["sentry"].update(release=[]),
        lambda value: value["reconciliation"]["repository"].update(status=[]),
        lambda value: value["reconciliation"]["repository"].update(
            harness_manifest_sha256=[]
        ),
        lambda value: value["configuration"].update(attempt_order=42),
    ],
)
def test_untrusted_value_types_never_escape_the_validation_boundary(mutation):
    value = manifest()
    mutation(value)

    with pytest.raises(PilotValidationError, match="invalid value types"):
        verify_manifest(value, expected_commit=HEAD, now="2026-09-02T04:00:00Z")


def test_synthetic_attempt_evidence_cannot_be_promoted_to_passed(tmp_path: Path):
    copy_repository_evidence(tmp_path)
    value = manifest()
    attempt = value["attempts"][0]
    attempt.update(result="passed", unknowns=[])
    attempt["stages"] = {stage: "observed" for stage in attempt["stages"]}
    evidence = tmp_path / attempt["evidence_refs"][0]
    payload = json.loads(evidence.read_text())
    payload.update(
        status="passed",
        analysis_mode_observed=True,
        stages=attempt["stages"],
        unknowns=[],
    )
    evidence.write_text(json.dumps(payload))

    with pytest.raises(PilotValidationError, match="claimed result and stages"):
        verify_manifest(
            value,
            expected_commit=HEAD,
            repository_root=tmp_path,
            now="2026-09-02T04:00:00Z",
        )


def test_native_rollback_proof_must_exist(tmp_path: Path):
    copy_repository_evidence(tmp_path)
    rollback = tmp_path / manifest()["rollback"]["evidence_refs"][0]
    proof = json.loads(rollback.read_text())
    proof["native_proof_ref"] = "pilots/evidence/GH-73/missing-native-proof.json"
    rollback.write_text(json.dumps(proof))

    with pytest.raises(PilotValidationError, match="validated attempt evidence"):
        verify_manifest(
            manifest(),
            expected_commit=HEAD,
            repository_root=tmp_path,
            now="2026-09-02T04:00:00Z",
        )


def test_native_rollback_proof_uses_the_shared_privacy_boundary(tmp_path: Path):
    copy_repository_evidence(tmp_path)
    native_ref = manifest()["attempts"][0]["evidence_refs"][0]
    native = tmp_path / native_ref
    payload = json.loads(native.read_text())
    payload["api_key"] = "sk-" + "private-value"
    native.write_text(json.dumps(payload))
    rollback_path = tmp_path / manifest()["rollback"]["evidence_refs"][0]
    rollback = json.loads(rollback_path.read_text())
    native_sha = hashlib.sha256(native.read_bytes()).hexdigest()
    rollback["evidence_sha256_before"] = native_sha
    rollback["evidence_sha256_after"] = native_sha
    rollback_path.write_text(json.dumps(rollback))

    with pytest.raises(PilotValidationError, match="shared privacy boundary"):
        verify_manifest(
            manifest(),
            expected_commit=HEAD,
            repository_root=tmp_path,
            now="2026-09-02T04:00:00Z",
        )


def test_native_rollback_proof_must_be_validated_attempt_evidence(tmp_path: Path):
    copy_repository_evidence(tmp_path)
    native = tmp_path / "pilots/evidence/GH-73/arbitrary-safe.json"
    native.write_text("{}\n")
    rollback_path = tmp_path / manifest()["rollback"]["evidence_refs"][0]
    rollback = json.loads(rollback_path.read_text())
    rollback["native_proof_ref"] = str(native.relative_to(tmp_path))
    native_sha = hashlib.sha256(native.read_bytes()).hexdigest()
    rollback["evidence_sha256_before"] = native_sha
    rollback["evidence_sha256_after"] = native_sha
    rollback_path.write_text(json.dumps(rollback))

    with pytest.raises(PilotValidationError, match="validated attempt evidence"):
        verify_manifest(
            manifest(),
            expected_commit=HEAD,
            repository_root=tmp_path,
            now="2026-09-02T04:00:00Z",
        )


def test_rollback_generator_validates_the_attempt_evidence(tmp_path: Path):
    copy_repository_evidence(tmp_path)
    value = manifest()
    build_proof = json.loads((tmp_path / value["build"]["proof_ref"]).read_text())
    app = tmp_path / value["build"]["app_bundle_ref"]
    app.parent.mkdir(parents=True, exist_ok=True)
    shutil.unpack_archive(tmp_path / build_proof["app_archive_ref"], app.parent)
    native_ref = value["attempts"][0]["evidence_refs"][0]
    native = tmp_path / native_ref
    native.write_text(
        json.dumps(
            {
                "privacy_safe": True,
                "commit": value["build"]["commit"],
                "api_key": "sk-" + "private-value",
            }
        )
    )

    with pytest.raises(PilotValidationError, match="shared privacy boundary"):
        generate_rollback_proof(
            value,
            repository_root=tmp_path,
            native_proof_ref=native_ref,
        )


def test_rollback_generator_validates_attempt_semantics(tmp_path: Path):
    value = manifest()
    attempt = value["attempts"][0]
    attempt.update(result="passed", unknowns=[])
    attempt["stages"] = {stage: "unobserved" for stage in attempt["stages"]}

    with pytest.raises(PilotValidationError, match="observed attempt requires"):
        generate_rollback_proof(
            value,
            repository_root=tmp_path,
            native_proof_ref=attempt["evidence_refs"][0],
        )


@pytest.mark.parametrize(
    "payload,error",
    [
        ({}, "manifest fields"),
        ({**manifest(), "api_key": "sk-private-value"}, "shared privacy boundary"),
    ],
)
def test_rollback_generator_validates_the_complete_manifest_before_execution(
    tmp_path: Path, monkeypatch, payload, error
):
    executed = False

    def rollback_checks(*_args, **_kwargs):
        nonlocal executed
        executed = True

    monkeypatch.setattr(
        "scripts.lifecycle_pilot._run_frozen_rollback_checks", rollback_checks
    )

    with pytest.raises(PilotValidationError, match=error):
        generate_rollback_proof(
            payload,
            repository_root=tmp_path,
            native_proof_ref="pilots/evidence/GH-73/live-local-proof.json",
        )

    assert executed is False


@pytest.mark.parametrize("field", ["app_bundle_ref", "proof_ref"])
def test_rollback_generator_rejects_absolute_build_references(
    tmp_path: Path, field: str
):
    value = manifest()
    value["build"][field] = str(tmp_path / "external")

    with pytest.raises(PilotValidationError, match="build freeze"):
        generate_rollback_proof(
            value,
            repository_root=tmp_path,
            native_proof_ref="pilots/evidence/GH-73/live-local-proof.json",
        )


def test_rollback_generator_rejects_an_absolute_native_proof_reference(
    tmp_path: Path,
):
    with pytest.raises(PilotValidationError, match="validated attempt evidence"):
        generate_rollback_proof(
            manifest(),
            repository_root=tmp_path,
            native_proof_ref=str(tmp_path / "external.json"),
        )


@pytest.mark.parametrize("field,value", [("status", "failed"), ("commit", "0" * 40)])
def test_rollback_proof_identity_is_bound(tmp_path: Path, field, value):
    copy_repository_evidence(tmp_path)
    rollback = tmp_path / manifest()["rollback"]["evidence_refs"][0]
    proof = json.loads(rollback.read_text())
    proof[field] = value
    rollback.write_text(json.dumps(proof))

    with pytest.raises(PilotValidationError, match="rollback evidence is unrelated"):
        verify_manifest(
            manifest(),
            expected_commit=HEAD,
            repository_root=tmp_path,
            now="2026-09-02T04:00:00Z",
        )


def test_rollback_execution_uses_a_detached_frozen_worktree(
    tmp_path: Path, monkeypatch
):
    copy_repository_evidence(tmp_path)
    changed = (
        tmp_path
        / "macos/InsightKitApp/Sources/InsightKitApp/Services/ProductAnalytics.swift"
    )
    changed.parent.mkdir(parents=True, exist_ok=True)
    changed.write_text("// working-tree dependency drift\n")
    original_run = subprocess.run
    observed = {}

    def run(command, *args, **kwargs):
        if command[0] == "swift":
            cwd = Path(kwargs["cwd"])
            observed["commit"] = original_run(
                ["git", "-C", str(cwd), "rev-parse", "HEAD"],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
            observed["cwd"] = cwd
            return subprocess.CompletedProcess(command, 0)
        return original_run(command, *args, **kwargs)

    monkeypatch.setattr(subprocess, "run", run)
    _run_frozen_rollback_checks(tmp_path, HEAD)

    assert observed["commit"] == HEAD
    assert observed["cwd"] != tmp_path


def test_repository_checks_do_not_claim_unrecorded_gates():
    value = manifest()
    value["reconciliation"]["repository"]["checks"].append("codesign")

    with pytest.raises(PilotValidationError, match="repository readback"):
        verify_manifest(value, expected_commit=HEAD, now="2026-09-02T04:00:00Z")


def test_local_artifact_verification_is_explicit_and_hash_bound(tmp_path: Path):
    copy_repository_evidence(tmp_path)
    with pytest.raises(PilotValidationError, match="app artifact hash"):
        verify_manifest(
            manifest(),
            expected_commit=HEAD,
            repository_root=tmp_path,
            now="2026-09-02T04:00:00Z",
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
            now="2026-09-02T04:00:00Z",
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
            now="2026-09-02T04:00:00Z",
        )


@pytest.mark.parametrize("mutation", ["missing", "changed"])
def test_ledger_outcome_artifact_must_exist_and_match(tmp_path: Path, mutation):
    copy_repository_evidence(tmp_path)
    ledger = json.loads((tmp_path / manifest()["evidence_ledger_ref"]).read_text())
    outcome = tmp_path / ledger["records"][0]["source_ref"]
    if mutation == "missing":
        outcome.unlink()
    else:
        outcome.write_text("{}\n")

    with pytest.raises(PilotValidationError, match="ledger outcome artifact"):
        verify_manifest(
            manifest(),
            expected_commit=HEAD,
            repository_root=tmp_path,
            now="2026-09-02T04:00:00Z",
        )


def test_ledger_outcome_artifact_must_be_the_expected_json(tmp_path: Path):
    copy_repository_evidence(tmp_path)
    ledger_path = tmp_path / manifest()["evidence_ledger_ref"]
    ledger = json.loads(ledger_path.read_text())
    artifact = tmp_path / "pilots/evidence/GH-73/arbitrary-private.bin"
    artifact.write_text("api_key=sk-" + "example-secret-value-that-must-not-pass")
    ledger["records"][0]["source_ref"] = str(artifact.relative_to(tmp_path))
    ledger["records"][0]["recheck_source"] = str(artifact.relative_to(tmp_path))
    ledger["records"][0]["artifact_sha256"] = (
        "sha256:" + hashlib.sha256(artifact.read_bytes()).hexdigest()
    )
    ledger_path.write_text(json.dumps(ledger))

    with pytest.raises(PilotValidationError, match="ledger outcome artifact"):
        verify_manifest(
            manifest(),
            expected_commit=HEAD,
            repository_root=tmp_path,
            now="2026-09-02T04:00:00Z",
        )


def test_ledger_outcome_artifact_must_match_the_computed_outcome(tmp_path: Path):
    copy_repository_evidence(tmp_path)
    ledger_path = tmp_path / manifest()["evidence_ledger_ref"]
    ledger = json.loads(ledger_path.read_text())
    outcome = tmp_path / ledger["records"][0]["source_ref"]
    payload = json.loads(outcome.read_text())
    payload.update(
        status="passed",
        result="completed",
        observed_attempts=4,
        unobserved_attempts=0,
        production_readiness_claimed=True,
    )
    outcome.write_text(json.dumps(payload))
    ledger["records"][0]["artifact_sha256"] = (
        "sha256:" + hashlib.sha256(outcome.read_bytes()).hexdigest()
    )
    ledger_path.write_text(json.dumps(ledger))

    with pytest.raises(PilotValidationError, match="ledger outcome artifact"):
        verify_manifest(
            manifest(),
            expected_commit=HEAD,
            repository_root=tmp_path,
            now="2026-09-02T04:00:00Z",
        )


def test_provider_evidence_kind_matches_its_classification(tmp_path: Path):
    copy_repository_evidence(tmp_path)
    evidence = tmp_path / manifest()["reconciliation"]["posthog"]["evidence_ref"]
    payload = json.loads(evidence.read_text())
    payload["evidence_kind"] = "inference"
    evidence.write_text(json.dumps(payload))

    with pytest.raises(PilotValidationError, match="provider evidence is unrelated"):
        verify_manifest(
            manifest(),
            expected_commit=HEAD,
            repository_root=tmp_path,
            now="2026-09-02T04:00:00Z",
        )


def test_prerequisite_readback_cannot_be_relabelled_as_current_pilot(tmp_path: Path):
    copy_repository_evidence(tmp_path)
    value = manifest()
    value["reconciliation"]["posthog"]["scope"] = "pilot-attempt"
    evidence = tmp_path / value["reconciliation"]["posthog"]["evidence_ref"]
    payload = json.loads(evidence.read_text())
    payload["scope"] = "pilot-attempt"
    payload["source_issue"] = "GH-73"
    evidence.write_text(json.dumps(payload))

    with pytest.raises(PilotValidationError, match="segmented lifecycle evidence"):
        verify_manifest(
            value,
            expected_commit=HEAD,
            repository_root=tmp_path,
            now="2026-09-02T04:00:00Z",
        )


@pytest.mark.parametrize(
    "field,value",
    [
        ("region", "private meeting: Alice discussed acquisition"),
        ("readback", "private meeting: Alice discussed acquisition"),
    ],
)
def test_provider_metadata_is_bounded_and_inside_the_pilot_window(
    tmp_path: Path, field, value
):
    copy_repository_evidence(tmp_path)
    evidence = tmp_path / manifest()["reconciliation"]["posthog"]["evidence_ref"]
    payload = json.loads(evidence.read_text())
    payload[field] = value
    evidence.write_text(json.dumps(payload))

    with pytest.raises(PilotValidationError, match="PostHog evidence"):
        verify_manifest(
            manifest(),
            expected_commit=HEAD,
            repository_root=tmp_path,
            now="2026-09-02T04:00:00Z",
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
            now="2026-09-02T04:00:00Z",
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
            now="2026-09-02T04:00:00Z",
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
            now="2026-09-02T04:00:00Z",
        )


@pytest.mark.parametrize(
    "field,value",
    [
        ("distribution", "untrusted"),
        ("signing", "unsigned"),
        ("verification", []),
        ("signing_team_id", "untrusted"),
        ("signing_leaf_certificate_sha256", "0" * 64),
    ],
)
def test_build_proof_signing_assertions_are_bound(tmp_path: Path, field, value):
    copy_repository_evidence(tmp_path)
    proof_path = tmp_path / manifest()["build"]["proof_ref"]
    proof = json.loads(proof_path.read_text())
    proof[field] = value
    proof_path.write_text(json.dumps(proof))

    with pytest.raises(PilotValidationError, match="build proof"):
        verify_manifest(
            manifest(),
            expected_commit=HEAD,
            repository_root=tmp_path,
            now="2026-09-02T04:00:00Z",
        )


def test_archived_app_signature_is_verified(tmp_path: Path, monkeypatch):
    copy_repository_evidence(tmp_path)
    original_run = subprocess.run

    def fail_codesign(command, *args, **kwargs):
        if command[0] == "codesign":
            return subprocess.CompletedProcess(command, 1)
        return original_run(command, *args, **kwargs)

    monkeypatch.setattr(subprocess, "run", fail_codesign)
    with pytest.raises(PilotValidationError, match="archive signature"):
        verify_manifest(
            manifest(),
            expected_commit=HEAD,
            repository_root=tmp_path,
            now="2026-09-02T04:00:00Z",
        )


def test_developer_attestation_binds_the_final_app_subject(tmp_path: Path, monkeypatch):
    copy_repository_evidence(tmp_path)
    value = manifest()
    proof_path = tmp_path / value["build"]["proof_ref"]
    proof = json.loads(proof_path.read_text())
    archive_path = tmp_path / proof["app_archive_ref"]
    replacement = archive_path.with_suffix(".replacement.zip")
    target = "InsightKit.app/Contents/Resources/insightkit_runtime/insightkit/ipc/server.py"
    with zipfile.ZipFile(archive_path) as source, zipfile.ZipFile(
        replacement, "w", zipfile.ZIP_DEFLATED
    ) as destination:
        for info in source.infolist():
            payload = source.read(info) if not info.is_dir() else b""
            destination.writestr(
                info,
                payload + (b"\n# tampered after build\n" if info.filename == target else b""),
            )
    replacement.replace(archive_path)
    attacked_app_sha, _ = _archive_bundle_sha(archive_path)
    proof["app_archive_sha256"] = hashlib.sha256(archive_path.read_bytes()).hexdigest()
    proof["app_bundle_sha256"] = attacked_app_sha
    proof_path.write_text(json.dumps(proof))
    evidence_path = tmp_path / value["attempts"][0]["evidence_refs"][0]
    evidence = json.loads(evidence_path.read_text())
    evidence["app"]["bundle_sha256"] = attacked_app_sha
    evidence_path.write_text(json.dumps(evidence))
    evidence_sha = hashlib.sha256(evidence_path.read_bytes()).hexdigest()
    rollback_path = tmp_path / value["rollback"]["evidence_refs"][0]
    rollback = json.loads(rollback_path.read_text())
    rollback["rollback_target_sha256"] = attacked_app_sha
    rollback["evidence_sha256_before"] = evidence_sha
    rollback["evidence_sha256_after"] = evidence_sha
    rollback_path.write_text(json.dumps(rollback))
    monkeypatch.setattr(
        "scripts.lifecycle_pilot._verify_archive_signature",
        lambda _: {
            "bundle_id": "com.yannjy.insightkit",
            "cdhash": proof["bundle_cdhash"],
            "team_id": proof["signing_team_id"],
            "leaf_certificate_sha256": proof["signing_leaf_certificate_sha256"],
            "architectures": ["arm64"],
            "executable_sha256": proof["executable_sha256"],
        },
    )

    with pytest.raises(PilotValidationError, match="does not bind the frozen app"):
        verify_manifest(
            value,
            expected_commit=HEAD,
            repository_root=tmp_path,
            now="2026-09-02T04:00:00Z",
        )


def test_reconciliation_sql_is_bound_to_the_frozen_commit(tmp_path: Path):
    copy_repository_evidence(tmp_path)
    sql = tmp_path / manifest()["configuration"]["sql_refs"][0]
    sql.write_text("SELECT 0\n")

    with pytest.raises(PilotValidationError, match="reconciliation SQL"):
        verify_manifest(
            manifest(),
            expected_commit=HEAD,
            repository_root=tmp_path,
            now="2026-09-02T04:00:00Z",
        )


def test_rollback_proof_binds_frozen_package_hash(tmp_path: Path):
    copy_repository_evidence(tmp_path)
    rollback = tmp_path / manifest()["rollback"]["evidence_refs"][0]
    proof = json.loads(rollback.read_text())
    proof["test_source_sha256"] = "0" * 64
    rollback.write_text(json.dumps(proof))

    with pytest.raises(PilotValidationError, match="test source changed"):
        verify_manifest(
            manifest(),
            expected_commit=HEAD,
            repository_root=tmp_path,
            now="2026-09-02T04:00:00Z",
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


def test_rollback_cli_failure_is_bounded_and_does_not_echo_private_input(
    tmp_path: Path, capsys, monkeypatch
):
    source = tmp_path / "pilot.json"
    source.write_text(json.dumps({"api_key": "DO-NOT-REFLECT"}))
    monkeypatch.chdir(tmp_path)

    assert (
        main(
            [
                "rollback-dry-run",
                str(source),
                "--native-proof-ref",
                "pilots/evidence/GH-73/live-local-proof.json",
                "--output",
                str(tmp_path / "proof.json"),
            ]
        )
        == 2
    )
    stderr = capsys.readouterr().err
    assert "shared privacy boundary" in stderr
    assert "DO-NOT-REFLECT" not in stderr


def test_non_string_build_commit_is_a_bounded_validation_error():
    value = manifest()
    value["build"]["commit"] = 42

    with pytest.raises(PilotValidationError, match="build freeze"):
        verify_manifest(value, expected_commit=HEAD, now="2026-09-02T04:00:00Z")


def test_manifest_rejects_future_end():
    with pytest.raises(PilotValidationError, match="has not ended"):
        verify_manifest(manifest(), expected_commit=HEAD, now="2026-09-01T21:00:00Z")
