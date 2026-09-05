from __future__ import annotations

import json
import re
import subprocess
import sys
from dataclasses import asdict
from pathlib import Path

import pytest

from scripts.agent_harness import (
    TRIAGE_LABELS,
    _run_command,
    _symphony_snapshot,
    changes_sha256,
    changed_files,
    installed_app_snapshot,
    doctor,
    gate_specs,
    git_changes_sha256,
    issue_preflight,
    linear_issue_identifier,
    parse_issue_number,
    runtime_status,
    telemetry_snapshot,
    validate_issue,
    write_controller_handoff,
)
from scripts.symphony_delivery_controller import TRIAGE_LABELS as CONTROLLER_TRIAGE_LABELS


def issue_payload(**overrides):
    payload = {
        "number": 12,
        "state": "OPEN",
        "labels": [{"name": "ready-for-agent"}],
        "assignees": [],
        "body": """## Goal

Prove the harness can complete one unattended issue.

## Context

Use AGENTS.md and docs/agents/harness.md.

## Boundary

Do not change product behavior.

## Acceptance

- [ ] Harness doctor passes.

## Verification

`python3.11 scripts/agent_harness.py doctor`

## Resource class

isolated

## Blockers

None.

## Human gates

None.
""",
    }
    payload.update(overrides)
    return payload


def test_parse_issue_number_accepts_tracker_identifiers():
    assert parse_issue_number("12") == 12
    assert parse_issue_number("#12") == 12
    assert parse_issue_number("GH-12") == 12


def test_linear_issue_identifier_uses_verified_linkback_comment():
    payload = issue_payload(
        comments=[
            {
                "author": {"login": "linear-code"},
                "body": '<!-- linear-linkback --><a href="https://linear.app/yannjy/issue/YAN-32">YAN-32</a>',
            }
        ]
    )

    assert linear_issue_identifier(payload) == "YAN-32"


def test_issue_preflight_rejects_ready_issue_without_linear_linkback(monkeypatch):
    monkeypatch.setattr("scripts.agent_harness.load_issue", lambda _number: issue_payload())

    result = issue_preflight("12")

    assert "synchronized issue is missing the verified Linear linkback" in result["errors"]


def test_issue_preflight_can_validate_a_safe_ci_retry_without_mutating_the_issue(monkeypatch):
    payload = issue_payload(
        labels=[],
        assignees=[],
        comments=[
            {
                "author": {"login": "linear-code"},
                "body": '<!-- linear-linkback --><a href="https://linear.app/yannjy/issue/YAN-62">YAN-62</a>',
            }
        ],
    )
    monkeypatch.setattr("scripts.agent_harness.load_issue", lambda _number: payload)

    result = issue_preflight("12", retry=True)

    assert result["status"] == "passed"
    assert payload["labels"] == []
    assert payload["assignees"] == []


def test_issue_preflight_retry_rejects_any_assignee(monkeypatch):
    payload = issue_payload(
        labels=[],
        assignees=[{"login": "human-reviewer"}],
        comments=[
            {
                "author": {"login": "linear-code"},
                "body": '<!-- linear-linkback --><a href="https://linear.app/yannjy/issue/YAN-62">YAN-62</a>',
            }
        ],
    )
    monkeypatch.setattr("scripts.agent_harness.load_issue", lambda _number: payload)

    result = issue_preflight("12", retry=True)

    assert result["status"] == "failed"
    assert any("unassigned" in error for error in result["errors"])


def test_issue_preflight_retry_preserves_a_human_triage_decision(monkeypatch):
    payload = issue_payload(
        labels=[{"name": "needs-info"}],
        comments=[
            {
                "author": {"login": "linear-code"},
                "body": '<!-- linear-linkback --><a href="https://linear.app/yannjy/issue/YAN-62">YAN-62</a>',
            }
        ],
    )
    monkeypatch.setattr("scripts.agent_harness.load_issue", lambda _number: payload)

    result = issue_preflight("12", retry=True)

    assert result["status"] == "failed"
    assert "CI retry preflight requires no active triage label" in result["errors"]


def test_validate_issue_accepts_complete_ready_issue():
    assert validate_issue(issue_payload()) == []


def test_validate_issue_rejects_freeform_blockers():
    payload = issue_payload(body=issue_payload()["body"].replace("None.\n\n## Human gates", "Waiting on the designer.\n\n## Human gates"))

    assert "Blockers must be None or contain only explicit #<issue> references" in validate_issue(payload)


def test_validate_issue_accepts_documented_blocker_prefix_and_current_worker_resume():
    payload = issue_payload(
        assignees=[{"login": "agent-worker"}],
        body=issue_payload()["body"].replace("None.\n\n## Human gates", "Blocked by: #123\n\n## Human gates"),
    )

    assert validate_issue(payload, allowed_assignee_login="agent-worker") == []


def test_validate_issue_rejects_missing_contract_and_conflicting_resource_classes():
    payload = issue_payload(
        assignees=[{"login": "another-worker"}],
        labels=[{"name": "ready-for-agent"}, {"name": "needs-info"}],
        body=issue_payload()["body"]
        .replace("## Verification\n\n`python3.11 scripts/agent_harness.py doctor`\n\n", "")
        .replace("isolated", "isolated and exclusive-macos")
    )

    errors = validate_issue(payload)

    assert any("Verification" in error for error in errors)
    assert any("exactly one resource class" in error for error in errors)
    assert any("unassigned" in error for error in errors)
    assert any("exactly ready-for-agent" in error for error in errors)


def test_gate_specs_keep_docs_only_changes_narrow():
    names = [spec.name for spec in gate_specs(["docs/agents/harness.md"], mode="full", python_executable="python3.11")]

    assert names == ["diff-check", "harness-tests", "project-normalization"]


def test_gate_specs_route_python_and_swift_changes():
    names = [
        spec.name
        for spec in gate_specs(
            ["insightkit/ipc/server.py", "macos/InsightKitApp/Sources/InsightKitApp/App.swift"],
            mode="full",
            python_executable="python3.11",
        )
    ]

    assert names == ["diff-check", "python-tests", "swift-tests", "architecture-contracts"]


def test_gate_specs_route_project_configuration_and_ui_tests():
    python_gates = gate_specs(["pyproject.toml"], mode="full", python_executable="python3.11")
    native_names = [
        spec.name
        for spec in gate_specs(
            [
                "macos/InsightKitApp/project.yml",
                "macos/InsightKitApp/UITests/RecordsPersistenceUITests.swift",
                "scripts/run_uitests.sh",
            ],
            mode="full",
            python_executable="python3.11",
        )
    ]

    assert [spec.name for spec in python_gates] == ["diff-check", "python-tests"]
    assert ("git", "diff", "--cached", "--check") in python_gates[0].commands
    assert python_gates[1].commands[0] == ("./scripts/agent_bootstrap.sh",)
    assert native_names == ["diff-check", "automation-syntax", "xcuitests"]


def test_changed_files_includes_staged_paths(monkeypatch):
    outputs = {
        ("git", "diff", "--name-only", "origin/main...HEAD"): "committed.py\n",
        ("git", "diff", "--name-only"): "unstaged.swift\n",
        ("git", "diff", "--cached", "--name-only"): "staged.py\n",
        ("git", "ls-files", "--others", "--exclude-standard"): "untracked.sh\n",
    }

    def completed(command, **_kwargs):
        return subprocess.CompletedProcess(command, 0, outputs[tuple(command)], "")

    monkeypatch.setattr("scripts.agent_harness.subprocess.run", completed)

    assert changed_files("origin/main") == ["committed.py", "staged.py", "unstaged.swift", "untracked.sh"]


def test_change_digest_matches_the_committed_tree_and_rejects_symlinks(tmp_path):
    subprocess.run(["git", "init", "-b", "main"], cwd=tmp_path, check=True, capture_output=True)
    subprocess.run(["git", "config", "user.name", "Harness Test"], cwd=tmp_path, check=True)
    subprocess.run(["git", "config", "user.email", "harness@example.invalid"], cwd=tmp_path, check=True)
    regular = tmp_path / "feature.py"
    regular.write_text("print('verified')\n", encoding="utf-8")
    subprocess.run(["git", "add", "feature.py"], cwd=tmp_path, check=True)
    subprocess.run(["git", "commit", "-m", "verified"], cwd=tmp_path, check=True, capture_output=True)

    assert git_changes_sha256(tmp_path, "HEAD", ["feature.py"]) == changes_sha256(tmp_path, ["feature.py"])

    (tmp_path / "linked.py").symlink_to(regular)
    with pytest.raises(ValueError, match="symbolic link"):
        changes_sha256(tmp_path, ["linked.py"])


def test_gate_specs_route_harness_tests_and_symphony_shell():
    test_names = [
        spec.name
        for spec in gate_specs(["tests/test_agent_harness.py"], mode="full", python_executable="python3.11")
    ]
    shell_gates = gate_specs(["scripts/run_symphony.sh"], mode="full", python_executable="python3.11")

    assert "harness-tests" in test_names
    assert "automation-syntax" in [spec.name for spec in shell_gates]
    assert ("sh", "-n", "scripts/run_symphony.sh") in next(
        spec.commands for spec in shell_gates if spec.name == "automation-syntax"
    )


def test_actions_are_deterministic_ci_only():
    workflows = Path(__file__).resolve().parent.parent / ".github" / "workflows"
    tracked = sorted(path.name for path in workflows.iterdir() if path.is_file())

    assert tracked == ["ci.yml", "controller-handoff.yml"]
    ci = (workflows / "ci.yml").read_text(encoding="utf-8")
    handoff = (workflows / "controller-handoff.yml").read_text(encoding="utf-8")
    assert "copilot-requests" not in ci
    assert "gh-aw" not in ci
    assert "workflow_run:" in handoff
    assert "actions/checkout" in handoff
    assert '"$author" == "$GITHUB_REPOSITORY_OWNER"' in handoff
    assert "issue-preflight --issue \"$issue_number\" --retry" in handoff
    assert "Preserving human triage state" in handoff
    assert "--method PUT" not in handoff
    assert '--method POST "repos/$GITHUB_REPOSITORY/issues/$issue_number/labels"' in handoff
    assert '--method DELETE "repos/$GITHUB_REPOSITORY/issues/$issue_number/labels/$target"' in handoff
    assert "ready-for-human" in handoff
    assert "ready-for-agent" in handoff
    workflow_labels = set(re.findall(r'"((?:needs|ready)-[a-z-]+|wontfix)"', handoff))
    assert workflow_labels == TRIAGE_LABELS == CONTROLLER_TRIAGE_LABELS


def test_command_evidence_never_persists_process_output(tmp_path, monkeypatch):
    monkeypatch.setenv("HARNESS_TEST_SECRET", "do-not-persist-this-secret")
    result = _run_command(
        [sys.executable, "-c", "import os; print(os.environ['HARNESS_TEST_SECRET'])"],
        output_root=tmp_path,
    )

    assert "do-not-persist-this-secret" not in json.dumps(asdict(result))


def test_symphony_configuration_uses_dedicated_token_and_core_environment():
    root = Path(__file__).resolve().parent.parent
    workflow = (root / "WORKFLOW.md").read_text(encoding="utf-8")
    launcher = (root / "scripts/run_symphony.sh").read_text(encoding="utf-8")
    gate = (root / "scripts/symphony_issue_gate.sh").read_text(encoding="utf-8")
    after_run = (root / "scripts/symphony_after_run.sh").read_text(encoding="utf-8")

    assert "shell_environment_policy.inherit=core" in workflow
    assert "shell_environment_policy.inherit=all" not in workflow
    assert "env -u SYMPHONY_AGENT_GITHUB_TOKEN" in workflow
    assert "-u SYMPHONY_GITHUB_TOKEN" in workflow
    assert "-u OPENAI_API_KEY" in workflow
    assert '"$SYMPHONY_CONTROLLER_REPO_ROOT/scripts/symphony-bin/codex"' in workflow
    assert "before_run:" in workflow
    assert "after_run:" in workflow
    assert "agent_harness.py handoff" in workflow
    assert "issue-preflight --json" in gate
    assert "--resume" in gate
    assert "SYMPHONY_PREFLIGHT_EVIDENCE_ROOT" in workflow
    assert "SYMPHONY_REAL_CODEX" in launcher
    assert 'PATH="$repo_root/scripts/symphony-bin:$PATH"' not in launcher
    assert "agent-github-token" not in launcher
    assert "agent-github-token" in gate
    assert "agent-github-token" in after_run
    assert "--workspace \"$workspace\"" in after_run
    assert "agent_harness.py\" verify" not in after_run
    assert "cd \"$SYMPHONY_CONTROLLER_REPO_ROOT\"" in after_run
    assert "SYMPHONY_PREFLIGHT_EVIDENCE_ROOT" in launcher
    assert "read_timeout_ms: 120000" in workflow
    assert "dashboard_enabled: false" in workflow
    assert "SYMPHONY_REPO_SOURCE" in workflow
    assert "git remote set-url origin" in workflow
    assert "gh auth token" not in launcher
    assert "SYMPHONY_GITHUB_TOKEN" in launcher
    assert "security find-generic-password" in launcher
    assert "proxy-environment" in launcher
    assert "unset OPENAI_API_KEY" in launcher
    assert "symphony_delivery_controller.py" in after_run
    assert "symphony_after_run.sh" in workflow
    assert "runtime-status" in launcher
    assert "Runtime status refresh failed" in launcher
    assert 'rm -f "$runtime_status_path"' in launcher


def test_installed_app_snapshot_reports_revision_freshness_without_exposing_project_key(tmp_path):
    import plistlib

    app = tmp_path / "InsightKit.app"
    plist = app / "Contents" / "Info.plist"
    plist.parent.mkdir(parents=True)
    plist.write_bytes(
        plistlib.dumps(
            {
                "CFBundleVersion": "202609030001",
                "CFBundleShortVersionString": "0.1.0",
                "InsightKitGitRevision": "abcdef1",
                "InsightKitPostHogOwnerPilotHost": "https://us.i.posthog.com",
                "InsightKitPostHogOwnerPilotProjectKey": "secret-project-key",
                "InsightKitPostHogOwnerPilotRetentionVerified": True,
            }
        )
    )

    snapshot = installed_app_snapshot(app, expected_revision="abcdef123456")

    assert snapshot["freshness"] == "current"
    assert snapshot["posthog_transport_ready"] is True
    assert "secret-project-key" not in json.dumps(snapshot)


def test_telemetry_snapshot_records_only_bounded_file_state(tmp_path):
    (tmp_path / "Sentry").mkdir()
    (tmp_path / "local-evidence-ledger-v1.json").write_text('{"private":"meeting text"}', encoding="utf-8")
    (tmp_path / "Sentry" / "external-telemetry-disable-evidence-v1.json").write_text(
        '{"secret":"do-not-copy"}', encoding="utf-8"
    )

    snapshot = telemetry_snapshot(tmp_path)

    assert snapshot == {
        "product_analytics_ledger_exists": True,
        "sentry_disable_evidence_exists": True,
    }
    assert "meeting text" not in json.dumps(snapshot)


def test_symphony_snapshot_rejects_non_loopback_urls():
    with pytest.raises(ValueError, match="loopback"):
        _symphony_snapshot("https://example.com/api/v1/state")


def test_runtime_status_bounds_remote_probe_and_falls_back_to_local_head(tmp_path, monkeypatch):
    commands = []

    def run(command, **kwargs):
        commands.append((command, kwargs))
        if command[:2] == ["git", "ls-remote"]:
            raise subprocess.TimeoutExpired(command, kwargs["timeout"])
        if command[:2] == ["pgrep", "-x"]:
            return subprocess.CompletedProcess(command, 1)
        if command[:2] == ["git", "status"]:
            return subprocess.CompletedProcess(command, 0, "", "")
        raise AssertionError(command)

    monkeypatch.setattr("scripts.agent_harness.subprocess.run", run)
    monkeypatch.setattr(
        "scripts.agent_harness._git_value",
        lambda *args: "abcdef123456" if args == ("rev-parse", "HEAD") else "main",
    )
    monkeypatch.setattr("scripts.agent_harness._symphony_snapshot", lambda _url: {"healthy": True})

    payload = runtime_status(
        app_path=tmp_path / "missing.app",
        telemetry_root=tmp_path,
        symphony_url="http://127.0.0.1:4000/api/v1/state",
    )

    assert payload["repository"]["main_revision"] == "abcdef123456"
    assert payload["repository"]["main_revision_source"] == "local-head-fallback"
    assert next(kwargs["timeout"] for command, kwargs in commands if command[:2] == ["git", "ls-remote"]) == 10


@pytest.mark.parametrize("running_bundle, expected", [("test-host", False), ("installed", True), ("none", False), ("unavailable", None)])
def test_runtime_status_binds_running_state_to_requested_bundle(tmp_path, monkeypatch, running_bundle, expected):
    import plistlib

    app = tmp_path / "Operator Applications" / "InsightKit.app"
    executable = app / "Contents" / "MacOS" / "InsightKitApp"
    executable.parent.mkdir(parents=True)
    executable.touch()
    (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "InsightKitApp"}))
    test_executable = tmp_path / "DerivedData" / "InsightKitUITestHost.app" / "Contents" / "MacOS" / "InsightKitApp"

    def run(command, **kwargs):
        if command[:2] == ["git", "ls-remote"]:
            return subprocess.CompletedProcess(command, 0, "abcdef123456\trefs/heads/main\n", "")
        if command[:2] == ["git", "status"]:
            return subprocess.CompletedProcess(command, 0, "", "")
        if command[0] == "pgrep":
            # A name-only probe cannot tell these two bundles apart.
            return subprocess.CompletedProcess(command, 0 if running_bundle != "none" else 1, b"123\n")
        if command[0] == "ps":
            paths = {"test-host": str(test_executable), "installed": f"{test_executable}\n{executable}", "none": ""}
            return subprocess.CompletedProcess(command, 1 if running_bundle == "unavailable" else 0, paths.get(running_bundle, ""), "")
        raise AssertionError(command)

    monkeypatch.setattr("scripts.agent_harness.subprocess.run", run)
    monkeypatch.setattr("scripts.agent_harness._git_value", lambda *args: "abcdef123456")
    monkeypatch.setattr("scripts.agent_harness._symphony_snapshot", lambda _url: {"healthy": True})
    result = runtime_status(app_path=app, telemetry_root=tmp_path, symphony_url="http://127.0.0.1:4000/api/v1/state")

    assert result["installed_app"]["running"] is expected


def test_write_controller_handoff_derives_bounded_evidence_from_passed_manifest(tmp_path):
    manifest = tmp_path / "logs" / "harness" / "run" / "manifest.json"
    manifest.parent.mkdir(parents=True)
    manifest.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "status": "passed",
                "issue": 95,
                "workspace": str(tmp_path),
                "changed_files": ["feature.py"],
                "changes_sha256": changes_sha256(tmp_path, ["feature.py"]),
                "mode": "full",
                "gates": [{"name": "python-tests", "status": "passed", "commands": []}],
            }
        ),
        encoding="utf-8",
    )

    result = write_controller_handoff(
        root=tmp_path,
        issue="GH-95",
        manifest_path=manifest,
        summary="Close the delivery loop",
        review_status="clear",
        human_gates=("Review and merge.",),
        no_change=False,
    )

    payload = json.loads(result.read_text(encoding="utf-8"))
    assert payload["manifest"] == "logs/harness/run/manifest.json"
    assert payload["kind"] == "changes"
    assert payload["summary"] == "Close the delivery loop"
    assert "commands" not in payload


def test_app_proof_doctor_checks_full_xcode_and_native_capture_tools():
    checks = {item["check"] for item in doctor(profile="app-proof")["checks"]}

    assert "command:xcodebuild" in checks
    assert "command:xcrun" in checks
    assert "command:xcodegen" in checks
    assert "xcode-runtime" in checks
    assert "file:/usr/sbin/screencapture" in checks
    assert "file:/usr/bin/log" in checks


def test_app_proof_doctor_reports_missing_xcode_without_crashing(monkeypatch):
    original_run = subprocess.run

    def missing_xcode(command, *args, **kwargs):
        if command[0] in {"xcodebuild", "xcrun"}:
            raise FileNotFoundError(command[0])
        return original_run(command, *args, **kwargs)

    monkeypatch.setattr("scripts.agent_harness.subprocess.run", missing_xcode)

    runtime = next(item for item in doctor(profile="app-proof")["checks"] if item["check"] == "xcode-runtime")
    assert runtime["ok"] is False
    assert runtime["detail"]["failed"] == [
        "xcodebuild -version",
        "xcrun --find xcresulttool",
        "xcrun --find xctrace",
    ]


def test_lock_subcommand_runs_command_and_writes_no_secret(tmp_path):
    marker = tmp_path / "ran.json"
    command = [
        sys.executable,
        "scripts/agent_harness.py",
        "lock",
        "--resource",
        "test-resource",
        "--timeout",
        "1",
        "--",
        sys.executable,
        "-c",
        f"from pathlib import Path; import json; Path({str(marker)!r}).write_text(json.dumps({{'ok': True}}))",
    ]

    completed = subprocess.run(command, text=True, capture_output=True, check=False)

    assert completed.returncode == 0, completed.stderr
    assert json.loads(marker.read_text(encoding="utf-8")) == {"ok": True}
