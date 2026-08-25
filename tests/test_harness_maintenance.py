from __future__ import annotations

from datetime import date
import json
import plistlib
import shlex
import subprocess

from scripts.harness_maintenance import (
    TASKS,
    _macos_proxy_environment,
    _shell_proxy_exports,
    due_task_names,
    enqueue,
    existing_issue_url,
    install_launch_agent,
    install_symphony_launch_agent,
    issue_body,
    marker_for,
)
from scripts.agent_harness import validate_issue


def test_tuesday_catches_up_monday_and_tuesday_tasks():
    assert due_task_names(date(2026, 8, 25)) == ["docs-gardening", "feedback-promotion"]


def test_maintenance_issue_is_deduplicated_and_dispatch_ready():
    task = TASKS["feedback-promotion"]
    period = "2026-W35"
    body = issue_body(task, period)

    assert marker_for(task, period) in body
    for heading in (
        "Goal",
        "Context",
        "Boundary",
        "Acceptance",
        "Verification",
        "Resource class",
        "Blockers",
        "Human gates",
    ):
        assert f"## {heading}" in body
    assert "exactly one of Docs, Skill, Lint, or Structural Test" in body
    assert "isolated" in body
    assert body.rstrip().endswith("None.")
    assert validate_issue(
        {"state": "OPEN", "labels": [{"name": "ready-for-agent"}], "assignees": [], "body": body}
    ) == []


def test_launch_agent_uses_canonical_repo_and_daily_schedule(tmp_path, monkeypatch):
    repo = tmp_path / "repo"
    script = repo / "scripts" / "harness_maintenance.py"
    script.parent.mkdir(parents=True)
    script.write_text("# test\n", encoding="utf-8")
    monkeypatch.setattr("scripts.harness_maintenance.shutil.which", lambda command: f"/tools/{command}")

    destination = install_launch_agent(repo, load=False, launch_agents_dir=tmp_path / "LaunchAgents")
    payload = plistlib.loads(destination.read_bytes())

    assert payload["ProgramArguments"] == [
        "/tools/python3.11",
        str(script),
        "enqueue",
        "--task",
        "due",
    ]
    assert payload["WorkingDirectory"] == str(repo)
    assert payload["StartCalendarInterval"] == {"Hour": 9, "Minute": 0}


def test_macos_proxy_environment_reads_enabled_system_proxies(monkeypatch):
    output = """
  HTTPEnable : 1
  HTTPProxy : 127.0.0.1
  HTTPPort : 7897
  HTTPSEnable : 1
  HTTPSProxy : 127.0.0.1
  HTTPSPort : 7897
  ExceptionsList : <array> {
    0 : *.local
    1 : 169.254/16
  }
  ExcludeSimpleHostnames : 1
  __SCOPED__ : <dictionary> {
    HTTPProxy : ignored.example
    HTTPPort : 9999
  }
"""
    monkeypatch.setattr("scripts.harness_maintenance.sys.platform", "darwin")
    monkeypatch.setattr(
        "scripts.harness_maintenance.subprocess.run",
        lambda *_args, **_kwargs: subprocess.CompletedProcess([], 0, output, ""),
    )

    assert _macos_proxy_environment() == {
        "HTTP_PROXY": "http://127.0.0.1:7897",
        "HTTPS_PROXY": "http://127.0.0.1:7897",
        "NO_PROXY": "127.0.0.1,localhost,*.local,169.254/16,<local>",
    }


def test_shell_proxy_exports_quote_untrusted_system_values():
    exports = _shell_proxy_exports({"HTTPS_PROXY": "http://proxy/'$(unsafe)"})

    assert shlex.split(exports.removeprefix("export ")) == ["HTTPS_PROXY=http://proxy/'$(unsafe)"]


def test_symphony_launch_agent_uses_local_main_without_model_api_key(tmp_path, monkeypatch):
    repo = tmp_path / "repo"
    launcher = repo / "scripts" / "run_symphony.sh"
    launcher.parent.mkdir(parents=True)
    launcher.write_text("#!/bin/sh\n", encoding="utf-8")
    (repo / "WORKFLOW.md").write_text("# test\n", encoding="utf-8")
    resolved = {
        "symphony": "/last/symphony",
        "codex": "/first/codex",
        "gh": "/tools/gh",
        "python3.11": "/tools/python3.11",
    }
    monkeypatch.setenv("PATH", "/first:/tools:/last:/unrelated")
    monkeypatch.setattr("scripts.harness_maintenance.shutil.which", resolved.get)

    destination = install_symphony_launch_agent(
        repo,
        load=False,
        launch_agents_dir=tmp_path / "LaunchAgents",
    )
    payload = plistlib.loads(destination.read_bytes())

    assert payload["ProgramArguments"] == ["/bin/sh", str(launcher)]
    assert payload["WorkingDirectory"] == str(repo)
    assert payload["EnvironmentVariables"]["SYMPHONY_REPO_SOURCE"] == str(repo)
    assert payload["EnvironmentVariables"]["PATH"].split(":")[:3] == ["/first", "/tools", "/last"]
    assert "HTTPS_PROXY" not in payload["EnvironmentVariables"]
    assert "OPENAI_API_KEY" not in payload["EnvironmentVariables"]
    assert payload["KeepAlive"] is True
    assert payload["RunAtLoad"] is True


def test_enqueue_reuses_existing_period_issue_without_creating(monkeypatch):
    task = TASKS["feedback-promotion"]
    existing = "https://github.com/YannJY02/AutoTranscribe/issues/99"
    monkeypatch.setattr("scripts.harness_maintenance.existing_issue_url", lambda *_args: existing)
    monkeypatch.setattr(
        "scripts.harness_maintenance._run",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(AssertionError("must not create a duplicate")),
    )

    assert enqueue(task, date(2026, 8, 25), dry_run=False) == {
        "task": "feedback-promotion",
        "period": "2026-W35",
        "status": "existing",
        "url": existing,
    }


def test_existing_issue_lookup_requires_the_exact_period_marker(monkeypatch):
    task = TASKS["feedback-promotion"]
    exact = marker_for(task, "2026-W35")
    payload = json.dumps(
        [
            {"body": "<!-- harness-maintenance:feedback-promotion:2026-W34 -->", "url": "old"},
            {"body": exact, "url": "current"},
        ]
    )
    monkeypatch.setattr(
        "scripts.harness_maintenance._run",
        lambda *_args, **_kwargs: subprocess.CompletedProcess([], 0, payload, ""),
    )

    assert existing_issue_url(task, "2026-W35") == "current"
