import json
import multiprocessing
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest

from scripts.evidence_ledger import EvidenceLedger, ValidationError


OBSERVED_AT = "2026-08-30T09:00:00Z"


def source(**overrides):
    value = {
        "linear_issue_id": "YAN-50",
        "github_issue_or_pr_id": "GH-68",
        "lifecycle_stage": "verification",
        "lifecycle_transition": "verification-completed",
        "source_type": "ci",
        "source_id": "check-101",
        "source_ref": "https://github.com/YannJY02/AutoTranscribe/actions/runs/101",
        "revision": "build-101",
        "artifact_sha256": None,
        "observed_at": OBSERVED_AT,
        "environment": "github-actions",
        "result": "passed",
        "claim_class": "observed",
        "promotion_category": "gate",
        "privacy_class": "public-metadata",
        "fact": "Focused regressions passed.",
        "gap_or_decision": "No focused regression gap remains.",
        "owner_action": "Controller rechecks CI after push.",
        "recheck_source": "https://github.com/YannJY02/AutoTranscribe/actions/runs/101",
        "human_gate": "PR review remains required.",
        "unknowns": [],
    }
    value.update(overrides)
    return value


def _collect_in_process(path: str, item: dict):
    EvidenceLedger(path)._collect_normalized([item])


def test_replay_is_byte_equivalent_and_deduplicated(tmp_path: Path):
    ledger = EvidenceLedger(tmp_path / "ledger.json")
    first = ledger._collect_normalized([source()])
    first_bytes = ledger.path.read_bytes()
    second = ledger._collect_normalized([source()])

    assert first == second
    assert ledger.path.read_bytes() == first_bytes
    assert len(second["records"]) == 1
    assert second["records"][0]["evidence_id"].startswith("ev_v1_")


def test_transition_is_part_of_evidence_id_and_revision_supersedes_only_its_stream(tmp_path: Path):
    ledger = EvidenceLedger(tmp_path / "ledger.json")
    first = ledger._collect_normalized([
        source(lifecycle_transition="preflight-passed", revision="build-a"),
        source(lifecycle_transition="handoff-ready", revision="build-a"),
    ])
    preflight = next(r for r in first["records"] if r["lifecycle_transition"] == "preflight-passed")
    handoff = next(r for r in first["records"] if r["lifecycle_transition"] == "handoff-ready")
    assert preflight["evidence_id"] != handoff["evidence_id"]

    changed = ledger._collect_normalized([
        source(lifecycle_transition="preflight-passed", revision="build-b", result="failed"),
    ])
    old = next(r for r in changed["records"] if r["evidence_id"] == preflight["evidence_id"])
    newest = next(r for r in changed["records"] if r["revision"] == "build-b")
    untouched = next(r for r in changed["records"] if r["evidence_id"] == handoff["evidence_id"])
    assert old["result"] == "superseded"
    assert newest["supersedes"] == old["evidence_id"]
    assert untouched["result"] == "passed"


def test_promotion_id_is_stable_across_revision_changes(tmp_path: Path):
    ledger = EvidenceLedger(tmp_path / "ledger.json")
    first = ledger._collect_normalized([source(revision="build-a")])
    first_id = ledger.promotions(first)[0]["promotion_id"]
    second = ledger._collect_normalized([source(revision="build-b", result="failed")])
    assert ledger.promotions(second)[0]["promotion_id"] == first_id


def test_distinct_transitions_have_distinct_promotion_ids(tmp_path: Path):
    ledger = EvidenceLedger(tmp_path / "ledger.json")
    normalized = ledger._collect_normalized([
        source(lifecycle_transition="preflight-passed"),
        source(lifecycle_transition="handoff-ready"),
    ])
    assert len({item["promotion_id"] for item in ledger.promotions(normalized)}) == 2


def test_promotion_payload_identifies_its_publication_target(tmp_path: Path):
    ledger = EvidenceLedger(tmp_path / "ledger.json")
    linear = ledger.promotions(ledger._collect_normalized([source()]))[0]
    github = ledger.promotions(ledger._collect_normalized([
        source(
            source_id="check-102", revision="build-102",
            source_ref="https://github.com/YannJY02/AutoTranscribe/actions/runs/102",
            linear_issue_id=None, github_issue_or_pr_id="GH-68",
        )
    ]))
    github = next(item for item in github if item["target_service"] == "github")

    assert (linear["target_service"], linear["target"]) == ("linear", "YAN-50")
    assert (github["target_service"], github["target"]) == ("github", "GH-68")


def test_same_revision_with_changed_claim_is_rejected(tmp_path: Path):
    ledger = EvidenceLedger(tmp_path / "ledger.json")
    ledger._collect_normalized([source()])
    with pytest.raises(ValidationError, match="stable source revision changed content"):
        ledger._collect_normalized([source(fact="Tampered claim")])


def test_superseded_revision_cannot_be_replayed_with_a_changed_result(tmp_path: Path):
    ledger = EvidenceLedger(tmp_path / "ledger.json")
    ledger._collect_normalized([source(revision="build-a")])
    ledger._collect_normalized([source(revision="build-b", result="failed")])

    with pytest.raises(ValidationError, match="superseded source revision cannot be replayed"):
        ledger._collect_normalized([source(revision="build-a", result="failed")])


def test_batch_is_validated_before_any_write(tmp_path: Path):
    ledger = EvidenceLedger(tmp_path / "ledger.json")
    with pytest.raises(ValidationError, match="private path"):
        ledger._collect_normalized([source(), source(source_id="check-202", fact="See /Users/alice/private")])
    assert not ledger.path.exists()


def test_concurrent_collectors_do_not_lose_records(tmp_path: Path):
    path = tmp_path / "ledger.json"
    context = multiprocessing.get_context("spawn")
    processes = [
        context.Process(target=_collect_in_process, args=(str(path), source(
            source_id=f"check-{index}", revision=f"build-{index}",
            source_ref=f"https://github.com/YannJY02/AutoTranscribe/actions/runs/{index}",
        )))
        for index in range(4)
    ]
    for process in processes:
        process.start()
    for process in processes:
        process.join(10)
        assert process.exitcode == 0
    assert len(EvidenceLedger(path)._load()["records"]) == 4


def test_timestamp_offsets_are_compared_as_instants(tmp_path: Path):
    ledger = EvidenceLedger(tmp_path / "ledger.json")
    ledger._collect_normalized([source(observed_at="2026-08-30T09:30:00Z", revision="build-new")])
    with pytest.raises(ValidationError, match="stale source observation"):
        ledger._collect_normalized([source(observed_at="2026-08-30T10:00:00+02:00", revision="build-old")])

    precise = EvidenceLedger(tmp_path / "precise-ledger.json")
    precise._collect_normalized([
        source(observed_at="2026-08-30T09:30:00.0000001Z", revision="z-revision")
    ])
    changed = precise._collect_normalized([
        source(observed_at="2026-08-30T09:30:00.0000002Z", revision="a-revision")
    ])
    assert next(record for record in changed["records"] if record["revision"] == "a-revision")["result"] == "passed"


def test_manifest_is_privacy_walked_and_records_a_separate_artifact_hash(tmp_path: Path):
    repository_root = Path(__file__).parents[1]
    with tempfile.TemporaryDirectory(dir=repository_root) as directory:
        manifest = Path(directory) / "proof.json"
        repository_ref = manifest.relative_to(repository_root).as_posix()
        manifest.write_text(json.dumps({
            "status": "passed", "commit": "abc123", "finished_at": OBSERVED_AT,
            "transcript": "private",
        }))
        ledger = EvidenceLedger(tmp_path / "ledger.json")
        with pytest.raises(ValidationError, match="forbidden field"):
            ledger.collect_repository_manifest(
                manifest, repository_ref=repository_ref, source_id="harness-GH-68",
                lifecycle_stage="verification", lifecycle_transition="full-harness-completed",
                environment="local-macos", linear_issue_id="YAN-50", github_issue_or_pr_id="GH-68",
                promotion_category="gate",
            )
        assert not ledger.path.exists()

        manifest.write_text(json.dumps({
            "status": "passed", "commit": "abc123", "finished_at": OBSERVED_AT,
            "workspace": "/Users/alice/private-workspace",
        }))
        with pytest.raises(ValidationError, match="match repository_ref"):
            ledger.collect_repository_manifest(
                manifest, repository_ref="logs/harness/different.json", source_id="harness-GH-68",
                lifecycle_stage="verification", lifecycle_transition="full-harness-completed",
                environment="local-macos", linear_issue_id="YAN-50", github_issue_or_pr_id="GH-68",
                promotion_category="gate",
            )
        outside = tmp_path / "outside.json"
        outside.write_text(manifest.read_text())
        symlink = Path(directory) / "outside-link.json"
        symlink.symlink_to(outside)
        with pytest.raises(ValidationError, match="inside the repository"):
            ledger.collect_repository_manifest(
                symlink, repository_ref=symlink.relative_to(repository_root).as_posix(),
                source_id="harness-GH-68", lifecycle_stage="verification",
                lifecycle_transition="full-harness-completed", environment="local-macos",
                linear_issue_id="YAN-50", github_issue_or_pr_id="GH-68", promotion_category="gate",
            )
        normalized = ledger.collect_repository_manifest(
            manifest, repository_ref=repository_ref, source_id="harness-GH-68",
            lifecycle_stage="verification", lifecycle_transition="full-harness-completed",
            environment="local-macos", linear_issue_id="YAN-50", github_issue_or_pr_id="GH-68",
            promotion_category="gate",
        )
        record = normalized["records"][0]
        assert record["revision"] == "abc123"
        assert record["artifact_sha256"].startswith("sha256:")
        assert "/Users/" not in json.dumps(normalized)


@pytest.mark.parametrize("field", [
    "access_token", "client_secret", "private_key", "github_pat", "accessToken", "clientSecret",
    "access_token_value",
    "aws_access_key_id", "aws_secret_access_key", "AWSAccessKeyId", "AWSAccessKey", "AWSSecretKey",
])
def test_manifest_rejects_bare_credential_field_names(tmp_path: Path, field: str):
    repository_root = Path(__file__).parents[1]
    with tempfile.TemporaryDirectory(dir=repository_root) as directory:
        manifest = Path(directory) / "proof.json"
        manifest.write_text(json.dumps({
            "status": "passed", "commit": "abc123", "finished_at": OBSERVED_AT,
            field: "opaque-value",
        }))
        with pytest.raises(ValidationError, match="forbidden field"):
            EvidenceLedger(tmp_path / "ledger.json").collect_repository_manifest(
                manifest, repository_ref=manifest.relative_to(repository_root).as_posix(),
                source_id="harness-GH-68", lifecycle_stage="verification",
                lifecycle_transition="full-harness-completed", environment="local-macos",
                linear_issue_id="YAN-50", github_issue_or_pr_id="GH-68", promotion_category="gate",
            )


@pytest.mark.parametrize("field", ["token=supersecret", "/Users/alice/private-proof"])
def test_manifest_rejects_secret_or_private_text_in_field_names(tmp_path: Path, field: str):
    repository_root = Path(__file__).parents[1]
    with tempfile.TemporaryDirectory(dir=repository_root) as directory:
        manifest = Path(directory) / "proof.json"
        manifest.write_text(json.dumps({
            "status": "passed", "commit": "abc123", "finished_at": OBSERVED_AT,
            field: "opaque-value",
        }))
        with pytest.raises(ValidationError, match="forbidden field") as error:
            EvidenceLedger(tmp_path / "ledger.json").collect_repository_manifest(
                manifest, repository_ref=manifest.relative_to(repository_root).as_posix(),
                source_id="harness-GH-68", lifecycle_stage="verification",
                lifecycle_transition="full-harness-completed", environment="local-macos",
                linear_issue_id="YAN-50", github_issue_or_pr_id="GH-68", promotion_category="gate",
            )
        assert field not in str(error.value)


@pytest.mark.parametrize("secret", [
    "-----BEGIN " + "PRIVATE KEY-----",
    "sk-" + "a" * 40,
    "sk-" + "ant-" + "a" * 32,
    "AI" + "za" + "A" * 35,
    "gh" + "p_" + "A" * 36,
    "hf_" + "A" * 30,
    "sk_" + "live_" + "A" * 24,
    "AK" + "IA" + "A" * 16,
])
def test_manifest_rejects_repository_secret_formats_in_values(tmp_path: Path, secret: str):
    repository_root = Path(__file__).parents[1]
    with tempfile.TemporaryDirectory(dir=repository_root) as directory:
        manifest = Path(directory) / "proof.json"
        manifest.write_text(json.dumps({
            "status": "passed", "commit": "abc123", "finished_at": OBSERVED_AT,
            "note": secret,
        }))
        with pytest.raises(ValidationError, match="secret-like value") as error:
            EvidenceLedger(tmp_path / "ledger.json").collect_repository_manifest(
                manifest, repository_ref=manifest.relative_to(repository_root).as_posix(),
                source_id="harness-GH-68", lifecycle_stage="verification",
                lifecycle_transition="full-harness-completed", environment="local-macos",
                linear_issue_id="YAN-50", github_issue_or_pr_id="GH-68", promotion_category="gate",
            )
        assert secret not in str(error.value)


def test_manifest_rejects_duplicate_json_keys_before_privacy_scan(tmp_path: Path):
    repository_root = Path(__file__).parents[1]
    with tempfile.TemporaryDirectory(dir=repository_root) as directory:
        manifest = Path(directory) / "proof.json"
        manifest.write_text(
            '{"status":"passed","commit":"abc123","finished_at":"'
            + OBSERVED_AT
            + '","token=supersecret":"first","token=supersecret":"second"}'
        )
        with pytest.raises(ValidationError, match="duplicate JSON field") as error:
            EvidenceLedger(tmp_path / "ledger.json").collect_repository_manifest(
                manifest, repository_ref=manifest.relative_to(repository_root).as_posix(),
                source_id="harness-GH-68", lifecycle_stage="verification",
                lifecycle_transition="full-harness-completed", environment="local-macos",
                linear_issue_id="YAN-50", github_issue_or_pr_id="GH-68", promotion_category="gate",
            )
        assert "supersecret" not in str(error.value)


def test_source_refs_reject_uri_fallback_and_opaque_external_refs(tmp_path: Path):
    ledger = EvidenceLedger(tmp_path / "ledger.json")
    with pytest.raises(ValidationError, match="inspectable approved reference"):
        ledger._collect_normalized([source(
            source_type="repository", source_ref="https://evil.example/readback",
            artifact_sha256="sha256:" + "a" * 64,
        )])
    with pytest.raises(ValidationError, match="inspectable approved reference"):
        ledger._collect_normalized([source(source_type="analytics", source_ref="analytics:cohort-7")])
    with pytest.raises(ValidationError, match="inspectable approved reference"):
        ledger._collect_normalized([source(source_type="analytics", source_ref="https://evil.example/readback")])
    with pytest.raises(ValidationError, match="inspectable approved reference"):
        ledger._collect_normalized([source(source_type="analytics", source_ref="https://us.posthog.com")])
    with pytest.raises(ValidationError, match="inspectable approved reference"):
        ledger._collect_normalized([source(source_type="diagnostics", source_ref="https://sentry.io")])
    with pytest.raises(ValidationError, match="inspectable approved reference"):
        ledger._collect_normalized([source(source_ref="https://[broken")])
    with pytest.raises(ValidationError, match="inspectable approved reference"):
        ledger._collect_normalized([source(source_type="analytics", source_ref="https://[broken")])
    for source_ref in ("https://github.com:bad/x", "https://github.com:99999/x", "https://github.com:1/x"):
        with pytest.raises(ValidationError, match="inspectable approved reference"):
            ledger._collect_normalized([source(source_ref=source_ref)])
    for item in (
        source(source_type="linear", source_ref="https://linear.app:1/yannjy/issue/YAN-50"),
        source(source_type="analytics", source_ref="https://us.posthog.com:1/project/1/insights/2"),
        source(source_type="diagnostics", source_ref="https://sentry.io:1/organizations/example/issues/1"),
    ):
        with pytest.raises(ValidationError, match="inspectable approved reference"):
            ledger._collect_normalized([item])
    accepted = ledger._collect_normalized([
        source(source_type="analytics", source_ref="https://eu.posthog.com/project/1/insights/2"),
        source(
            source_type="diagnostics", source_id="sentry-issue-1",
            source_ref="https://example.sentry.io/issues/1/", lifecycle_transition="diagnostics-readback",
        ),
    ])
    assert {record["source_type"] for record in accepted["records"]} == {"analytics", "diagnostics"}


@pytest.mark.parametrize("item", [
    source(
        source_type="linear", source_id="YAN-51", linear_issue_id="YAN-50",
        source_ref="https://linear.app/yannjy/issue/YAN-50",
    ),
    source(
        source_type="github", source_id="GH-69", github_issue_or_pr_id="GH-68",
        source_ref="https://github.com/YannJY02/AutoTranscribe/issues/68",
    ),
    source(
        source_type="linear", source_id="YAN-50",
        source_ref="https://linear.app/yannjy/issue/YAN-51",
    ),
    source(
        source_type="linear", source_id="YAN-50",
        source_ref="https://linear.app/attacker/issue/YAN-50",
    ),
    source(
        source_type="github", source_id="GH-68",
        source_ref="https://github.com/YannJY02/AutoTranscribe/issues/69",
    ),
    source(
        source_type="github", source_id="GH-68",
        source_ref="https://github.com/extra/YannJY02/AutoTranscribe/issues/68",
    ),
    source(
        source_type="ci", source_id="check-101",
        source_ref="https://github.com/YannJY02/AutoTranscribe/actions/runs/102",
    ),
    source(
        source_type="ci", source_id="check-101",
        source_ref="https://github.com/extra/YannJY02/AutoTranscribe/actions/runs/101",
    ),
    source(
        source_type="linear", source_id="not-a-linear-id", linear_issue_id=None,
        source_ref="https://linear.app/yannjy/issue/not-a-linear-id",
    ),
    source(
        source_type="github", source_id="PR-68", github_issue_or_pr_id="PR-68",
        source_ref="https://github.com/YannJY02/AutoTranscribe/issues/68",
    ),
])
def test_task_and_ci_references_must_identify_the_linked_evidence(tmp_path: Path, item: dict):
    with pytest.raises(ValidationError, match="identify the linked evidence"):
        EvidenceLedger(tmp_path / "ledger.json")._collect_normalized([item])


def test_cli_rejects_escaped_unicode_surrogates_without_a_traceback(tmp_path: Path):
    input_path = tmp_path / "input.json"
    item = source(
        source_type="analytics",
        source_id="aggregate-1",
        source_ref="https://us.posthog.com/project/1/insights/\ud800",
    )
    generated = {"privacy_class", "fact", "gap_or_decision", "owner_action", "recheck_source", "human_gate"}
    input_path.write_text(json.dumps([
        {"adapter": "external-reference", **{key: value for key, value in item.items() if key not in generated}}
    ]))
    completed = subprocess.run(
        [
            sys.executable,
            "scripts/evidence_ledger.py",
            "--ledger", str(tmp_path / "ledger.json"),
            "--input", str(input_path),
        ],
        cwd=Path(__file__).parents[1],
        text=True,
        capture_output=True,
        check=False,
    )

    assert completed.returncode == 2
    assert "Traceback" not in completed.stderr


def test_schema_boundaries_reject_overlong_https_refs_numeric_ids_and_non_rfc3339_timestamps(tmp_path: Path):
    ledger = EvidenceLedger(tmp_path / "ledger.json")
    with pytest.raises(ValidationError, match="inspectable approved reference"):
        ledger._collect_normalized([source(source_ref="https://github.com/" + "a" * 500)])
    with pytest.raises(ValidationError, match="inspectable approved reference"):
        ledger._collect_normalized([source(source_ref="https://github.com/x\r# forged")])
    for unsafe_ref in (
        "https://github.com/x\u202e#forged",
        "https://github.com/x\u009f#forged",
    ):
        with pytest.raises(ValidationError, match="inspectable approved reference"):
            ledger._collect_normalized([source(source_ref=unsafe_ref)])
    with pytest.raises(ValidationError, match="issue or PR identifier"):
        ledger._collect_normalized([source(github_issue_or_pr_id=68)])
    for field in ("lifecycle_stage", "lifecycle_transition", "environment"):
        with pytest.raises(ValidationError, match=field):
            ledger._collect_normalized([source(**{field: 1})])
    for unsafe in ("safe\r# forged", "safe\x00forged", "safe\u2028# forged"):
        with pytest.raises(ValidationError, match="bounded non-empty metadata"):
            ledger._collect_normalized([source(fact=unsafe)])
    for observed_at in (
        "2026-W35T09:00:00Z", "2026-08-30 09:00:00Z", "2026-08-30T09:00:00+00:00:01",
        "2026-08-30T09:00:00+00:60", "2026-08-30T09:00:00+24:00",
    ):
        with pytest.raises(ValidationError, match="RFC 3339"):
            ledger._collect_normalized([source(observed_at=observed_at)])


def test_repository_backed_external_evidence_requires_a_real_privacy_safe_manifest(tmp_path: Path):
    repository_root = Path(__file__).parents[1]
    ledger = EvidenceLedger(tmp_path / "ledger.json")
    metadata = {
        key: value for key, value in source(
            source_type="pilot", source_id="pilot-1", source_ref="logs/pilot/missing.json",
        ).items()
        if key not in {"privacy_class", "fact", "gap_or_decision", "owner_action", "recheck_source", "human_gate"}
    }
    with pytest.raises(ValidationError, match="unreadable or malformed"):
        ledger.collect_external_reference(**metadata)

    with tempfile.TemporaryDirectory(dir=repository_root) as directory:
        manifest = Path(directory) / "pilot.json"
        repository_ref = manifest.relative_to(repository_root).as_posix()
        manifest.write_text(json.dumps({"status": "passed", "access_token": "ghp_abcdefghijklmnopqrstuvwxyz012345"}))
        with pytest.raises(ValidationError, match="forbidden field"):
            ledger.collect_external_reference(**{**metadata, "source_ref": repository_ref})

        manifest.write_text(json.dumps({
            "status": "failed", "revision": "pilot-rev-1", "observed_at": OBSERVED_AT,
            "run_id": "pilot-1",
        }))
        record = ledger.collect_external_reference(**{**metadata, "source_ref": repository_ref})["records"][0]
        assert record["artifact_sha256"].startswith("sha256:")
        assert record["result"] == "failed"
        assert record["revision"] == "pilot-rev-1"
        assert record["fact"] == "Pilot reference metadata reports failed."


@pytest.mark.parametrize("degraded", [
    {"revision": "unavailable", "result": "passed"},
    {"revision": "UNAVAILABLE", "result": "passed"},
    {"lifecycle_transition": "connector-unavailable", "result": "passed"},
    {"lifecycle_transition": "source-unobserved", "result": "passed"},
    {"unknowns": ["connector-unavailable"], "result": "passed"},
])
def test_unavailable_or_degraded_sources_never_pass(tmp_path: Path, degraded: dict):
    with pytest.raises(ValidationError, match="unavailable|degraded"):
        EvidenceLedger(tmp_path / "ledger.json")._collect_normalized([source(**degraded)])


def test_unavailable_repository_source_is_explicitly_unobserved(tmp_path: Path):
    record = EvidenceLedger(tmp_path / "ledger.json").collect_unavailable(
        "repository", "harness-GH-68", "manifest-unavailable", observed_at=OBSERVED_AT,
        environment="local-macos", lifecycle_stage="verification", linear_issue_id="YAN-50",
        github_issue_or_pr_id="GH-68",
    )["records"][0]
    assert record["result"] == "unobserved"
    assert record["revision"] == "unavailable"
    assert record["artifact_sha256"] is None


def test_unavailable_ci_source_links_to_the_check_run(tmp_path: Path):
    record = EvidenceLedger(tmp_path / "ledger.json").collect_unavailable(
        "ci", "check-101", "check-unavailable", observed_at=OBSERVED_AT,
        environment="github-actions", lifecycle_stage="verification", linear_issue_id="YAN-50",
        github_issue_or_pr_id="GH-68",
    )["records"][0]
    assert record["source_ref"] == "https://github.com/YannJY02/AutoTranscribe/actions/runs/101"
    assert record["result"] == "unobserved"


def test_unavailable_github_pr_source_links_to_the_pull_request(tmp_path: Path):
    record = EvidenceLedger(tmp_path / "ledger.json").collect_unavailable(
        "github", "PR-68", "github-unavailable", observed_at=OBSERVED_AT,
        environment="github-actions", lifecycle_stage="verification", linear_issue_id="YAN-50",
        github_issue_or_pr_id="PR-68",
    )["records"][0]
    assert record["source_ref"] == "https://github.com/YannJY02/AutoTranscribe/pull/68"


def test_content_hash_cannot_be_used_as_source_id(tmp_path: Path):
    ledger = EvidenceLedger(tmp_path / "ledger.json")
    for source_id in ("sha256:deadbeef", "a" * 64):
        with pytest.raises(ValidationError, match="stable metadata identifier"):
            ledger._collect_normalized([source(source_id=source_id)])


def test_schema_matches_the_accepted_yan_43_record_contract():
    schema = json.loads((Path(__file__).parents[1] / "docs/evidence/evidence-record.schema.json").read_text())
    required = set(schema["required"])
    assert {
        "schema_version", "evidence_id", "linear_issue_id", "github_issue_or_pr_id",
        "lifecycle_stage", "lifecycle_transition", "source_type", "source_id", "source_ref",
        "revision", "artifact_sha256", "observed_at", "environment", "result", "claim_class",
        "promotion_category", "privacy_class", "supersedes",
    } <= required
    assert schema["properties"]["claim_class"]["enum"] == ["observed", "accepted-decision", "inference", "unknown"]
    assert "superseded" in schema["properties"]["result"]["enum"]


def test_boolean_schema_versions_are_rejected(tmp_path: Path):
    ledger = EvidenceLedger(tmp_path / "ledger.json")
    normalized = ledger._collect_normalized([source()])
    with pytest.raises(ValidationError, match="malformed ledger"):
        ledger._validate_ledger({**normalized, "schema_version": True})
    with pytest.raises(ValidationError, match="record schema_version"):
        ledger._validate_ledger({
            **normalized,
            "records": [{**normalized["records"][0], "schema_version": True}],
        })


def test_readme_adapter_example_is_executable(tmp_path: Path):
    readme = (Path(__file__).parents[1] / "docs/evidence/README.md").read_text()
    example = readme.split("```json\n", 1)[1].split("\n```", 1)[0]
    normalized = EvidenceLedger(tmp_path / "ledger.json").collect_adapter_items(json.loads(example))
    assert len(normalized["records"]) == 1


def test_repeated_feedback_requires_independent_runs_but_severe_event_routes_once(tmp_path: Path):
    ledger = EvidenceLedger(tmp_path / "ledger.json")
    below = ledger.route_repeated_feedback(
        "redaction-boundary", evidence_refs=[
            "https://github.com/YannJY02/AutoTranscribe/pull/1",
            "https://github.com/YannJY02/AutoTranscribe/pull/2",
        ], run_ids=["review-1", "review-1"], event_class="review",
        available_surfaces=["docs/agents/harness.md"],
    )
    severe = ledger.route_repeated_feedback(
        "credential-leak", evidence_refs=["https://github.com/YannJY02/AutoTranscribe/issues/3"],
        run_ids=["bug-3"], event_class="security", available_surfaces=["docs/agents/harness.md"],
    )
    assert below["status"] == "below-threshold"
    assert severe["status"] == "accepted"
    assert severe["selected_surfaces"] == ["docs/agents/harness.md"]
    with pytest.raises(ValidationError, match="feedback evidence"):
        ledger.route_repeated_feedback(
            "missing-proof", evidence_refs=["logs/no/a.json", "logs/no/b.json"],
            run_ids=["review-1", "review-2"], event_class="review",
            available_surfaces=["docs/agents/harness.md"],
        )
    for host_only in ("https://github.com", "https://linear.app"):
        with pytest.raises(ValidationError, match="feedback evidence"):
            ledger.route_repeated_feedback(
                "missing-remote-proof", evidence_refs=[host_only, host_only],
                run_ids=["review-1", "review-2"], event_class="review",
                available_surfaces=["docs/agents/harness.md"],
            )


def test_handoff_requires_explicit_linked_evidence_and_validates_supplied_ledger(tmp_path: Path):
    ledger = EvidenceLedger(tmp_path / "ledger.json")
    artifact_sha = "sha256:" + "a" * 64
    normalized = ledger._collect_normalized([source(
        source_type="repository", source_ref="logs/harness/GH-68/manifest.json",
        artifact_sha256=artifact_sha,
    )])
    evidence_id = normalized["records"][0]["evidence_id"]
    with pytest.raises(ValidationError, match="explicit evidence IDs"):
        ledger.issue_handoff("GH-68", normalized)
    with pytest.raises(ValidationError, match="not linked"):
        ledger.issue_handoff("GH-69", normalized, evidence_ids={evidence_id})
    with pytest.raises(ValidationError, match="malformed ledger"):
        ledger.issue_handoff("GH-68", {"schema_version": 1, "records": [{"fact": "forged"}]}, evidence_ids={evidence_id})
    handoff = ledger.issue_handoff("GH-68", normalized, evidence_ids={evidence_id})
    assert "Focused regressions passed" in handoff
    assert f"Evidence ID: ` {evidence_id} `" in handoff
    assert f"Artifact SHA-256: ` {artifact_sha} `" in handoff


def test_handoff_escapes_markdown_in_every_rendered_claim_field(tmp_path: Path):
    malicious_link = ")[forged](https://evil.example"
    malicious_prose = f"``ticks`` {malicious_link} @octocat ~~strike~~"
    ledger = EvidenceLedger(tmp_path / "ledger.json")
    normalized = ledger._collect_normalized([source(
        source_type="analytics", source_id="aggregate-1",
        source_ref=f"https://us.posthog.com/project/1/insights/2{malicious_link}",
        fact=f"Observed {malicious_prose}",
        recheck_source=f"https://us.posthog.com/project/1/insights/2{malicious_link}",
    )])
    evidence_id = normalized["records"][0]["evidence_id"]

    handoff = ledger.issue_handoff("GH-68", normalized, evidence_ids={evidence_id})

    assert f"``` Observed {malicious_prose} ```" in handoff
    assert f"` https://us.posthog.com/project/1/insights/2{malicious_link} `" in handoff


def test_friday_update_requires_live_linear_and_linked_evidence(tmp_path: Path):
    ledger = EvidenceLedger(tmp_path / "ledger.json")
    normalized = ledger._collect_normalized([
        source(source_type="linear", source_id="YAN-50", source_ref="https://linear.app/yannjy/issue/YAN-50",
               revision="linear-rev-7", promotion_category="status"),
        source(source_type="repository", source_id="harness-GH-68", source_ref="logs/harness/GH-68/manifest.json",
               revision="abc123", artifact_sha256="sha256:" + "a" * 64),
    ])
    linear_id = next(r["evidence_id"] for r in normalized["records"] if r["source_type"] == "linear")
    repository_id = next(r["evidence_id"] for r in normalized["records"] if r["source_type"] == "repository")
    update = ledger.friday_update(
        "2026-W35", normalized, live_linear_evidence_ids={linear_id}, linked_evidence_ids={repository_id},
    )
    assert "Friday Project Update" in update and "Focused regressions passed" in update

    cross_issue = ledger._collect_normalized([
        source(
            source_type="repository", source_id="harness-GH-69",
            source_ref="logs/harness/GH-69/manifest.json", linear_issue_id="YAN-51",
            github_issue_or_pr_id="GH-69", revision="def456",
            artifact_sha256="sha256:" + "b" * 64,
        )
    ])
    cross_issue_id = next(
        record["evidence_id"] for record in cross_issue["records"]
        if record["source_id"] == "harness-GH-69"
    )
    with pytest.raises(ValidationError, match="live Linear evidence"):
        ledger.friday_update(
            "2026-W35", cross_issue,
            live_linear_evidence_ids={linear_id}, linked_evidence_ids={cross_issue_id},
        )

    unavailable_ledger = EvidenceLedger(tmp_path / "unavailable.json")
    unavailable = unavailable_ledger.collect_unavailable(
        "linear", "YAN-50", "linear-unavailable", observed_at=OBSERVED_AT,
        environment="controller", lifecycle_stage="handoff", linear_issue_id="YAN-50",
    )
    unavailable_id = unavailable["records"][0]["evidence_id"]
    with pytest.raises(ValidationError, match="live Linear evidence"):
        unavailable_ledger.friday_update(
            "2026-W35", unavailable,
            live_linear_evidence_ids={unavailable_id}, linked_evidence_ids=set(),
        )

    inferred_ledger = EvidenceLedger(tmp_path / "inferred.json")
    inferred = inferred_ledger._collect_normalized([
        source(
            source_type="linear", source_id="YAN-50",
            source_ref="https://linear.app/yannjy/issue/YAN-50",
            revision="linear-inference-1", claim_class="inference", promotion_category="status",
        )
    ])
    inferred_id = inferred["records"][0]["evidence_id"]
    with pytest.raises(ValidationError, match="live Linear evidence"):
        inferred_ledger.friday_update(
            "2026-W35", inferred,
            live_linear_evidence_ids={inferred_id}, linked_evidence_ids=set(),
        )

    mixed = ledger._collect_normalized([
        source(
            source_type="linear", source_id="YAN-51",
            source_ref="https://linear.app/yannjy/issue/YAN-51",
            linear_issue_id="YAN-51", revision="linear-inference-2",
            lifecycle_transition="linked-status", claim_class="inference",
            promotion_category="status",
        )
    ])
    inferred_linked_id = next(
        record["evidence_id"] for record in mixed["records"]
        if record["source_id"] == "YAN-51"
    )
    with pytest.raises(ValidationError, match="live Linear evidence"):
        ledger.friday_update(
            "2026-W35", mixed,
            live_linear_evidence_ids={linear_id}, linked_evidence_ids={inferred_linked_id},
        )


def test_adapter_rejects_claim_prose_and_non_array_cli_input(tmp_path: Path):
    ledger = EvidenceLedger(tmp_path / "ledger.json")
    item = source()
    adapter_item = {"adapter": "external-reference", **{
        key: value for key, value in item.items()
        if key not in {"privacy_class", "fact", "gap_or_decision", "owner_action", "recheck_source", "human_gate"}
    }}
    with pytest.raises(ValidationError, match="array"):
        ledger.collect_adapter_items({"not": "an array"})
    with pytest.raises(ValidationError, match="unsupported fields"):
        ledger.collect_adapter_items([{**adapter_item, "fact": "private caller prose"}])

    input_path = tmp_path / "input.json"
    input_path.write_text("{}")
    script = Path(__file__).parents[1] / "scripts" / "evidence_ledger.py"
    completed = subprocess.run(
        [sys.executable, str(script), "--ledger", str(tmp_path / "cli.json"), "--input", str(input_path)],
        text=True, capture_output=True, check=False,
    )
    assert completed.returncode == 2
    assert "array" in completed.stderr


@pytest.mark.parametrize("payload", ["null", "0", "true"])
def test_cli_rejects_every_non_array_json_value(tmp_path: Path, payload: str):
    input_path = tmp_path / "input.json"
    input_path.write_text(payload)
    completed = subprocess.run(
        [
            sys.executable, str(Path(__file__).parents[1] / "scripts" / "evidence_ledger.py"),
            "--ledger", str(tmp_path / "ledger.json"), "--input", str(input_path),
        ],
        text=True, capture_output=True, check=False,
    )
    assert completed.returncode == 2
    assert "array" in completed.stderr


def test_cli_rejects_non_utf8_input_without_traceback(tmp_path: Path):
    input_path = tmp_path / "input.json"
    input_path.write_bytes(b"\xff")
    completed = subprocess.run(
        [
            sys.executable, str(Path(__file__).parents[1] / "scripts" / "evidence_ledger.py"),
            "--ledger", str(tmp_path / "ledger.json"), "--input", str(input_path),
        ],
        text=True, capture_output=True, check=False,
    )

    assert completed.returncode == 2
    assert "Traceback" not in completed.stderr


def test_typed_adapter_batch_is_order_independent(tmp_path: Path):
    items = []
    for revision, result in [("build-a", "passed"), ("build-b", "failed")]:
        item = source(revision=revision, result=result)
        items.append({"adapter": "external-reference", **{
            key: value for key, value in item.items()
            if key not in {"privacy_class", "fact", "gap_or_decision", "owner_action", "recheck_source", "human_gate"}
        }})
    forward = EvidenceLedger(tmp_path / "forward.json")
    reverse = EvidenceLedger(tmp_path / "reverse.json")
    forward.collect_adapter_items(items)
    reverse.collect_adapter_items(reversed(items))
    assert forward.path.read_bytes() == reverse.path.read_bytes()
