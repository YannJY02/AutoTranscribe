from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess

from scripts.native_app_proof import finalize_proof


def test_finalize_proof_records_ui_logs_metrics_and_trace_without_log_contents(tmp_path):
    log_path = tmp_path / "xcodebuild.log"
    log_path.write_text(
        "Test Case '-[InsightKitUITests.Flow testOne]' passed (1.250 seconds).\n"
        "Test Case '-[InsightKitUITests.Flow testTwo]' passed (0.500 seconds).\n"
        "** TEST SUCCEEDED **\nsecret-output-must-stay-in-the-log\n",
        encoding="utf-8",
    )
    unified_log = tmp_path / "unified.ndjson"
    unified_log.write_text('{"message":"started"}\n', encoding="utf-8")
    attachments = tmp_path / "attachments"
    attachments.mkdir()
    (attachments / "after.png").write_bytes(b"png")
    video = tmp_path / "journey.mov"
    video.write_bytes(b"mov")
    trace = tmp_path / "journey.trace"
    trace.mkdir()
    result_bundle = tmp_path / "tests.xcresult"
    result_bundle.mkdir()

    proof = finalize_proof(
        output_root=tmp_path,
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
    assert json.loads((tmp_path / "proof.json").read_text(encoding="utf-8"))["status"] == "passed"
    assert json.loads((tmp_path / "metrics.json").read_text(encoding="utf-8"))["tests_passed"] == 2


def test_finalize_proof_fails_when_a_passing_ui_run_has_no_screenshot(tmp_path):
    log_path = tmp_path / "xcodebuild.log"
    log_path.write_text("** TEST SUCCEEDED **\n", encoding="utf-8")

    proof = finalize_proof(
        output_root=tmp_path,
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
    unified_log.write_text('{"message":"started"}\n', encoding="utf-8")
    result_bundle = tmp_path / "tests.xcresult"
    result_bundle.mkdir()
    attachments = tmp_path / "attachments"
    attachments.mkdir()
    (attachments / "after.png").write_bytes(b"png")

    proof = finalize_proof(
        output_root=tmp_path,
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
