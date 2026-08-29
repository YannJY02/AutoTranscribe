from __future__ import annotations

from datetime import date
import json
import os
from pathlib import Path
import plistlib
import pytest
import shlex
import subprocess
import tomllib

from scripts.harness_maintenance import (
    TASKS,
    _bootstrap_launch_agent,
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


def test_maintenance_issue_contract_is_dispatch_ready_after_triage():
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


def test_enqueue_requires_linear_triage_before_dispatch(monkeypatch):
    calls: list[list[str]] = []
    monkeypatch.setattr("scripts.harness_maintenance.existing_issue_url", lambda *_args: None)

    def fake_run(args, *, input_text=None):
        calls.append(args)
        return subprocess.CompletedProcess(args, 0, "https://github.com/YannJY02/AutoTranscribe/issues/99\n", "")

    monkeypatch.setattr("scripts.harness_maintenance._run", fake_run)

    enqueue(TASKS["feedback-promotion"], date(2026, 8, 25), dry_run=False)

    assert "needs-triage" in calls[-1]
    assert "ready-for-agent" not in calls[-1]


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


def test_macos_proxy_environment_uses_portable_bypass_entries(monkeypatch):
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
        "NO_PROXY": "127.0.0.1,localhost,*.local,169.254/16",
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


def test_symphony_launch_agent_retries_one_failed_bootstrap(tmp_path, monkeypatch):
    repo = tmp_path / "repo"
    launcher = repo / "scripts" / "run_symphony.sh"
    launcher.parent.mkdir(parents=True)
    launcher.write_text("#!/bin/sh\n", encoding="utf-8")
    (repo / "WORKFLOW.md").write_text("# test\n", encoding="utf-8")
    monkeypatch.setattr(
        "scripts.harness_maintenance.shutil.which",
        lambda command: f"/tools/{command}",
    )
    monkeypatch.setattr(
        "scripts.harness_maintenance.subprocess.run",
        lambda *args, **kwargs: subprocess.CompletedProcess(args[0], 0, "", ""),
    )
    transient = (
        "Bootstrap failed: 5: Input/output error\n"
        "Try re-running the command as root for richer errors."
    )
    bootstraps = 0

    def fake_run(command, *, input_text=None):
        nonlocal bootstraps
        bootstraps += 1
        if bootstraps == 1:
            raise RuntimeError(transient)
        return subprocess.CompletedProcess(command, 0, "", "")

    monkeypatch.setattr("scripts.harness_maintenance._run", fake_run)
    sleeps = []
    monkeypatch.setattr("scripts.harness_maintenance.time.sleep", sleeps.append)

    install_symphony_launch_agent(
        repo,
        load=True,
        launch_agents_dir=tmp_path / "LaunchAgents",
    )

    assert bootstraps == 2
    assert sleeps == [1]


def test_bootstrap_retry_requires_exact_error_and_stops_after_three_attempts(tmp_path, monkeypatch):
    transient = (
        "Bootstrap failed: 5: Input/output error\n"
        "Try re-running the command as root for richer errors."
    )
    attempts = 0

    def fail_with_extra_context(command, *, input_text=None):
        nonlocal attempts
        attempts += 1
        raise RuntimeError(f"{transient}\nPermission denied")

    monkeypatch.setattr("scripts.harness_maintenance._run", fail_with_extra_context)
    with pytest.raises(RuntimeError, match="Permission denied"):
        _bootstrap_launch_agent("gui/501", tmp_path / "agent.plist")
    assert attempts == 1

    def fail_transiently(command, *, input_text=None):
        nonlocal attempts
        attempts += 1
        raise RuntimeError(transient)

    attempts = 0
    sleeps = []
    monkeypatch.setattr("scripts.harness_maintenance.time.sleep", sleeps.append)
    monkeypatch.setattr("scripts.harness_maintenance._run", fail_transiently)
    with pytest.raises(RuntimeError, match="Input/output error"):
        _bootstrap_launch_agent("gui/501", tmp_path / "agent.plist")
    assert attempts == 3
    assert sleeps == [1, 1]


def test_maintenance_launch_agent_uses_shared_bootstrap(tmp_path, monkeypatch):
    repo = tmp_path / "repo"
    script = repo / "scripts" / "harness_maintenance.py"
    script.parent.mkdir(parents=True)
    script.write_text("# test\n", encoding="utf-8")
    monkeypatch.setattr("scripts.harness_maintenance.shutil.which", lambda _command: "/tools/python3.11")
    monkeypatch.setattr(
        "scripts.harness_maintenance.subprocess.run",
        lambda *args, **kwargs: subprocess.CompletedProcess(args[0], 0, "", ""),
    )
    bootstraps = []
    monkeypatch.setattr(
        "scripts.harness_maintenance._bootstrap_launch_agent",
        lambda domain, destination: bootstraps.append((domain, destination)),
    )

    destination = install_launch_agent(
        repo,
        load=True,
        launch_agents_dir=tmp_path / "LaunchAgents",
    )

    assert bootstraps == [(f"gui/{os.getuid()}", destination)]


def _fake_symphony_commands(tmp_path, *, symphony_body=None, curl_body=None, gh_body=None):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    commands = {
        "python3.11": "#!/bin/sh\nexit 0\n",
        "codex": '#!/bin/sh\n[ "${FAKE_CODEX_LOGIN_VALID:-1}" = 1 ] || exit 1\nprintf "%s\\n" "${FAKE_CODEX_LOGIN_STATUS:-Logged in using ChatGPT}" >&2\n',
        "gh": gh_body or "#!/bin/sh\nexit 0\n",
        "symphony": symphony_body
        or '#!/bin/sh\nprintf "%s|%s\\n" "$CODEX_HOME" "${OPENAI_API_KEY-unset}"\n',
        "curl": curl_body or "#!/bin/sh\nexit 0\n",
    }
    for name, body in commands.items():
        command = bin_dir / name
        command.write_text(body, encoding="utf-8")
        command.chmod(0o755)
    return bin_dir


def _run_test_symphony_launcher(
    tmp_path,
    *,
    create_auth=True,
    symphony_body=None,
    curl_body=None,
    gh_body=None,
    **extra_env,
):
    root = tmp_path / "home"
    auth = root / ".codex" / "auth.json"
    auth.parent.mkdir(parents=True)
    if create_auth:
        auth.write_text(json.dumps({"auth_mode": "chatgpt"}), encoding="utf-8")
    bin_dir = _fake_symphony_commands(
        tmp_path,
        symphony_body=symphony_body,
        curl_body=curl_body,
        gh_body=gh_body,
    )
    repo = Path(__file__).resolve().parent.parent
    env = os.environ.copy()
    env.pop("SYMPHONY_CODEX_HOME", None)
    env.update(
        {
            "HOME": str(root),
            "CODEX_HOME": str(root / ".codex"),
            "PATH": f"{bin_dir}:/usr/bin:/bin",
            "SYMPHONY_GITHUB_TOKEN": "tracker-token",
            "OPENAI_API_KEY": "must-be-unset",
            "SYMPHONY_HEALTH_STARTUP_SECONDS": "0.05",
            "SYMPHONY_HEALTH_INTERVAL_SECONDS": "1",
            **extra_env,
        }
    )
    completed = subprocess.run(
        ["/bin/sh", str(repo / "scripts" / "run_symphony.sh")],
        cwd=repo,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    return completed, root


def test_symphony_launcher_defaults_to_minimal_isolated_codex_home(tmp_path):
    completed, root = _run_test_symphony_launcher(tmp_path)
    runtime = root / "Library" / "Application Support" / "InsightKit" / "SymphonyCodex"

    assert completed.returncode == 0, completed.stderr
    assert completed.stdout.strip() == f"{runtime}|unset"
    assert (runtime / "auth.json").is_symlink()
    assert (runtime / "auth.json").resolve() == root / ".codex" / "auth.json"
    config = tomllib.loads((runtime / "config.toml").read_text(encoding="utf-8"))
    assert config["features"] == {"apps": False, "plugins": False, "remote_plugin": False}


def test_symphony_launcher_preserves_explicit_codex_home(tmp_path):
    override = tmp_path / "custom-codex-home"
    override.mkdir()
    (override / "auth.json").write_text("custom-login", encoding="utf-8")
    (override / "config.toml").write_text("model = 'custom'\n", encoding="utf-8")

    completed, _root = _run_test_symphony_launcher(tmp_path, SYMPHONY_CODEX_HOME=str(override))

    assert completed.returncode == 0, completed.stderr
    assert completed.stdout.strip() == f"{override}|unset"
    assert (override / "config.toml").read_text(encoding="utf-8") == "model = 'custom'\n"


def test_symphony_launcher_fails_without_chatgpt_login(tmp_path):
    completed, root = _run_test_symphony_launcher(tmp_path, create_auth=False)

    assert completed.returncode != 0
    assert completed.stdout == ""
    assert completed.stderr.strip() == f"Codex ChatGPT login is required at: {root}/.codex/auth.json"


def test_symphony_launcher_rejects_copied_auth(tmp_path):
    runtime = tmp_path / "home" / "Library" / "Application Support" / "InsightKit" / "SymphonyCodex"
    runtime.mkdir(parents=True)
    (runtime / "auth.json").write_text("copied-login", encoding="utf-8")

    completed, _root = _run_test_symphony_launcher(tmp_path)

    assert completed.returncode != 0
    assert "auth must be a link, not a copied file" in completed.stderr


def test_symphony_launcher_rejects_wrong_auth_link(tmp_path):
    runtime = tmp_path / "home" / "Library" / "Application Support" / "InsightKit" / "SymphonyCodex"
    runtime.mkdir(parents=True)
    wrong_auth = tmp_path / "wrong-auth.json"
    wrong_auth.write_text("wrong-login", encoding="utf-8")
    (runtime / "auth.json").symlink_to(wrong_auth)

    completed, root = _run_test_symphony_launcher(tmp_path)

    assert completed.returncode != 0
    assert completed.stderr.strip() == f"Symphony Codex auth must link to: {root}/.codex/auth.json"


def test_symphony_launcher_replaces_config_link_without_following_it(tmp_path):
    runtime = tmp_path / "home" / "Library" / "Application Support" / "InsightKit" / "SymphonyCodex"
    runtime.mkdir(parents=True)
    operator_config = tmp_path / "operator-config.toml"
    operator_config.write_text("model = 'keep-me'\n", encoding="utf-8")
    (runtime / "config.toml").symlink_to(operator_config)

    completed, _root = _run_test_symphony_launcher(tmp_path)

    assert completed.returncode == 0, completed.stderr
    assert operator_config.read_text(encoding="utf-8") == "model = 'keep-me'\n"
    assert not (runtime / "config.toml").is_symlink()


def test_symphony_launcher_reports_invalid_chatgpt_login(tmp_path):
    completed, _root = _run_test_symphony_launcher(tmp_path, FAKE_CODEX_LOGIN_VALID="0")

    assert completed.returncode != 0
    assert "does not contain a valid ChatGPT login" in completed.stderr


def test_symphony_launcher_rejects_api_key_login(tmp_path):
    completed, _root = _run_test_symphony_launcher(
        tmp_path,
        FAKE_CODEX_LOGIN_STATUS="Logged in using an API key",
    )

    assert completed.returncode != 0
    assert completed.stderr.strip() == "Symphony requires ChatGPT login; API-key authentication is not allowed."


def test_symphony_launcher_times_out_stalled_github_preflight(tmp_path):
    completed, _root = _run_test_symphony_launcher(
        tmp_path,
        gh_body="#!/bin/sh\nsleep 2\n",
        SYMPHONY_PREFLIGHT_TIMEOUT_SECONDS="1",
    )

    assert completed.returncode != 0
    assert completed.stderr.strip().endswith(
        "Codex's GitHub CLI session is not authenticated. Run: gh auth login"
    )


def test_symphony_launcher_rejects_github_preflight_exec_failure(tmp_path):
    completed, _root = _run_test_symphony_launcher(
        tmp_path,
        gh_body="#!/missing/interpreter\n",
    )

    assert completed.returncode != 0
    assert completed.stderr.strip().endswith(
        "Codex's GitHub CLI session is not authenticated. Run: gh auth login"
    )


def test_symphony_launcher_stops_an_unhealthy_child_for_launchd_restart(tmp_path):
    completed, _root = _run_test_symphony_launcher(
        tmp_path,
        symphony_body=(
            "#!/bin/sh\n"
            "trap '' TERM INT\n"
            "while :; do sleep 1; done\n"
        ),
        curl_body="#!/bin/sh\nexit 22\n",
        SYMPHONY_HEALTH_STARTUP_SECONDS="0",
        SYMPHONY_HEALTH_INTERVAL_SECONDS="1",
        SYMPHONY_HEALTH_FAILURE_LIMIT="2",
        SYMPHONY_TERMINATION_GRACE_SECONDS="0",
    )

    assert completed.returncode != 0
    assert "health probe failed 2 consecutive times" in completed.stderr


def test_symphony_launcher_rejects_invalid_port(tmp_path):
    completed, _root = _run_test_symphony_launcher(tmp_path, SYMPHONY_PORT="4000/path")

    assert completed.returncode != 0
    assert completed.stderr.strip() == "SYMPHONY_PORT must be an integer from 1 to 65535."


def test_symphony_launcher_rejects_zero_health_interval_and_timeout(tmp_path):
    for variable in ("SYMPHONY_HEALTH_INTERVAL_SECONDS", "SYMPHONY_HEALTH_TIMEOUT_SECONDS"):
        for zero in ("0", "00"):
            case_root = tmp_path / f"{variable.lower()}-{zero}"
            case_root.mkdir()
            completed, _root = _run_test_symphony_launcher(case_root, **{variable: zero})

            assert completed.returncode != 0
            assert completed.stderr.strip() == (
            "Symphony health interval and timeout must be positive integers."
        )


def test_symphony_launcher_rejects_all_zero_health_failure_limit(tmp_path):
    completed, _root = _run_test_symphony_launcher(
        tmp_path,
        SYMPHONY_HEALTH_FAILURE_LIMIT="00",
    )

    assert completed.returncode != 0
    assert completed.stderr.strip() == (
        "SYMPHONY_HEALTH_FAILURE_LIMIT must be a positive integer."
    )


def test_symphony_workflow_hands_read_only_git_delivery_to_controller():
    workflow = (Path(__file__).resolve().parent.parent / "WORKFLOW.md").read_text(encoding="utf-8")

    assert "do not create temporary Git metadata" in workflow
    assert "controller handoff" in workflow


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
