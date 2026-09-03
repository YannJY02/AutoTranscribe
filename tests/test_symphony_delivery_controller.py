from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest

from scripts.symphony_delivery_controller import (
    DeliveryController,
    DeliveryError,
    branch_name,
    load_delivery_context,
    render_pull_request_body,
    should_process,
)


def _git(*args: str, cwd: Path) -> str:
    result = subprocess.run(["git", *args], cwd=cwd, text=True, capture_output=True, check=True)
    return result.stdout.strip()


def _workspace(tmp_path: Path) -> tuple[Path, Path]:
    workspace = tmp_path / "GH-95"
    workspace.mkdir()
    _git("init", "-b", "main", cwd=workspace)
    _git("config", "user.name", "Harness Test", cwd=workspace)
    _git("config", "user.email", "harness@example.invalid", cwd=workspace)
    (workspace / ".gitignore").write_text(".symphony/\nlogs/\n", encoding="utf-8")
    (workspace / "feature.txt").write_text("before\n", encoding="utf-8")
    _git("add", ".gitignore", "feature.txt", cwd=workspace)
    _git("commit", "-m", "base", cwd=workspace)
    (workspace / "feature.txt").write_text("after\n", encoding="utf-8")

    manifest_path = workspace / "logs" / "harness" / "run" / "manifest.json"
    manifest_path.parent.mkdir(parents=True)
    manifest_path.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "status": "passed",
                "issue": 95,
                "workspace": str(workspace),
                "changed_files": ["feature.txt"],
                "gates": [{"name": "python-tests", "status": "passed", "commands": []}],
            }
        ),
        encoding="utf-8",
    )
    handoff_dir = workspace / ".symphony"
    handoff_dir.mkdir()
    (handoff_dir / "handoff.json").write_text(
        json.dumps(
            {
                "schema_version": 1,
                "status": "ready",
                "issue": "GH-95",
                "summary": "Close the delivery loop",
                "kind": "changes",
                "manifest": "logs/harness/run/manifest.json",
                "review_status": "clear",
                "human_gates": ["Review and merge the pull request."],
            }
        ),
        encoding="utf-8",
    )

    preflight_root = tmp_path / "preflight"
    preflight_root.mkdir()
    (preflight_root / "GH-95.json").write_text(
        json.dumps(
            {
                "status": "passed",
                "issue": 95,
                "linear_issue": "YAN-62",
                "url": "https://github.com/YannJY02/AutoTranscribe/issues/95",
                "resource_class": "isolated",
                "blockers": [],
                "errors": [],
            }
        ),
        encoding="utf-8",
    )
    return workspace, preflight_root


def test_load_delivery_context_requires_passed_manifest_and_exact_current_diff(tmp_path: Path):
    workspace, preflight_root = _workspace(tmp_path)

    context = load_delivery_context(workspace, preflight_root)

    assert context.issue_number == 95
    assert context.linear_issue == "YAN-62"
    assert context.changed_files == ("feature.txt",)
    assert context.gates == ("python-tests",)
    assert branch_name(context) == "codex/gh-95-yan-62"


def test_load_delivery_context_rejects_manifest_escape(tmp_path: Path):
    workspace, preflight_root = _workspace(tmp_path)
    handoff_path = workspace / ".symphony" / "handoff.json"
    handoff = json.loads(handoff_path.read_text(encoding="utf-8"))
    handoff["manifest"] = "../outside.json"
    handoff_path.write_text(json.dumps(handoff), encoding="utf-8")

    with pytest.raises(DeliveryError, match="manifest must stay inside the workspace"):
        load_delivery_context(workspace, preflight_root)


def test_load_delivery_context_rejects_unknown_schema_version(tmp_path: Path):
    workspace, preflight_root = _workspace(tmp_path)
    handoff_path = workspace / ".symphony" / "handoff.json"
    handoff = json.loads(handoff_path.read_text(encoding="utf-8"))
    handoff["schema_version"] = 2
    handoff_path.write_text(json.dumps(handoff), encoding="utf-8")

    with pytest.raises(DeliveryError, match="schema version"):
        load_delivery_context(workspace, preflight_root)


def test_load_delivery_context_rejects_unverified_extra_change(tmp_path: Path):
    workspace, preflight_root = _workspace(tmp_path)
    (workspace / "extra.txt").write_text("not verified\n", encoding="utf-8")

    with pytest.raises(DeliveryError, match="changed files do not match"):
        load_delivery_context(workspace, preflight_root)


def test_pull_request_body_contains_bounded_evidence_not_command_output(tmp_path: Path):
    workspace, preflight_root = _workspace(tmp_path)
    context = load_delivery_context(workspace, preflight_root)

    body = render_pull_request_body(context)

    assert "Refs #95" in body
    assert "YAN-62" in body
    assert "python-tests: passed" in body
    assert "Review and merge" in body
    assert "commands" not in body


def test_delivery_state_is_idempotent_per_handoff_digest():
    assert should_process({}, "new") is True
    assert should_process({"status": "pending-ci", "handoff_sha256": "same"}, "same") is False
    assert should_process({"status": "ready-for-human", "handoff_sha256": "same"}, "same") is False
    assert should_process({"status": "failed", "handoff_sha256": "same"}, "same") is True
    assert should_process({"status": "pending-ci", "handoff_sha256": "old"}, "new") is True


def test_controller_rejects_worker_supplied_git_execution_config(tmp_path: Path):
    workspace, preflight_root = _workspace(tmp_path)
    _git("config", "core.fsmonitor", "malicious-command", cwd=workspace)
    context = load_delivery_context(workspace, preflight_root)
    controller = DeliveryController(preflight_root=preflight_root, repository="YannJY02/AutoTranscribe", gh="gh")

    with pytest.raises(DeliveryError, match="unsupported local Git configuration"):
        controller._validate_git_boundary(context, {})


def test_controller_requires_new_change_after_a_pr_has_entered_ci(tmp_path: Path):
    workspace, preflight_root = _workspace(tmp_path)
    _git("update-ref", "refs/remotes/origin/main", "HEAD", cwd=workspace)
    _git("switch", "-c", "codex/gh-95-yan-62", cwd=workspace)
    _git("add", "feature.txt", cwd=workspace)
    _git("commit", "-m", "controller delivery", cwd=workspace)
    controller = DeliveryController(preflight_root=preflight_root, repository="YannJY02/AutoTranscribe", gh="gh")
    state_path = preflight_root.parent / "delivery" / "GH-95.json"
    state_path.parent.mkdir()
    state_path.write_text(
        json.dumps({"status": "failed", "handoff_sha256": "old", "pull_request": "https://example.invalid/pr/1"}),
        encoding="utf-8",
    )

    with pytest.raises(DeliveryError, match="new verified change"):
        controller.process(workspace)
