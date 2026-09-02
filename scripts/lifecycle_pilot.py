#!/usr/bin/env python3
"""Run and verify the bounded, privacy-safe GH-73 owner pilot."""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import re
import subprocess
import sys
import tempfile
import zipfile
from datetime import UTC, datetime
from functools import wraps
from pathlib import Path, PurePosixPath
from typing import Any

if __package__:
    from .agent_harness import gate_specs as harness_gate_specs
    from .evidence_ledger import EvidenceLedger, ValidationError
    from .evidence_ledger import _walk as _privacy_scan
else:
    from agent_harness import gate_specs as harness_gate_specs
    from evidence_ledger import EvidenceLedger, ValidationError
    from evidence_ledger import _walk as _privacy_scan


ATTEMPT_ORDER = ("live-local", "live-cloud", "import-local", "import-cloud")
POST_HARNESS_EVIDENCE_REFS = {
    "pilots/evidence/GH-73/full-harness-manifest.json",
    "pilots/evidence/GH-73/repository-proof.json",
    "pilots/gh-73-owner-lifecycle.json",
}
STAGES = (
    "started",
    "record_saved",
    "record_reopened",
    "smart_minutes_review_opened",
    "export_completed",
    "workflow_completed",
)
PRODUCT_ANALYTICS_EVENTS = {
    "workflow_started",
    "record_saved",
    "record_reopened",
    "transcript_search_completed",
    "smart_minutes_review_opened",
    "export_completed",
    "workflow_completed",
    "workflow_failed",
    "recovery_attempted",
    "recovery_completed",
    "telemetry_consent_changed",
}
CLASSIFICATIONS = {"observed", "inference", "unobserved"}
STAGE_RESULTS = {"observed", "failed", "blocked", "unobserved"}
SHA = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
CODE = re.compile(r"^[a-z0-9][a-z0-9._:-]{0,127}$")
ROLLBACK_CHECKS = (
    "unified-consent-revocation",
    "deterministic-queue-purge-readback",
    "sentry-disable-without-environment",
)
ROLLBACK_PACKAGE_REF = "macos/InsightKitApp"
OWNER_PILOT_SIGNING_TEAM_ID = "KBAF95R4C5"
OWNER_PILOT_SIGNING_CERT_SHA256 = (
    "c59c2eeaae7f38f50b04885c679938dc1e0a1fcfb0b7e46c8caa8b852b4676b1"
)
OWNER_PILOT_SIGNER_POLICY = "owner-pilot-apple-development-v1"
BUILD_PROOF_FIELDS = {
    "status",
    "commit",
    "app_bundle_ref",
    "app_bundle_sha256",
    "app_archive_ref",
    "app_archive_sha256",
    "build_version",
    "build_source",
    "git_revision_short",
    "package_script_sha256",
    "bundle_cdhash",
    "executable_sha256",
    "source_attestation_ref",
    "source_attestation_sha256",
    "source_attestation_signature_ref",
    "source_attestation_signature_sha256",
    "signing_team_id",
    "signing_leaf_certificate_sha256",
    "source_clean",
    "distribution",
    "signing",
    "verification",
}
ATTEMPT_EVIDENCE_FIELDS = {
    "status",
    "issue",
    "commit",
    "pilot_id",
    "evidence_kind",
    "subject",
    "observed_at",
    "privacy_safe",
    "scenario",
    "analysis_mode",
    "analysis_mode_observed",
    "stages",
    "app",
    "visual",
    "host_attempts",
    "unknowns",
}
RECONCILIATION_EVIDENCE_FIELDS = {
    "posthog": {
        "status",
        "issue",
        "commit",
        "pilot_id",
        "evidence_kind",
        "subject",
        "observed_at",
        "scope",
        "project_id",
        "region",
        "environment",
        "schema_version",
        "window_start",
        "window_end",
        "event_count",
        "event_counts",
        "readback",
        "source_issue",
        "privacy_safe",
    },
    "sentry": {
        "status",
        "issue",
        "commit",
        "pilot_id",
        "evidence_kind",
        "subject",
        "observed_at",
        "scope",
        "project_id",
        "issue_id",
        "event_id",
        "event_created_at",
        "environment",
        "release",
        "platform",
        "classification",
        "privacy_safe",
    },
    "langfuse": {
        "status",
        "issue",
        "commit",
        "pilot_id",
        "evidence_kind",
        "subject",
        "observed_at",
        "scope",
        "project_id",
        "dataset_id",
        "dataset_name",
        "dataset_sha256",
        "dataset_item_count",
        "experiment_id",
        "experiment_name",
        "experiment_item_count",
        "score_count",
        "score_names",
        "score_environment",
        "observation_environment",
        "privacy_safe",
    },
    "repository": {
        "status",
        "issue",
        "commit",
        "pilot_id",
        "evidence_kind",
        "subject",
        "observed_at",
        "scope",
        "checks",
        "harness_manifest_ref",
        "harness_manifest_sha256",
        "privacy_safe",
    },
}
ROLLBACK_EVIDENCE_FIELDS = {
    "status",
    "issue",
    "commit",
    "pilot_id",
    "evidence_kind",
    "subject",
    "observed_at",
    "consent_disabled",
    "queues_purged",
    "app_target_verified",
    "evidence_preserved",
    "rollback_target",
    "rollback_target_sha256",
    "checks",
    "native_proof_ref",
    "test_source_sha256",
    "evidence_sha256_before",
    "evidence_sha256_after",
}


class PilotValidationError(ValueError):
    """Pilot input is outside the accepted scope, schema, or privacy boundary."""


def _fail(message: str) -> None:
    raise PilotValidationError(message)


def _validation_boundary(function: Any) -> Any:
    @wraps(function)
    def bounded(*args: Any, **kwargs: Any) -> Any:
        try:
            return function(*args, **kwargs)
        except PilotValidationError:
            raise
        except (AttributeError, TypeError) as error:
            raise PilotValidationError("pilot input has invalid value types") from error

    return bounded


def _walk(value: Any) -> None:
    try:
        _privacy_scan(value)
    except ValidationError as error:
        raise PilotValidationError(
            "pilot evidence failed the shared privacy boundary"
        ) from error


def _repo_ref(value: Any) -> bool:
    if (
        not isinstance(value, str)
        or len(value) > 500
        or value.startswith(("/", "\\"))
        or "://" in value
        or "\\" in value
    ):
        return False
    path = PurePosixPath(value)
    return len(path.parts) > 1 and all(
        part not in {"", ".", ".."} for part in path.parts
    )


def _timestamp(value: Any) -> datetime:
    if not isinstance(value, str):
        _fail("pilot timestamps must use RFC 3339")
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        _fail("pilot timestamps must use RFC 3339")
    if parsed.tzinfo is None:
        _fail("pilot timestamps must include a timezone")
    return parsed


def _require_keys(value: Any, keys: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or not keys.issubset(value):
        _fail(f"{label} is incomplete")
    return value


def _exact_keys(value: dict[str, Any], keys: set[str], label: str) -> None:
    if set(value) != keys:
        _fail(f"{label} fields do not match the schema")


def _artifact_sha(path: Path) -> str:
    digest = hashlib.sha256()
    if path.is_file():
        digest.update(path.read_bytes())
    else:
        for child in sorted(item for item in path.rglob("*") if item.is_file()):
            digest.update(child.relative_to(path).as_posix().encode())
            digest.update(b"\0")
            digest.update(child.read_bytes())
    return digest.hexdigest()


def _git_blob(root: Path, commit: str, ref: str) -> bytes:
    result = subprocess.run(
        ["git", "-C", str(root), "show", f"{commit}:{ref}"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if result.returncode != 0:
        _fail("frozen source commit is unavailable")
    return result.stdout


def _git_head(root: Path) -> str:
    result = subprocess.run(
        ["git", "-C", str(root), "rev-parse", "HEAD"],
        capture_output=True,
        check=False,
        text=True,
    )
    if result.returncode != 0:
        _fail("repository Harness candidate commit is unavailable")
    return result.stdout.strip()


def _git_diff_files(root: Path, base: str, commit: str) -> list[str]:
    result = subprocess.run(
        ["git", "-C", str(root), "diff", "--name-only", f"{base}...{commit}"],
        capture_output=True,
        check=False,
        text=True,
    )
    if result.returncode != 0:
        _fail("repository Harness base diff is unavailable")
    return sorted({line for line in result.stdout.splitlines() if line})


def _git_is_ancestor(root: Path, commit: str) -> bool:
    return subprocess.run(
        ["git", "-C", str(root), "merge-base", "--is-ancestor", commit, "HEAD"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    ).returncode == 0


def _source_sha(root: Path, commit: str) -> str:
    result = subprocess.run(
        [
            "git",
            "-C",
            str(root),
            "ls-tree",
            "-r",
            "--name-only",
            commit,
            "--",
            ROLLBACK_PACKAGE_REF,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
        text=True,
    )
    refs = result.stdout.splitlines()
    if result.returncode != 0 or not refs:
        _fail("frozen Swift package is unavailable")
    digest = hashlib.sha256()
    for ref in refs:
        digest.update(ref.encode())
        digest.update(b"\0")
        digest.update(_git_blob(root, commit, ref))
    return digest.hexdigest()


def _git_tree(root: Path, commit: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(root), "rev-parse", f"{commit}^{{tree}}"],
        capture_output=True,
        check=False,
        text=True,
    )
    tree = result.stdout.strip()
    if result.returncode != 0 or not SHA.fullmatch(tree):
        _fail("frozen Git tree is unavailable")
    return tree


def _run_frozen_rollback_checks(root: Path, commit: str) -> None:
    filters = (
        "ExternalTelemetryPrivacyGateTests/testUnifiedConsentRevocationPurgesProductAndSentryQueues",
        "ExternalTelemetryPrivacyGateTests/testDisablePurgesQueueAndWritesDeterministicReadbackEvidence",
        "SentryDiagnosticsAdapterTests/testExplicitDisablePurgesWithoutTelemetryEnvironment",
    )
    with tempfile.TemporaryDirectory(prefix="insightkit-rollback-") as scratch:
        worktree = Path(scratch) / "frozen"
        added = (
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(root),
                    "worktree",
                    "add",
                    "--detach",
                    str(worktree),
                    commit,
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            ).returncode
            == 0
        )
        if not added:
            _fail("frozen rollback worktree could not be created")
        try:
            command = [
                "swift",
                "test",
                "--disable-sandbox",
                "--package-path",
                ROLLBACK_PACKAGE_REF,
                *(part for test in filters for part in ("--filter", test)),
            ]
            passed = subprocess.run(command, cwd=worktree, check=False).returncode == 0
        finally:
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(root),
                    "worktree",
                    "remove",
                    "--force",
                    str(worktree),
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
        if not passed:
            _fail("rollback deterministic checks failed")


def _archive_bundle_sha(path: Path) -> tuple[str, dict[str, Any]]:
    digest = hashlib.sha256()
    try:
        with zipfile.ZipFile(path) as archive:
            files = sorted(
                (item for item in archive.infolist() if not item.is_dir()),
                key=lambda item: item.filename,
            )
            if not files or any(
                not item.filename.startswith("InsightKit.app/") for item in files
            ):
                _fail("frozen app archive has an invalid layout")
            for item in files:
                ref = PurePosixPath(item.filename.removeprefix("InsightKit.app/"))
                if not ref.parts or ".." in ref.parts:
                    _fail("frozen app archive has an invalid layout")
                digest.update(ref.as_posix().encode())
                digest.update(b"\0")
                digest.update(archive.read(item))
            info = plistlib.loads(archive.read("InsightKit.app/Contents/Info.plist"))
    except (KeyError, OSError, plistlib.InvalidFileException, zipfile.BadZipFile):
        _fail("frozen app archive is unreadable")
    return digest.hexdigest(), info


def _developer_signature_metadata(app: Path) -> dict[str, Any]:
    requirement = (
        'anchor apple generic and identifier "com.yannjy.insightkit" '
        f'and certificate leaf[subject.OU] = "{OWNER_PILOT_SIGNING_TEAM_ID}"'
    )
    with tempfile.TemporaryDirectory(prefix="insightkit-signature-") as directory:
        certificate_prefix = Path(directory) / "certificate"
        verified = subprocess.run(
            [
                "codesign",
                "--verify",
                "--deep",
                "--strict",
                f"-R={requirement}",
                str(app),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        details = subprocess.run(
            ["codesign", "-dv", "--verbose=4", str(app)],
            capture_output=True,
            check=False,
            text=True,
        )
        extracted = subprocess.run(
            [
                "codesign",
                "-d",
                f"--extract-certificates={certificate_prefix}",
                str(app),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        leaf = Path(f"{certificate_prefix}0")
        architectures = subprocess.run(
            ["lipo", "-archs", str(app / "Contents/MacOS/InsightKitApp")],
            capture_output=True,
            check=False,
            text=True,
        )
        fields = dict(
            re.findall(
                r"^(Identifier|CDHash|TeamIdentifier)=(.+)$",
                details.stderr or "",
                re.MULTILINE,
            )
        )
        leaf_sha = _artifact_sha(leaf) if leaf.is_file() else None
        archs = architectures.stdout.split()
        if (
            verified.returncode != 0
            or details.returncode != 0
            or extracted.returncode != 0
            or architectures.returncode != 0
            or fields.get("Identifier") != "com.yannjy.insightkit"
            or fields.get("TeamIdentifier") != OWNER_PILOT_SIGNING_TEAM_ID
            or not re.fullmatch(r"[0-9a-f]{40}", fields.get("CDHash", ""))
            or leaf_sha != OWNER_PILOT_SIGNING_CERT_SHA256
            or archs != ["arm64"]
        ):
            _fail("frozen app archive signature is invalid")
    return {
        "bundle_id": fields["Identifier"],
        "cdhash": fields["CDHash"],
        "team_id": fields["TeamIdentifier"],
        "leaf_certificate_sha256": leaf_sha,
        "architectures": archs,
        "executable_sha256": _artifact_sha(app / "Contents/MacOS/InsightKitApp"),
    }


def _verify_archive_signature(path: Path) -> dict[str, Any]:
    with tempfile.TemporaryDirectory(prefix="insightkit-archive-") as directory:
        extracted = Path(directory)
        unpacked = subprocess.run(
            ["ditto", "-x", "-k", str(path), str(extracted)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if unpacked.returncode != 0:
            _fail("frozen app archive signature is invalid")
        return _developer_signature_metadata(extracted / "InsightKit.app")


def _verify_source_attestation(
    root: Path,
    build: dict[str, Any],
    build_proof: dict[str, Any],
    *,
    app_sha: str,
    signature: dict[str, Any],
) -> None:
    refs = (
        build_proof.get("source_attestation_ref"),
        build_proof.get("source_attestation_signature_ref"),
    )
    paths = [(root / ref).resolve() if _repo_ref(ref) else None for ref in refs]
    if any(
        path is None or not path.is_relative_to(root) or not path.is_file()
        for path in paths
    ):
        _fail("source attestation is missing")
    statement_path, cms_path = paths
    if (
        _artifact_sha(statement_path) != build_proof["source_attestation_sha256"]
        or _artifact_sha(cms_path)
        != build_proof["source_attestation_signature_sha256"]
    ):
        _fail("source attestation digest changed")
    with tempfile.TemporaryDirectory(prefix="insightkit-attestation-") as directory:
        decoded = Path(directory) / "statement.json"
        signer = Path(directory) / "signer.pem"
        signer_der = Path(directory) / "signer.der"
        verified = subprocess.run(
            [
                "openssl",
                "cms",
                "-verify",
                "-inform",
                "DER",
                "-in",
                str(cms_path),
                "-noverify",
                "-out",
                str(decoded),
                "-signer",
                str(signer),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        converted = subprocess.run(
            [
                "openssl",
                "x509",
                "-in",
                str(signer),
                "-outform",
                "DER",
                "-out",
                str(signer_der),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if (
            verified.returncode != 0
            or converted.returncode != 0
            or not decoded.is_file()
            or decoded.read_bytes() != statement_path.read_bytes()
            or not signer_der.is_file()
            or _artifact_sha(signer_der) != OWNER_PILOT_SIGNING_CERT_SHA256
        ):
            _fail("source attestation signature is invalid")
    statement = _load_json(statement_path)
    if not isinstance(statement, dict):
        _fail("source attestation is invalid")
    _walk(statement)
    _exact_keys(
        statement,
        {"schema_version", "predicate_type", "subject", "predicate"},
        "source attestation",
    )
    subject = statement.get("subject")
    predicate = statement.get("predicate")
    if not isinstance(subject, dict) or not isinstance(predicate, dict):
        _fail("source attestation is invalid")
    _exact_keys(
        subject,
        {
            "name",
            "bundle_sha256",
            "cdhash",
            "executable_sha256",
            "bundle_id",
            "architectures",
        },
        "source attestation subject",
    )
    _exact_keys(
        predicate,
        {
            "commit",
            "git_tree",
            "package_script_sha256",
            "build_version",
            "source_clean",
            "source_state",
            "build_argv",
            "swift_version",
            "xcode_version",
            "sdk_version",
            "signing_team_id",
            "signing_leaf_certificate_sha256",
            "provenance_level",
        },
        "source attestation predicate",
    )
    expected_subject = {
        "name": "InsightKit.app",
        "bundle_sha256": app_sha,
        "cdhash": signature["cdhash"],
        "executable_sha256": signature["executable_sha256"],
        "bundle_id": signature["bundle_id"],
        "architectures": signature["architectures"],
    }
    expected_predicate = {
        "commit": build["commit"],
        "git_tree": _git_tree(root, build["commit"]),
        "package_script_sha256": build_proof["package_script_sha256"],
        "build_version": build_proof["build_version"],
        "source_clean": True,
        "source_state": "detached-clean",
        "build_argv": [
            "bash",
            "scripts/package_insightkit_app.sh",
            "--clean",
            "--output-dir",
            "$EVIDENCE_ROOT",
        ],
        "signing_team_id": OWNER_PILOT_SIGNING_TEAM_ID,
        "signing_leaf_certificate_sha256": OWNER_PILOT_SIGNING_CERT_SHA256,
        "provenance_level": "developer-attested-source-provenance-non-reproducible",
    }
    toolchain = (
        predicate.get("swift_version"),
        predicate.get("xcode_version"),
        predicate.get("sdk_version"),
    )
    if (
        statement.get("schema_version") != 1
        or statement.get("predicate_type")
        != "insightkit.local-owner-pilot.developer-attestation/v1"
        or subject != expected_subject
        or any(predicate.get(key) != value for key, value in expected_predicate.items())
        or not all(isinstance(value, str) and 1 <= len(value) <= 256 for value in toolchain)
    ):
        _fail("source attestation does not bind the frozen app")


def _validate_attempts(attempts: Any) -> tuple[dict[str, int], bool]:
    if not isinstance(attempts, list) or [
        item.get("id") for item in attempts if isinstance(item, dict)
    ] != list(ATTEMPT_ORDER):
        _fail("attempt matrix must contain the exact serialized paths")
    counts = {classification: 0 for classification in CLASSIFICATIONS}
    all_passed = True
    for attempt, attempt_id in zip(attempts, ATTEMPT_ORDER, strict=True):
        _exact_keys(
            attempt,
            {
                "id",
                "workflow",
                "analysis_mode",
                "classification",
                "result",
                "stages",
                "evidence_refs",
                "unknowns",
            },
            "attempt",
        )
        workflow, mode = attempt_id.split("-")
        if attempt["workflow"] != workflow or attempt["analysis_mode"] != mode:
            _fail("attempt workflow segmentation is invalid")
        classification = attempt["classification"]
        if classification not in CLASSIFICATIONS:
            _fail("attempt classification is invalid")
        counts[classification] += 1
        stages = attempt["stages"]
        if (
            not isinstance(stages, dict)
            or set(stages) != set(STAGES)
            or not set(stages.values()) <= STAGE_RESULTS
        ):
            _fail("attempt stages are incomplete")
        refs, unknowns = attempt["evidence_refs"], attempt["unknowns"]
        if not isinstance(refs, list) or not all(_repo_ref(ref) for ref in refs):
            _fail("attempt evidence references are invalid")
        if not isinstance(unknowns, list) or not all(
            isinstance(code, str) and CODE.fullmatch(code) for code in unknowns
        ):
            _fail("attempt unknowns must be bounded metadata codes")
        if classification == "observed" and (
            not refs or "observed" not in stages.values()
        ):
            _fail("observed attempt requires observed stages and evidence")
        if classification == "inference" and (not refs or not unknowns):
            _fail("attempt inference requires evidence and a bounded basis")
        if classification == "unobserved" and (
            not unknowns or "observed" in stages.values()
        ):
            _fail("unobserved attempt must retain an explicit unknown")
        if attempt["result"] not in {"passed", "failed", "blocked"}:
            _fail("attempt result is invalid")
        if attempt["result"] == "passed" and (
            classification != "observed"
            or unknowns
            or not all(value == "observed" for value in stages.values())
        ):
            _fail("passed attempt requires every stage to be observed")
        all_passed &= attempt["result"] == "passed"
    return counts, all_passed


def _validate_reconciliation(reconciliation: Any, config: dict[str, Any]) -> bool:
    reconciliation = _require_keys(
        reconciliation,
        {"posthog", "sentry", "langfuse", "repository"},
        "reconciliation",
    )
    _exact_keys(
        reconciliation,
        {"posthog", "sentry", "langfuse", "repository"},
        "reconciliation",
    )
    schemas = {
        "posthog": {
            "classification",
            "evidence_ref",
            "scope",
            "project_id",
            "state",
            "local_event_counts",
            "remote_event_counts",
            "schema_version",
            "environment",
            "window_start",
            "window_end",
        },
        "sentry": {
            "classification",
            "evidence_ref",
            "scope",
            "project_id",
            "issue_id",
            "event_id",
            "environment",
            "release",
            "build",
        },
        "langfuse": {
            "classification",
            "evidence_ref",
            "scope",
            "project_id",
            "dataset_id",
            "dataset_name",
            "dataset_sha256",
            "experiment_id",
            "experiment_name",
            "item_count",
            "score_count",
            "score_names",
            "score_environment",
            "observation_environment",
        },
        "repository": {
            "classification",
            "evidence_ref",
            "scope",
            "status",
            "checks",
            "harness_commit",
            "harness_manifest_ref",
            "harness_manifest_sha256",
        },
    }
    for provider, item in reconciliation.items():
        if (
            not isinstance(item, dict)
            or item.get("classification") not in CLASSIFICATIONS
        ):
            _fail("reconciliation classification is invalid")
        if item["classification"] == "unobserved":
            _exact_keys(
                item,
                {"classification", "evidence_ref", "unknowns"}
                | ({"state"} if provider == "posthog" else set()),
                f"{provider} reconciliation",
            )
            if (
                item["evidence_ref"] is not None
                or not item["unknowns"]
                or not all(
                    isinstance(code, str) and CODE.fullmatch(code)
                    for code in item["unknowns"]
                )
            ):
                _fail(f"{provider} unobserved result requires bounded unknowns")
            continue
        _exact_keys(
            item,
            schemas[provider]
            | ({"unknowns"} if item["classification"] == "inference" else set()),
            f"{provider} reconciliation",
        )
        if not _repo_ref(item["evidence_ref"]):
            _fail(f"{provider} result requires repository readback evidence")
        if item["classification"] == "inference":
            if not item["unknowns"] or not all(
                isinstance(code, str) and CODE.fullmatch(code)
                for code in item["unknowns"]
            ):
                _fail(f"{provider} inference requires a bounded basis")
            continue
        if provider == "posthog":
            local, remote = item["local_event_counts"], item["remote_event_counts"]
            if (
                item["scope"] not in {"prerequisite-synthetic", "pilot-attempt"}
                or item["project_id"] != "585182"
                or item["state"] != "complete"
            ):
                _fail("PostHog readback identity is invalid")
            if (
                not isinstance(local, dict)
                or not local
                or local != remote
                or sum(local.values()) <= 0
                or not set(local) <= PRODUCT_ANALYTICS_EVENTS
                or any(type(value) is not int or value < 0 for value in local.values())
            ):
                _fail("PostHog non-empty counts do not reconcile")
            if (
                item["schema_version"] != config["event_schema_version"]
                or item["environment"] != "owner-pilot"
            ):
                _fail("PostHog readback contract changed")
            if item["scope"] == "pilot-attempt":
                _fail("PostHog pilot-attempt requires segmented lifecycle evidence")
            if _timestamp(item["window_end"]) <= _timestamp(item["window_start"]):
                _fail("PostHog readback window is invalid")
        elif provider == "sentry":
            if (
                item["scope"] not in {"prerequisite-synthetic", "pilot-attempt"}
                or item["project_id"] != "4512002926247936"
                or item["issue_id"] != "7703629009"
                or not re.fullmatch(r"[0-9a-f]{32}", item["event_id"])
                or item["environment"] != "release"
                or not item["release"].endswith("+" + item["build"])
            ):
                _fail("Sentry readback identity is invalid")
        elif provider == "langfuse":
            expected = {
                "project_id": "cmtfr0jg10323ad0fqe9x8h27",
                "dataset_id": "cmtgiyr9p04suad0jyd9h7w1w",
                "dataset_name": "insightkit-smart-minutes-v1-metadata",
                "dataset_sha256": "3afe544b693e4a03a814f1b3f746b6d3f04c9229d3fa0e822c6b47e5716ca3b1",
                "experiment_id": "a57c3105-e1da-4eaf-9c96-5c9798bf6f38",
                "experiment_name": "smart-minutes-v1-20260831T005732440827Z",
                "item_count": 4,
                "score_count": 9,
                "score_names": [
                    "failure_behavior",
                    "latency",
                    "source_evidence_linkage",
                ],
                "score_environment": "owner-pilot",
                "observation_environment": "sdk-experiment",
            }
            if item["scope"] not in {"prerequisite-synthetic", "pilot-attempt"} or any(
                item[key] != value for key, value in expected.items()
            ):
                _fail("Langfuse readback identity or environment distinction changed")
        elif (
            item["scope"] != "repository-proof"
            or item["status"] not in {"passed", "failed"}
            or item["checks"] != ["full-agent-harness"]
            or not isinstance(item["harness_commit"], str)
            or not SHA.fullmatch(item["harness_commit"])
            or not _repo_ref(item["harness_manifest_ref"])
            or not SHA256.fullmatch(item["harness_manifest_sha256"])
        ):
            _fail("repository readback is invalid")
    return all(
        reconciliation[name]["classification"] == "observed"
        and reconciliation[name]["scope"] == "pilot-attempt"
        for name in ("posthog", "sentry", "langfuse")
    )


def _validate_provider_evidence(
    provider: str,
    item: dict[str, Any],
    evidence: Any,
    root: Path,
    pilot_window: tuple[datetime, datetime],
    base_commit: str,
    build_version: str,
) -> None:
    expected_status = item["status"] if provider == "repository" else "passed"
    if (
        not isinstance(evidence, dict)
        or evidence.get("status") != expected_status
        or evidence.get("privacy_safe") is not True
    ):
        _fail(f"{provider} evidence is not an accepted readback")
    observed_at = (
        _timestamp(evidence.get("observed_at")) if provider != "repository" else None
    )
    if (
        provider != "repository"
        and item["scope"] == "pilot-attempt"
        and not (pilot_window[0] <= observed_at <= pilot_window[1])
    ):
        label = {"posthog": "PostHog", "sentry": "Sentry", "langfuse": "Langfuse"}[provider]
        _fail(f"{label} evidence metadata is outside the pilot window")
    if provider == "posthog":
        expected = {
            "scope": item["scope"],
            "project_id": item["project_id"],
            "region": "us-cloud",
            "environment": item["environment"],
            "schema_version": item["schema_version"],
            "window_start": item["window_start"],
            "window_end": item["window_end"],
            "event_counts": item["remote_event_counts"],
            "readback": f"activity.showing-all-{sum(item['remote_event_counts'].values())}",
            "source_issue": "GH-73" if item["scope"] == "pilot-attempt" else "GH-72",
        }
        if any(
            evidence.get(key) != value for key, value in expected.items()
        ) or evidence.get("event_count") != sum(item["remote_event_counts"].values()):
            _fail("PostHog evidence does not match the reconciled readback")
        if item["scope"] == "pilot-attempt" and (
            evidence.get("source_issue") != "GH-73"
            or _timestamp(item["window_start"]) < pilot_window[0]
            or _timestamp(item["window_end"]) > pilot_window[1]
        ):
            _fail("PostHog pilot-attempt readback is outside the pilot window")
    elif provider == "sentry":
        expected = {
            "scope": item["scope"],
            "project_id": item["project_id"],
            "issue_id": item["issue_id"],
            "event_id": item["event_id"],
            "environment": item["environment"],
            "release": item["release"],
            "platform": "native",
        }
        classification = {
            "workflow": "live",
            "phase": "running",
            "engine_class": "local",
            "provider_class": "none",
            "recovery_result": "succeeded",
        }
        if (
            any(evidence.get(key) != value for key, value in expected.items())
            or evidence.get("classification") != classification
        ):
            _fail("Sentry evidence does not match the reconciled readback")
        if item["scope"] == "pilot-attempt" and not (
            pilot_window[0]
            <= _timestamp(evidence.get("event_created_at"))
            <= pilot_window[1]
        ):
            _fail("Sentry pilot-attempt readback is outside the pilot window")
        if item["scope"] == "pilot-attempt" and item["build"] != build_version:
            _fail("Sentry pilot-attempt readback does not match the frozen build")
        if item["scope"] == "pilot-attempt":
            _fail("Sentry pilot-attempt requires pilot-specific immutable event evidence")
    elif provider == "langfuse":
        expected = {
            "scope": item["scope"],
            "project_id": item["project_id"],
            "dataset_id": item["dataset_id"],
            "dataset_name": item["dataset_name"],
            "dataset_sha256": item["dataset_sha256"],
            "dataset_item_count": item["item_count"],
            "experiment_id": item["experiment_id"],
            "experiment_name": item["experiment_name"],
            "experiment_item_count": item["item_count"],
            "score_count": item["score_count"],
            "score_names": item["score_names"],
            "score_environment": item["score_environment"],
            "observation_environment": item["observation_environment"],
        }
        if any(evidence.get(key) != value for key, value in expected.items()):
            _fail("Langfuse evidence does not match the reconciled readback")
        if item["scope"] == "pilot-attempt":
            _fail("Langfuse pilot-attempt readback requires a pilot-specific experiment")
    else:
        expected = {
            "scope": item["scope"],
            "status": item["status"],
            "checks": item["checks"],
            "commit": item["harness_commit"],
            "harness_manifest_ref": item["harness_manifest_ref"],
            "harness_manifest_sha256": item["harness_manifest_sha256"],
        }
        if any(evidence.get(key) != value for key, value in expected.items()):
            _fail("repository evidence does not match the reconciled readback")
        harness_path = (root / item["harness_manifest_ref"]).resolve()
        harness = (
            _load_json(harness_path)
            if harness_path.is_relative_to(root) and harness_path.is_file()
            else None
        )
        if not isinstance(harness, dict):
            _fail("repository Harness evidence is invalid")
        gates = harness.get("gates") if isinstance(harness, dict) else None
        if isinstance(harness, dict):
            _walk(harness)
            _exact_keys(
                harness,
                {
                    "base",
                    "branch",
                    "changed_files",
                    "commit",
                    "finished_at",
                    "gates",
                    "generated_at",
                    "issue",
                    "schema_version",
                    "status",
                    "workspace",
                },
                "repository Harness",
            )
        if isinstance(gates, list):
            for gate in gates:
                if isinstance(gate, dict):
                    _exact_keys(gate, {"commands", "name", "status"}, "Harness gate")
                    for command in gate.get("commands", []):
                        if not isinstance(command, dict):
                            _fail("Harness command fields do not match the schema")
                        _exact_keys(
                            command,
                            {"command", "duration_seconds", "exit_code", "ok"},
                            "Harness command",
                        )
        changed_files = harness.get("changed_files") if isinstance(harness, dict) else None
        harness_commit = harness.get("commit") if isinstance(harness, dict) else None
        changed_files_valid = (
            isinstance(changed_files, list)
            and all(isinstance(path, str) for path in changed_files)
            and changed_files == sorted(set(changed_files))
            and harness.get("base") == "origin/main"
            and isinstance(harness_commit, str)
            and _git_is_ancestor(root, harness_commit)
            and set(_git_diff_files(root, harness_commit, "HEAD"))
            <= POST_HARNESS_EVIDENCE_REFS
            and changed_files == _git_diff_files(root, base_commit, _git_head(root))
        )
        specs = harness_gate_specs(
            changed_files if changed_files_valid else [],
            mode="full",
            python_executable="$WORKSPACE/.venv/bin/python",
        )
        expected_gate_names = [spec.name for spec in specs]
        actual_gate_states = [
            (gate.get("name"), gate.get("status"))
            for gate in gates
            if isinstance(gate, dict)
        ] if isinstance(gates, list) else []
        if len(actual_gate_states) > len(expected_gate_names):
            _fail("repository Harness evidence is invalid")
        expected_gate_states = (
            [(name, "passed") for name in expected_gate_names]
            if item["status"] == "passed"
            else (
                [
                    *[
                        (name, "passed")
                        for name in expected_gate_names[: len(actual_gate_states) - 1]
                    ],
                    (expected_gate_names[len(actual_gate_states) - 1], "failed"),
                ]
                if actual_gate_states
                else []
            )
        )
        expected_commands = {
            spec.name: [
                list(command)
                for command in (
                    spec.commands
                    + (
                        (("git", "diff", "--check", f"{harness['base']}...HEAD"),)
                        if spec.name == "diff-check"
                        else ()
                    )
                )
            ]
            for spec in specs
        }
        output_root = re.compile(r"^\$WORKSPACE/logs/harness/\d{8}-\d{6}")
        actual_commands = {
            gate["name"]: [
                [output_root.sub("{output_root}", part) for part in command["command"]]
                for command in gate["commands"]
            ]
            for gate in gates
            if isinstance(gate, dict)
            and isinstance(gate.get("commands"), list)
            and all(
                isinstance(command, dict) and isinstance(command.get("command"), list)
                and all(isinstance(part, str) for part in command["command"])
                for command in gate["commands"]
            )
        } if isinstance(gates, list) else {}
        if item["status"] == "passed":
            commands_match = all(
                actual_commands.get(name) == commands
                for name, commands in expected_commands.items()
            )
        else:
            failed_name = actual_gate_states[-1][0] if actual_gate_states else None
            failed_commands = actual_commands.get(failed_name, [])
            expected_failed_commands = expected_commands.get(failed_name)
            commands_match = (
                all(
                    actual_commands.get(name) == commands
                    for name, commands in list(expected_commands.items())[
                        : len(actual_gate_states) - 1
                    ]
                )
                and bool(failed_commands)
                and expected_failed_commands is not None
                and failed_commands
                == expected_failed_commands[: len(failed_commands)]
            )
        command_states_valid = isinstance(gates, list) and all(
            isinstance(gate, dict)
            and isinstance(gate.get("commands"), list)
            and bool(gate["commands"])
            and gate.get("status")
            == (
                "passed"
                if all(
                    command.get("exit_code") == 0 and command.get("ok") is True
                    for command in gate["commands"]
                    if isinstance(command, dict)
                )
                else "failed"
            )
            for gate in gates
        )
        if (
            not isinstance(harness, dict)
            or _artifact_sha(harness_path) != item["harness_manifest_sha256"]
            or harness.get("status") != item["status"]
            or harness.get("issue") != 73
            or harness.get("commit") != item["harness_commit"]
            or harness.get("workspace") != "$WORKSPACE"
            or not changed_files_valid
            or not isinstance(gates, list)
            or not all(
                isinstance(gate, dict) and isinstance(gate.get("commands"), list)
                for gate in gates
            )
            or actual_gate_states != expected_gate_states
            or not commands_match
            or not command_states_valid
        ):
            _fail("repository Harness evidence is invalid")


def _validate_attempt_evidence(
    attempt: dict[str, Any],
    evidence: dict[str, Any],
    *,
    root: Path,
    build_proof: dict[str, Any],
    pilot_window: tuple[datetime, datetime],
) -> None:
    unknowns = evidence.get("unknowns")
    if (
        evidence.get("status") != attempt["result"]
        or evidence.get("evidence_kind")
        != {"observed": "attempt", "inference": "inference"}[attempt["classification"]]
        or evidence.get("privacy_safe") is not True
        or evidence.get("analysis_mode") != attempt["analysis_mode"]
        or not isinstance(evidence.get("analysis_mode_observed"), bool)
        or (
            attempt["result"] == "passed"
            and evidence.get("analysis_mode_observed") is not True
        )
        or evidence.get("stages") != attempt["stages"]
        or (
            attempt["result"] == "passed"
            and evidence.get("scenario") == "synthetic-ui-route"
        )
        or not isinstance(unknowns, list)
        or not all(isinstance(code, str) and CODE.fullmatch(code) for code in unknowns)
        or not set(unknowns).issubset(attempt["unknowns"])
    ):
        _fail("attempt evidence does not match the claimed result and stages")
    host_attempts = evidence.get("host_attempts")
    if (
        evidence.get("scenario") != "synthetic-ui-route"
        or not isinstance(host_attempts, list)
        or not 1 <= len(host_attempts) <= 8
        or len(host_attempts) != len(set(host_attempts))
        or not all(isinstance(code, str) and CODE.fullmatch(code) for code in host_attempts)
        or not (
            pilot_window[0]
            <= _timestamp(evidence.get("observed_at"))
            <= pilot_window[1]
        )
    ):
        _fail("attempt metadata is outside the bounded pilot schema")
    app = evidence.get("app")
    visual = evidence.get("visual")
    if not isinstance(app, dict) or not isinstance(visual, dict):
        _fail("attempt attachment identity is invalid")
    _exact_keys(
        app,
        {
            "build",
            "bundle_sha256",
            "source",
            "cdhash",
            "attestation_sha256",
            "signer_policy",
        },
        "attempt app",
    )
    _exact_keys(
        visual,
        {"artifact_ref", "artifact_sha256", "fixture"},
        "attempt visual",
    )
    artifact_ref = visual.get("artifact_ref")
    artifact = (root / artifact_ref).resolve() if _repo_ref(artifact_ref) else None
    if (
        app.get("build") != build_proof["build_version"]
        or app.get("bundle_sha256") != build_proof["app_bundle_sha256"]
        or app.get("source") != build_proof["build_source"]
        or app.get("cdhash") != build_proof["bundle_cdhash"]
        or app.get("attestation_sha256")
        != build_proof["source_attestation_sha256"]
        or app.get("signer_policy") != OWNER_PILOT_SIGNER_POLICY
        or visual.get("fixture") != "synthetic"
        or artifact is None
        or not artifact.is_relative_to(root)
        or not artifact.is_file()
        or _artifact_sha(artifact) != visual.get("artifact_sha256")
    ):
        _fail("attempt attachment is missing or unrelated to the frozen build")


def validate_rollback_proof(
    proof: Any,
    *,
    rollback: dict[str, Any],
    app_bundle_ref: str,
    app_sha: str,
    source_sha: str | None = None,
    evidence_sha: str | None = None,
) -> None:
    if not isinstance(proof, dict):
        _fail("rollback proof is invalid")
    expected = {
        "consent_disabled": rollback["consent_disabled"],
        "queues_purged": rollback["queues_purged"],
        "evidence_preserved": rollback["evidence_preserved"],
        "app_target_verified": rollback["app_target_verified"],
        "rollback_target": app_bundle_ref,
        "rollback_target_sha256": app_sha,
        "checks": list(ROLLBACK_CHECKS),
    }
    if any(proof.get(key) != value for key, value in expected.items()):
        _fail("rollback proof does not bind every invariant and target")
    if proof.get("evidence_sha256_before") != proof.get("evidence_sha256_after"):
        _fail("rollback proof did not preserve evidence")
    if source_sha is not None and proof.get("test_source_sha256") != source_sha:
        _fail("rollback proof test source changed")
    if evidence_sha is not None and proof.get("evidence_sha256_before") != evidence_sha:
        _fail("rollback proof evidence input changed")


def _validated_attempt_evidence_refs(manifest: dict[str, Any]) -> set[str]:
    return {
        ref
        for attempt in manifest.get("attempts", [])
        if isinstance(attempt, dict)
        and attempt.get("classification") in {"observed", "inference"}
        for ref in attempt.get("evidence_refs", [])
        if _repo_ref(ref)
    }


@_validation_boundary
def generate_rollback_proof(
    manifest: dict[str, Any], *, repository_root: Path, native_proof_ref: str
) -> dict[str, Any]:
    build = manifest.get("build") if isinstance(manifest, dict) else None
    verify_manifest(
        manifest,
        expected_commit=build.get("commit") if isinstance(build, dict) else "",
    )
    build = manifest["build"]
    app_path, native_path = (
        repository_root / build["app_bundle_ref"],
        repository_root / native_proof_ref,
    )
    if native_proof_ref not in _validated_attempt_evidence_refs(manifest):
        _fail("rollback input is not validated attempt evidence")
    if not app_path.is_dir() or not native_path.is_file():
        _fail("rollback prerequisite evidence is missing")
    build_proof = _load_json(repository_root / build["proof_ref"])
    app_sha = _artifact_sha(app_path)
    if (
        not isinstance(build_proof, dict)
        or build_proof.get("app_bundle_sha256") != app_sha
    ):
        _fail("rollback target does not match the frozen build proof")
    attempt = next(
        item
        for item in manifest["attempts"]
        if item["classification"] in {"observed", "inference"}
        and native_proof_ref in item["evidence_refs"]
    )
    native_proof = _load_json(native_path)
    if isinstance(native_proof, dict):
        _walk(native_proof)
        _exact_keys(native_proof, ATTEMPT_EVIDENCE_FIELDS, "attempt evidence")
    if (
        not isinstance(native_proof, dict)
        or native_proof.get("issue") != "GH-73"
        or native_proof.get("commit") != build["commit"]
        or native_proof.get("pilot_id") != manifest["pilot_id"]
        or native_proof.get("evidence_kind")
        != {"observed": "attempt", "inference": "inference"}[
            attempt["classification"]
        ]
        or native_proof.get("subject") != attempt["id"]
    ):
        _fail("rollback input is unrelated to this pilot")
    _validate_attempt_evidence(
        attempt,
        native_proof,
        root=repository_root.resolve(),
        build_proof=build_proof,
        pilot_window=(
            _timestamp(manifest["window"]["started_at"]),
            _timestamp(manifest["window"]["ends_at"]),
        ),
    )
    evidence_sha = _artifact_sha(native_path)
    _run_frozen_rollback_checks(repository_root, build["commit"])
    if _artifact_sha(native_path) != evidence_sha:
        _fail("rollback checks changed retained evidence")
    return {
        "status": "passed",
        "issue": "GH-73",
        "commit": build["commit"],
        "pilot_id": manifest["pilot_id"],
        "evidence_kind": "rollback",
        "subject": "dry-run",
        "observed_at": datetime.now(UTC)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
        "consent_disabled": True,
        "queues_purged": True,
        "app_target_verified": True,
        "evidence_preserved": True,
        "rollback_target": build["app_bundle_ref"],
        "rollback_target_sha256": app_sha,
        "checks": list(ROLLBACK_CHECKS),
        "native_proof_ref": native_proof_ref,
        "test_source_sha256": _source_sha(repository_root, build["commit"]),
        "evidence_sha256_before": evidence_sha,
        "evidence_sha256_after": evidence_sha,
    }


@_validation_boundary
def verify_manifest(
    manifest: dict[str, Any],
    *,
    expected_commit: str,
    repository_root: Path | None = None,
    now: str | None = None,
    verify_app_artifact: bool = False,
) -> dict[str, Any]:
    if not isinstance(manifest, dict):
        _fail("manifest must be an object")
    _walk(manifest)
    _exact_keys(
        manifest,
        {
            "schema_version",
            "pilot_id",
            "issue",
            "environment",
            "build",
            "window",
            "cohort",
            "configuration",
            "attempts",
            "reconciliation",
            "rollback",
            "claims",
            "deviations",
            "evidence_ledger_ref",
        },
        "manifest",
    )
    if (
        manifest["schema_version"] != 1
        or manifest["pilot_id"] != "gh-73-owner-three-day-v1"
        or manifest["issue"] != "GH-73"
        or manifest["environment"] != "owner-pilot"
    ):
        _fail("manifest identity is invalid")
    build = _require_keys(
        manifest["build"], {"commit", "app_bundle_ref", "proof_ref"}, "build freeze"
    )
    _exact_keys(build, {"commit", "app_bundle_ref", "proof_ref"}, "build freeze")
    if (
        not isinstance(build["commit"], str)
        or not SHA.fullmatch(build["commit"])
        or build["commit"] != expected_commit
        or not _repo_ref(build["app_bundle_ref"])
        or not _repo_ref(build["proof_ref"])
    ):
        _fail("build freeze does not match the exact source commit")
    window = _require_keys(
        manifest["window"], {"started_at", "ends_at"}, "pilot window"
    )
    _exact_keys(window, {"started_at", "ends_at"}, "pilot window")
    started, ended = _timestamp(window["started_at"]), _timestamp(window["ends_at"])
    if (
        ended <= started
        or (ended - started).total_seconds() > 3 * 86400
        or ended > (_timestamp(now) if now else datetime.now(UTC))
    ):
        _fail("pilot window is invalid or has not ended")
    if manifest["cohort"] != {"kind": "owner", "size": 1, "reference_mac": True}:
        _fail("cohort must be one owner on the reference Mac")
    config = _require_keys(
        manifest["configuration"],
        {
            "event_schema_version",
            "smart_minutes_dataset",
            "consent_default",
            "attempt_order",
            "quality_thresholds",
            "consent_plan",
            "rollout_steps",
            "rollback_trigger",
            "human_gates",
            "sql_refs",
        },
        "configuration freeze",
    )
    _exact_keys(
        config,
        {
            "event_schema_version",
            "smart_minutes_dataset",
            "consent_default",
            "attempt_order",
            "quality_thresholds",
            "consent_plan",
            "rollout_steps",
            "rollback_trigger",
            "human_gates",
            "sql_refs",
        },
        "configuration freeze",
    )
    if (
        config["event_schema_version"] != 1
        or config["smart_minutes_dataset"] != "smart-minutes-v1"
        or config["consent_default"] != "off"
        or tuple(config["attempt_order"]) != ATTEMPT_ORDER
        or config["quality_thresholds"] != []
        or config["consent_plan"] != "explicit-enable-then-disable"
        or config["human_gates"] != []
        or config["rollout_steps"]
        != ["exact-build", "serialized-attempts", "reconcile", "rollback"]
        or not isinstance(config["rollback_trigger"], str)
        or not CODE.fullmatch(config["rollback_trigger"])
        or not isinstance(config["sql_refs"], list)
        or not config["sql_refs"]
        or not all(_repo_ref(ref) for ref in config["sql_refs"])
    ):
        _fail("accepted configuration freeze changed")
    counts, all_attempts_passed = _validate_attempts(manifest["attempts"])
    providers_observed = _validate_reconciliation(manifest["reconciliation"], config)
    rollback = _require_keys(
        manifest["rollback"],
        {
            "kind",
            "classification",
            "consent_disabled",
            "queues_purged",
            "app_target_verified",
            "evidence_preserved",
            "evidence_refs",
        },
        "rollback",
    )
    _exact_keys(
        rollback,
        {
            "kind",
            "classification",
            "consent_disabled",
            "queues_purged",
            "app_target_verified",
            "evidence_preserved",
            "evidence_refs",
        },
        "rollback",
    )
    if (
        rollback["kind"] != "dry-run"
        or rollback["classification"] != "observed"
        or not all(
            rollback[key] is True
            for key in (
                "consent_disabled",
                "queues_purged",
                "app_target_verified",
                "evidence_preserved",
            )
        )
        or not rollback["evidence_refs"]
        or not all(_repo_ref(ref) for ref in rollback["evidence_refs"])
    ):
        _fail("rollback invariants are not proven")
    claims = _require_keys(
        manifest["claims"], {"observed", "inferred", "unobserved"}, "claims"
    )
    _exact_keys(claims, {"observed", "inferred", "unobserved"}, "claims")
    if not all(
        isinstance(values, list)
        and all(isinstance(code, str) and CODE.fullmatch(code) for code in values)
        for values in claims.values()
    ):
        _fail("claims must contain bounded metadata codes")
    claim_bucket = {"observed": "observed", "inference": "inferred", "unobserved": "unobserved"}
    expected_claims = {
        "observed": {"rollback.dry-run"},
        "inferred": set(),
        "unobserved": {"production-readiness", "external-user-validation"},
    }
    for attempt in manifest["attempts"]:
        expected_claims[claim_bucket[attempt["classification"]]].add(
            f"attempt.{attempt['id']}"
        )
    for name, item in manifest["reconciliation"].items():
        expected_claims[claim_bucket[item["classification"]]].add(
            f"reconciliation.{name}"
        )
    actual_claims = {name: set(values) for name, values in claims.items()}
    if (
        any(len(actual_claims[name]) != len(claims[name]) for name in claims)
        or actual_claims != expected_claims
    ):
        _fail("claim classifications must exactly match their evidence")
    if (
        not isinstance(manifest["deviations"], list)
        or not all(
            isinstance(code, str) and CODE.fullmatch(code)
            for code in manifest["deviations"]
        )
        or not _repo_ref(manifest["evidence_ledger_ref"])
    ):
        _fail("deviations or evidence ledger reference is invalid")
    outcome = (
        "completed"
        if (
            all_attempts_passed
            and providers_observed
            and manifest["reconciliation"]["repository"]["classification"] == "observed"
            and manifest["reconciliation"]["repository"]["status"] == "passed"
            and repository_root is not None
        )
        else ("partial" if counts["observed"] else "blocked")
    )

    if repository_root is not None:
        root = repository_root.resolve()
        refs = [
            build["proof_ref"],
            manifest["evidence_ledger_ref"],
            *config["sql_refs"],
        ]
        refs += [
            ref for attempt in manifest["attempts"] for ref in attempt["evidence_refs"]
        ]
        refs += [
            item["evidence_ref"]
            for item in manifest["reconciliation"].values()
            if item.get("evidence_ref")
        ]
        refs += rollback["evidence_refs"]
        for ref in refs:
            path = (root / ref).resolve()
            if not path.is_relative_to(root) or not path.exists():
                _fail("referenced evidence does not exist inside the repository")
            if path.is_file() and path.suffix == ".json":
                try:
                    _walk(_load_json(path))
                except (OSError, json.JSONDecodeError):
                    _fail("referenced JSON evidence is unreadable")
        build_proof = _load_json(root / build["proof_ref"])
        if isinstance(build_proof, dict):
            _exact_keys(build_proof, BUILD_PROOF_FIELDS, "build proof")
        if (
            not isinstance(build_proof, dict)
            or build_proof.get("status") != "passed"
            or build_proof.get("commit") != build["commit"]
            or build_proof.get("app_bundle_ref") != build["app_bundle_ref"]
            or build_proof.get("source_clean") is not True
            or build_proof.get("build_source") != "local-workspace-clean"
            or build_proof.get("git_revision_short") != build["commit"][:7]
            or build_proof.get("distribution") != "local"
            or build_proof.get("signing") != "apple-development"
            or build_proof.get("verification")
            != [
                "codesign.deep-strict",
                "info-plist.source-binding",
                "bundle-content-sha256",
                "developer-source-attestation.cms",
            ]
            or not _repo_ref(build_proof.get("app_archive_ref"))
            or not _repo_ref(build_proof.get("source_attestation_ref"))
            or not _repo_ref(build_proof.get("source_attestation_signature_ref"))
            or not SHA256.fullmatch(str(build_proof.get("app_bundle_sha256", "")))
            or not SHA256.fullmatch(str(build_proof.get("app_archive_sha256", "")))
            or not SHA256.fullmatch(str(build_proof.get("package_script_sha256", "")))
            or not re.fullmatch(r"[0-9a-f]{40}", str(build_proof.get("bundle_cdhash", "")))
            or not SHA256.fullmatch(str(build_proof.get("executable_sha256", "")))
            or not SHA256.fullmatch(
                str(build_proof.get("source_attestation_sha256", ""))
            )
            or not SHA256.fullmatch(
                str(build_proof.get("source_attestation_signature_sha256", ""))
            )
            or build_proof.get("signing_team_id")
            != OWNER_PILOT_SIGNING_TEAM_ID
            or build_proof.get("signing_leaf_certificate_sha256")
            != OWNER_PILOT_SIGNING_CERT_SHA256
        ):
            _fail("build proof is not bound to the frozen source")
        app_sha = build_proof["app_bundle_sha256"]
        package_sha = hashlib.sha256(
            _git_blob(root, build["commit"], "scripts/package_insightkit_app.sh")
        ).hexdigest()
        if package_sha != build_proof["package_script_sha256"]:
            _fail("package script does not match the frozen source commit")
        archive_path = (root / build_proof["app_archive_ref"]).resolve()
        if (
            not archive_path.is_relative_to(root)
            or not archive_path.is_file()
            or _artifact_sha(archive_path) != build_proof["app_archive_sha256"]
        ):
            _fail("frozen app archive hash does not match build proof")
        archive_app_sha, app_info = _archive_bundle_sha(archive_path)
        if (
            archive_app_sha != app_sha
            or app_info.get("CFBundleVersion") != build_proof["build_version"]
            or app_info.get("InsightKitGitRevision") != build["commit"][:7]
            or app_info.get("InsightKitBuildSource") != build_proof["build_source"]
        ):
            _fail("frozen app archive does not match the exact build identity")
        signature = _verify_archive_signature(archive_path)
        if (
            build_proof["bundle_cdhash"] != signature["cdhash"]
            or build_proof["executable_sha256"] != signature["executable_sha256"]
            or build_proof["signing_team_id"] != signature["team_id"]
            or build_proof["signing_leaf_certificate_sha256"]
            != signature["leaf_certificate_sha256"]
        ):
            _fail("build proof signer identity changed")
        _verify_source_attestation(
            root,
            build,
            build_proof,
            app_sha=app_sha,
            signature=signature,
        )
        for ref in config["sql_refs"]:
            if (root / ref).read_bytes() != _git_blob(root, build["commit"], ref):
                _fail("reconciliation SQL changed after the frozen commit")
        if verify_app_artifact:
            app_path = root / build["app_bundle_ref"]
            if not app_path.is_dir() or _artifact_sha(app_path) != app_sha:
                _fail("frozen app artifact hash does not match build proof")
            if _developer_signature_metadata(app_path) != signature:
                _fail("frozen app artifact signer identity changed")
        for attempt in manifest["attempts"]:
            for ref in (
                attempt["evidence_refs"]
                if attempt["classification"] in {"observed", "inference"}
                else []
            ):
                evidence = _load_json(root / ref)
                if isinstance(evidence, dict):
                    _exact_keys(evidence, ATTEMPT_EVIDENCE_FIELDS, "attempt evidence")
                if (
                    not isinstance(evidence, dict)
                    or evidence.get("issue") != "GH-73"
                    or evidence.get("commit") != build["commit"]
                    or evidence.get("pilot_id") != manifest["pilot_id"]
                    or evidence.get("evidence_kind") not in {"attempt", "inference"}
                    or evidence.get("subject") != attempt["id"]
                ):
                    _fail("attempt evidence is unrelated to this pilot")
                _validate_attempt_evidence(
                    attempt,
                    evidence,
                    root=root,
                    build_proof=build_proof,
                    pilot_window=(started, ended),
                )
        for provider, item in manifest["reconciliation"].items():
            if item["classification"] in {"observed", "inference"}:
                evidence = _load_json(root / item["evidence_ref"])
                if isinstance(evidence, dict):
                    _exact_keys(
                        evidence,
                        RECONCILIATION_EVIDENCE_FIELDS[provider],
                        f"{provider} evidence",
                    )
                if (
                    not isinstance(evidence, dict)
                    or evidence.get("issue") != "GH-73"
                    or evidence.get("commit")
                    != (
                        item["harness_commit"]
                        if provider == "repository"
                        else build["commit"]
                    )
                    or evidence.get("pilot_id") != manifest["pilot_id"]
                    or evidence.get("evidence_kind")
                    != (
                        "reconciliation"
                        if item["classification"] == "observed"
                        else "inference"
                    )
                    or evidence.get("subject") != provider
                ):
                    _fail("provider evidence is unrelated to this pilot")
                _validate_provider_evidence(
                    provider,
                    item,
                    evidence,
                    root,
                    pilot_window=(started, ended),
                    base_commit=build["commit"],
                    build_version=build_proof["build_version"],
                )
        source_sha = _source_sha(root, build["commit"])
        for ref in rollback["evidence_refs"]:
            evidence = _load_json(root / ref)
            if isinstance(evidence, dict):
                _exact_keys(evidence, ROLLBACK_EVIDENCE_FIELDS, "rollback evidence")
            if (
                not isinstance(evidence, dict)
                or evidence.get("status") != "passed"
                or evidence.get("issue") != "GH-73"
                or evidence.get("commit") != build["commit"]
                or evidence.get("pilot_id") != manifest["pilot_id"]
                or evidence.get("evidence_kind") != "rollback"
                or evidence.get("subject") != "dry-run"
            ):
                _fail("rollback evidence is unrelated to this pilot")
            _timestamp(evidence.get("observed_at"))
            native_ref = evidence.get("native_proof_ref") if isinstance(evidence, dict) else None
            if native_ref not in _validated_attempt_evidence_refs(manifest):
                _fail("native rollback proof is not validated attempt evidence")
            native_path = (root / native_ref).resolve() if _repo_ref(native_ref) else None
            if (
                native_path is None
                or not native_path.is_relative_to(root)
                or not native_path.is_file()
            ):
                _fail("native rollback proof is missing")
            _walk(_load_json(native_path))
            native_sha = _artifact_sha(native_path)
            validate_rollback_proof(
                evidence,
                rollback=rollback,
                app_bundle_ref=build["app_bundle_ref"],
                app_sha=app_sha,
                source_sha=source_sha,
                evidence_sha=native_sha,
            )
        ledger = _load_json(root / manifest["evidence_ledger_ref"])
        try:
            EvidenceLedger._validate_ledger(ledger)
        except ValidationError as error:
            raise PilotValidationError(
                "evidence ledger failed the shared schema"
            ) from error
        ledger_result = {
            "completed": "passed",
            "partial": "failed",
            "blocked": "blocked",
        }[outcome]
        matching_records = [
            record
            for record in ledger["records"]
            if (
            record["source_id"] == manifest["pilot_id"]
            and record["source_type"] == "pilot"
            and record["result"] == ledger_result
            and record["revision"] == build["commit"]
            )
        ]
        if not matching_records:
            _fail("evidence ledger does not contain the truthful pilot outcome")
        expected_outcome_artifact = {
            "status": ledger_result,
            "issue": "GH-73",
            "commit": build["commit"],
            "pilot_id": manifest["pilot_id"],
            "observed_at": window["ends_at"],
            "result": outcome,
            "observed_attempts": counts["observed"],
            "unobserved_attempts": counts["unobserved"],
            "production_readiness_claimed": False,
            "privacy_safe": True,
        }
        artifact_matches = False
        for record in matching_records:
            if record["source_ref"] != "pilots/evidence/GH-73/pilot-outcome.json":
                continue
            artifact = (root / record["source_ref"]).resolve()
            if not artifact.is_relative_to(root) or not artifact.is_file():
                continue
            artifact_payload = _load_json(artifact)
            _walk(artifact_payload)
            artifact_matches |= (
                artifact_payload == expected_outcome_artifact
                and record["artifact_sha256"]
                == f"sha256:{_artifact_sha(artifact)}"
            )
        if not artifact_matches:
            _fail("ledger outcome artifact is missing or changed")

    return {
        "schema_version": 1,
        "status": "verified",
        "pilot_outcome": outcome,
        "issue": "GH-73",
        "commit": build["commit"],
        "finished_at": window["ends_at"],
        "environment": "owner-pilot",
        "attempt_counts": counts,
        "rollback": "proven-dry-run",
        "external_readbacks": {
            name: {
                "classification": item["classification"],
                "scope": item.get("scope"),
                **({"status": item["status"]} if "status" in item else {}),
            }
            for name, item in manifest["reconciliation"].items()
        },
        "production_readiness_claimed": False,
    }


def _load_json(path: Path) -> Any:
    def reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        value: dict[str, Any] = {}
        for key, child in pairs:
            if key in value:
                _fail("JSON contains a duplicate field")
            value[key] = child
        return value

    return json.loads(
        path.read_text(encoding="utf-8"), object_pairs_hook=reject_duplicates
    )


def _write(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    verify = commands.add_parser("verify")
    verify.add_argument("manifest", type=Path)
    verify.add_argument("--expected-commit", required=True)
    verify.add_argument("--verify-app-artifact", action="store_true")
    verify.add_argument("--output", type=Path, required=True)
    rollback = commands.add_parser("rollback-dry-run")
    rollback.add_argument("manifest", type=Path)
    rollback.add_argument("--native-proof-ref", required=True)
    rollback.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "rollback-dry-run":
            result = generate_rollback_proof(
                _load_json(args.manifest),
                repository_root=Path.cwd(),
                native_proof_ref=args.native_proof_ref,
            )
        else:
            result = verify_manifest(
                _load_json(args.manifest),
                expected_commit=args.expected_commit,
                repository_root=Path.cwd(),
                verify_app_artifact=args.verify_app_artifact,
            )
    except (
        OSError,
        UnicodeDecodeError,
        json.JSONDecodeError,
        PilotValidationError,
    ) as error:
        print(f"pilot {args.command} failed: {error}", file=sys.stderr)
        return 2
    _write(args.output, result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
