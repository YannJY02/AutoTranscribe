from __future__ import annotations

import json
import subprocess
import sys
from dataclasses import asdict
from pathlib import Path

from scripts.agent_harness import (
    _run_command,
    check_agentic_locks,
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


def test_agentic_source_changes_compile_and_check_generated_files():
    gates = gate_specs(
        [".github/workflows/agentic-ci-doctor.md"], mode="full", python_executable="python3.11"
    )

    assert gates[-1].name == "agentic-workflows"
    assert gates[-1].commands == (("python3.11", "scripts/agent_harness.py", "agentic-lock-check"),)


def test_agentic_generated_changes_also_trigger_lock_check():
    generated_paths = [
        ".github/workflows/agentic-ci-doctor.lock.yml",
        ".github/workflows/agentic_commands.yml",
        ".github/aw/actions-lock.json",
    ]

    for path in generated_paths:
        assert gate_specs([path], mode="quick", python_executable="python3.11")[-1].name == "agentic-workflows"


def test_agentic_lock_check_purges_orphaned_workflows(monkeypatch):
    commands = []
    monkeypatch.setattr("scripts.agent_harness._agentic_generated_snapshot", lambda: {})

    def completed(command, **_kwargs):
        commands.append(command)
        return subprocess.CompletedProcess(command, 0, "", "")

    monkeypatch.setattr("scripts.agent_harness.subprocess.run", completed)

    assert check_agentic_locks() == 0
    assert "--purge" in commands[0]


def test_agentic_lock_check_uses_native_actionlint_when_available(monkeypatch):
    commands = []
    snapshot = {".github/workflows/example.lock.yml": b"workflow"}
    monkeypatch.setattr("scripts.agent_harness._agentic_generated_snapshot", lambda: snapshot)
    monkeypatch.setattr(
        "scripts.agent_harness.shutil.which",
        lambda executable: "/opt/homebrew/bin/actionlint" if executable == "actionlint" else None,
    )

    def completed(command, **_kwargs):
        commands.append(command)
        return subprocess.CompletedProcess(command, 0, "", "")

    monkeypatch.setattr("scripts.agent_harness.subprocess.run", completed)

    assert check_agentic_locks() == 0
    assert "--actionlint" not in commands[0]
    assert commands[1] == ["/opt/homebrew/bin/actionlint", ".github/workflows/example.lock.yml"]


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
    assert "gh auth token" not in launcher
    assert "SYMPHONY_GITHUB_TOKEN" in launcher


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
