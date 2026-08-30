from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess

from scripts.native_app_proof import _display_path, finalize_proof, validate_claim_matrix


def test_finalize_proof_records_ui_logs_metrics_and_trace_without_log_contents(tmp_path):
    log_path = tmp_path / "xcodebuild.log"
    log_path.write_text(
        "Test Case '-[InsightKitUITests.Flow testOne]' passed (1.250 seconds).\n"
        "Test Case '-[InsightKitUITests.Flow testTwo]' passed (0.500 seconds).\n"
        "** TEST SUCCEEDED **\nsecret-output-must-stay-in-the-log\n",
        encoding="utf-8",
    )
    unified_log = tmp_path / "unified.ndjson"
    unified_log.write_text('{"event":"capture-completed"}\n', encoding="utf-8")
    attachments = tmp_path / "attachments"
    attachments.mkdir()
    (attachments / "after.png").write_bytes(b"png")
    video = tmp_path / "journey.mov"
    video.write_bytes(b"mov")
    trace = tmp_path / "journey.trace"
    trace.mkdir()
    result_bundle = tmp_path / "tests.xcresult"
    result_bundle.mkdir()

    output_root = tmp_path / "proof"
    proof = finalize_proof(
        output_root=output_root,
        exit_code=0,
        duration_seconds=2.0,
        xcodebuild_log=log_path,
        unified_log=unified_log,
        result_bundle=result_bundle,
        attachments_dir=attachments,
        video=video,
        trace=trace,
    )

    assert proof["status"] == "passed"
    assert proof["metrics"]["tests_passed"] == 2
    assert proof["metrics"]["test_duration_seconds"] == 1.75
    assert proof["metrics"]["screenshots"] == 1
    assert proof["capabilities"] == {
        "ui": "xcuitest-screenshots-and-screen-recording",
        "logs": "macos-unified-logging",
        "metrics": "proof-json",
        "trace": "instruments-xctrace",
    }
    serialized = json.dumps(proof)
    assert "secret-output-must-stay-in-the-log" not in serialized
    assert proof["privacy_safe"] is False
    assert json.loads((output_root / "proof.json").read_text(encoding="utf-8"))["status"] == "passed"
    assert json.loads((output_root / "metrics.json").read_text(encoding="utf-8"))["tests_passed"] == 2


def test_finalize_proof_fails_when_a_passing_ui_run_has_no_screenshot(tmp_path):
    log_path = tmp_path / "xcodebuild.log"
    log_path.write_text("** TEST SUCCEEDED **\n", encoding="utf-8")

    proof = finalize_proof(
        output_root=tmp_path / "proof",
        exit_code=0,
        duration_seconds=1.0,
        xcodebuild_log=log_path,
        unified_log=None,
        result_bundle=None,
        attachments_dir=None,
        video=None,
        trace=None,
    )

    assert proof["status"] == "failed"
    assert proof["missing_required_evidence"] == ["screenshot", "test-result", "xcresult", "unified-log"]


def test_finalize_proof_enforces_requested_video_and_trace(tmp_path):
    log_path = tmp_path / "xcodebuild.log"
    log_path.write_text("Test Case '-[InsightKitUITests.Flow testOne]' passed (0.100 seconds).\n", encoding="utf-8")
    unified_log = tmp_path / "unified.ndjson"
    unified_log.write_text('{"event":"capture-completed"}\n', encoding="utf-8")
    result_bundle = tmp_path / "tests.xcresult"
    result_bundle.mkdir()
    attachments = tmp_path / "attachments"
    attachments.mkdir()
    (attachments / "after.png").write_bytes(b"png")

    proof = finalize_proof(
        output_root=tmp_path / "proof",
        exit_code=0,
        duration_seconds=1.0,
        xcodebuild_log=log_path,
        unified_log=unified_log,
        result_bundle=result_bundle,
        attachments_dir=attachments,
        video=None,
        trace=None,
        require_video=True,
        require_trace=True,
    )

    assert proof["status"] == "failed"
    assert proof["missing_required_evidence"] == ["video", "trace"]


def test_uitest_runner_rejects_an_existing_proof_directory(tmp_path):
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    for name in ("xcodegen", "xcodebuild"):
        executable = fake_bin / name
        executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        executable.chmod(0o755)
    result_bundle = tmp_path / "fresh.xcresult"
    proof_root = tmp_path / "existing-proof"
    proof_root.mkdir()
    (proof_root / "old.png").write_bytes(b"stale")

    completed = subprocess.run(
        ["bash", "scripts/run_uitests.sh"],
        cwd=Path(__file__).resolve().parent.parent,
        env={
            **os.environ,
            "PATH": f"{fake_bin}:{os.environ['PATH']}",
            "INSIGHTKIT_UITEST_RESULT_BUNDLE": str(result_bundle),
            "INSIGHTKIT_UITEST_PROOF_ROOT": str(proof_root),
        },
        text=True,
        capture_output=True,
        check=False,
    )

    assert completed.returncode == 1
    assert "Proof directory already exists" in completed.stdout + completed.stderr
    assert (proof_root / "old.png").read_bytes() == b"stale"


def test_finalize_proof_records_identity_selected_tests_and_hashes_each_file(tmp_path):
    log_path = tmp_path / "xcodebuild.log"
    log_path.write_text(
        "Test Case '-[InsightKitUITests.HomeViewTests testHome]' passed (0.100 seconds).\n",
        encoding="utf-8",
    )
    unified_log = tmp_path / "unified.ndjson"
    unified_log.write_text('{"event":"capture-completed"}\n', encoding="utf-8")
    result_bundle = tmp_path / "tests.xcresult"
    result_bundle.mkdir()
    (result_bundle / "Info.plist").write_bytes(b"result")
    result_summary = tmp_path / "xcresult-summary.json"
    result_summary.write_text('{"result":"passed"}\n', encoding="utf-8")
    attachments = tmp_path / "attachments"
    attachments.mkdir()
    (attachments / "A1B2C3.png").write_bytes(b"png")
    (attachments / "manifest.json").write_text(json.dumps([{
        "attachments": [{
            "exportedFileName": "A1B2C3.png",
            "suggestedHumanReadableName": "target-window--[HomeViewTests testHome].png",
        }]
    }]), encoding="utf-8")

    proof = finalize_proof(
        output_root=tmp_path / "proof",
        exit_code=0,
        duration_seconds=1.0,
        xcodebuild_log=log_path,
        unified_log=unified_log,
        result_bundle=result_bundle,
        attachments_dir=attachments,
        video=None,
        trace=None,
        result_summary=result_summary,
        source_revision="abc123",
        build="2026083001",
        scenario="home-visible-route",
        selected_tests=["HomeViewTests/testHome"],
        expected_screenshots=["target-window"],
    )

    assert proof["status"] == "passed"
    assert proof["source"] == {"revision": "abc123", "build": "2026083001"}
    assert proof["scenario"] == "home-visible-route"
    assert proof["selected_tests"] == [{"name": "HomeViewTests/testHome", "status": "passed"}]
    assert proof["capture"] == {
        "screenshots": {
            "scope": "target-window",
            "pixels": "original",
            "cursor": "excluded",
            "other_apps": "excluded",
        },
        "video": {"scope": "main-display", "present": False, "privacy_safe": False},
    }
    manifest = json.loads((tmp_path / "proof" / "manifest.json").read_text(encoding="utf-8"))
    files = {item["name"] for item in manifest["files"]}
    assert "xcresult-summary.json" in files
    assert "xcresult/Info.plist" not in files
    assert "screenshots/A1B2C3.png" in files
    assert all(len(item["sha256"]) == 64 for item in manifest["files"])
    artifacts = {item["name"]: item["path"] for item in proof["artifacts"]}
    assert artifacts["xcodebuild-log"] == "xcodebuild.log"
    assert artifacts["unified-log"] == "unified.ndjson"
    assert artifacts["xcresult-summary"] == "xcresult-summary.json"
    assert artifacts["screenshots"] == "screenshots"


def test_finalize_proof_rejects_missing_selected_test_and_expected_screenshot(tmp_path):
    log_path = tmp_path / "xcodebuild.log"
    log_path.write_text(
        "Test Case '-[InsightKitUITests.OtherTests testOther]' passed (0.100 seconds).\n",
        encoding="utf-8",
    )
    attachments = tmp_path / "attachments"
    attachments.mkdir()
    (attachments / "other.png").write_bytes(b"png")
    (attachments / "manifest.json").write_text(json.dumps([{
        "attachments": [{
            "exportedFileName": "missing.png",
            "suggestedHumanReadableName": "home-window.png",
        }]
    }]), encoding="utf-8")
    result_bundle = tmp_path / "tests.xcresult"
    result_bundle.mkdir()
    unified_log = tmp_path / "unified.ndjson"
    unified_log.write_text('{"event":"capture-completed"}\n', encoding="utf-8")

    proof = finalize_proof(
        output_root=tmp_path / "proof",
        exit_code=0,
        duration_seconds=1.0,
        xcodebuild_log=log_path,
        unified_log=unified_log,
        result_bundle=result_bundle,
        attachments_dir=attachments,
        video=None,
        trace=None,
        selected_tests=["HomeViewTests/testHome"],
        expected_screenshots=["home-window"],
    )

    assert proof["status"] == "failed"
    assert proof["missing_required_evidence"] == [
        "selected-test:HomeViewTests/testHome",
        "expected-screenshot:home-window",
    ]
    assert proof["failure"]["classification"] == "test-defect"


def test_finalize_proof_classifies_xcode_macro_server_failure_as_test_defect(tmp_path):
    log_path = tmp_path / "xcodebuild.log"
    log_path.write_text(
        "swift-plugin-server' produced malformed response while compiling permission recovery UI\n",
        encoding="utf-8",
    )

    proof = finalize_proof(
        output_root=tmp_path / "proof",
        exit_code=1,
        duration_seconds=1.0,
        xcodebuild_log=log_path,
        unified_log=None,
        result_bundle=None,
        attachments_dir=None,
        video=None,
        trace=None,
    )

    assert proof["failure"]["classification"] == "test-defect"


def test_finalize_proof_requires_explicit_evidence_to_classify_app_defect(tmp_path):
    log_path = tmp_path / "xcodebuild.log"
    log_path.write_text(
        "Test Case '-[InsightKitUITests.HomeViewTests testHome]' failed (0.100 seconds).\n",
        encoding="utf-8",
    )

    proof = finalize_proof(
        output_root=tmp_path / "proof",
        exit_code=1,
        duration_seconds=1.0,
        xcodebuild_log=log_path,
        unified_log=None,
        result_bundle=None,
        attachments_dir=None,
        video=None,
        trace=None,
        failure_classification="app-defect",
    )

    assert proof["failure"]["classification"] == "app-defect"


def test_finalize_proof_redacts_personal_paths_and_tokens_in_in_place_logs(tmp_path):
    output_root = tmp_path / "proof"
    output_root.mkdir()
    log_path = tmp_path / "xcodebuild.log"
    log_path.write_text(
        "Test Case '-[InsightKitUITests.HomeViewTests testHome]' passed (0.100 seconds).\n"
        "/Users/private-person/secret Authorization: Bearer token-value sk-abcdefghijklmnop\n",
        encoding="utf-8",
    )
    unified_log = output_root / "unified.ndjson"
    unified_log.write_text(
        '{"path":"\\/Users\\/private-person\\/Documents\\/fixture"}\n'
        '{"event":"capture-completed"}\n',
        encoding="utf-8",
    )
    result_bundle = tmp_path / "tests.xcresult"
    result_bundle.mkdir()
    attachments = output_root / "attachments"
    attachments.mkdir()
    (attachments / "target-window.png").write_bytes(b"png")

    finalize_proof(
        output_root=output_root,
        exit_code=0,
        duration_seconds=1.0,
        xcodebuild_log=log_path,
        unified_log=unified_log,
        result_bundle=result_bundle,
        attachments_dir=attachments,
        video=None,
        trace=None,
    )

    retained = (output_root / "xcodebuild.log").read_text(encoding="utf-8") + unified_log.read_text(encoding="utf-8")
    assert "private-person" not in retained
    assert "\\/Users\\/" not in retained
    assert "token-value" not in retained
    assert "sk-abcdefghijklmnop" not in retained


def test_finalize_proof_refuses_to_overwrite_finalized_evidence(tmp_path):
    log_path = tmp_path / "xcodebuild.log"
    log_path.write_text("compile failed\n", encoding="utf-8")
    output_root = tmp_path / "proof"

    finalize_proof(
        output_root=output_root,
        exit_code=1,
        duration_seconds=1.0,
        xcodebuild_log=log_path,
        unified_log=None,
        result_bundle=None,
        attachments_dir=None,
        video=None,
        trace=None,
    )

    try:
        finalize_proof(
            output_root=output_root,
            exit_code=1,
            duration_seconds=1.0,
            xcodebuild_log=log_path,
            unified_log=None,
            result_bundle=None,
            attachments_dir=None,
            video=None,
            trace=None,
        )
    except FileExistsError:
        pass
    else:
        raise AssertionError("finalized proof was overwritten")


def test_claim_matrix_covers_required_surfaces_and_only_locks_exclusive_commands():
    matrix = json.loads(
        (Path(__file__).resolve().parent.parent / "docs/product-proof/claim-matrix.json").read_text(encoding="utf-8")
    )

    result = validate_claim_matrix(matrix)

    assert result["status"] == "passed"
    assert set(result["surfaces"]) == {
        "home", "live", "import", "records", "settings", "restart-persistence", "failure-recovery"
    }
    assert result["manual_only_count"] > 0


def test_ui_proof_logs_only_the_derived_test_app_and_redacts_home_paths():
    runner = (Path(__file__).resolve().parent.parent / "scripts/run_uitests.sh").read_text(encoding="utf-8")

    assert 'processImagePath BEGINSWITH' in runner
    assert 'eventMessage CONTAINS' not in runner
    assert 'xcodegen generate --quiet' in runner
    assert '_redact_text_file' in runner
    assert 'INSIGHTKIT_UITEST_TIMEOUT_SEC:-300' in runner
    assert _display_path(Path.home() / "private-proof") == "$HOME/private-proof"
