from __future__ import annotations

import json
import subprocess
import sys
from dataclasses import asdict
from pathlib import Path

from scripts.agent_harness import (
    _run_command,
    changed_files,
    doctor,
    gate_specs,
    parse_issue_number,
    validate_issue,
)


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

    assert tracked == ["ci.yml"]
    ci = (workflows / "ci.yml").read_text(encoding="utf-8")
    assert "copilot-requests" not in ci
    assert "gh-aw" not in ci


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

    assert "shell_environment_policy.inherit=core" in workflow
    assert "shell_environment_policy.inherit=all" not in workflow
    assert "env -u SYMPHONY_GITHUB_TOKEN" in workflow
    assert "-u OPENAI_API_KEY" in workflow
    assert "read_timeout_ms: 30000" in workflow
    assert "SYMPHONY_REPO_SOURCE" in workflow
    assert "git remote set-url origin" in workflow
    assert "gh auth token" not in launcher
    assert "SYMPHONY_GITHUB_TOKEN" in launcher
    assert "security find-generic-password" in launcher
    assert "unset OPENAI_API_KEY" in launcher


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
