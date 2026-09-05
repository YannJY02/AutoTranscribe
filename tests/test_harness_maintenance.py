from __future__ import annotations

from datetime import date
import json
import os
from pathlib import Path
import plistlib
import pytest
import shlex
import subprocess
import sys
import time
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

    assert payload["ProgramArguments"] == ["/usr/bin/env", "-u", "OPENAI_API_KEY", "/bin/sh", str(launcher)]
    assert payload["WorkingDirectory"] == str(repo)
    assert payload["EnvironmentVariables"]["SYMPHONY_REPO_SOURCE"] == str(repo)
    assert payload["EnvironmentVariables"]["PATH"].split(":")[:3] == ["/first", "/tools", "/last"]
    assert "HTTPS_PROXY" not in payload["EnvironmentVariables"]
    assert "OPENAI_API_KEY" not in payload["EnvironmentVariables"]
    assert payload["KeepAlive"] is True
    assert payload["RunAtLoad"] is True
    assert "ProcessType" not in payload


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


def test_bootstrap_retry_requires_exact_error_and_is_bounded(tmp_path, monkeypatch):
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
    assert attempts == 20
    assert sleeps == [1] * 19


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


def _fake_symphony_commands(
    tmp_path, *, symphony_body=None, curl_body=None, gh_body=None, ps_body=None,
    python_body=None, security_body=None,
):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    commands = {
        "python3.11": python_body or (
            '#!/bin/sh\nif [ "${1:-}" = - ]; then exec '
            f'{shlex.quote(sys.executable)} "$@"; fi\n'
            'if [ "${6:-}" = blocked-pending ]; then exit 3; fi\nexit 0\n'
        ),
        "codex": (
            '#!/bin/sh\nif [ "${FAKE_CODEX_CHILD_IGNORES_TERM:-0}" = 1 ]; then '
            "trap 'exit 0' TERM; "
            "sh -c 'trap \"\" TERM; printf \"%s\\n\" \"$$\" > \"$FAKE_CODEX_CHILD_PID_FILE\"; exec sleep 3' & "
            "wait; fi\n"
            '[ "${FAKE_CODEX_IGNORE_ALARM:-0}" = 1 ] || { '
            '[ "${FAKE_CODEX_LOGIN_VALID:-1}" = 1 ] || exit 1; '
            'printf "%s\\n" "${FAKE_CODEX_LOGIN_STATUS:-Logged in using ChatGPT}" >&2; '
            'exit 0; }\ntrap "" ALRM\nsleep 3\n'
        ),
        "gh": gh_body or "#!/bin/sh\nexit 0\n",
        "symphony": symphony_body
        or '#!/bin/sh\nprintf "%s|%s\\n" "$CODEX_HOME" "${OPENAI_API_KEY-unset}"\n',
        "curl": curl_body or "#!/bin/sh\nexit 0\n",
        "security": security_body or "#!/bin/sh\nexit 1\n",
    }
    if ps_body is not None:
        commands["ps"] = ps_body
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
    ps_body=None,
    python_body=None,
    security_body=None,
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
        ps_body=ps_body,
        python_body=python_body,
        security_body=security_body,
    )
    repo = Path(__file__).resolve().parent.parent
    env = os.environ.copy()
    env.pop("SYMPHONY_CODEX_HOME", None)
    env.pop("SSL_CERT_FILE", None)
    env.update(
        {
            "HOME": str(root),
            "CODEX_HOME": str(root / ".codex"),
            "PATH": f"{bin_dir}:/usr/bin:/bin",
            "SYMPHONY_GITHUB_TOKEN": "tracker-token",
            "SYMPHONY_AGENT_GITHUB_TOKEN": "agent-token",
            "OPENAI_API_KEY": "must-be-unset",
            "SYMPHONY_HEALTH_STARTUP_SECONDS": "0.05",
            "SYMPHONY_HEALTH_INTERVAL_SECONDS": "1",
            "SYMPHONY_SECURITY": str(bin_dir / "security"),
            "SYMPHONY_PREFLIGHT_EVIDENCE_ROOT": str(tmp_path / "preflight"),
            "SYMPHONY_WORKSPACE_ROOT": str(tmp_path / "workspaces"),
            "SYMPHONY_LOGS_ROOT": str(tmp_path / "logs"),
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
        timeout=20,
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


def test_symphony_launcher_keeps_only_the_read_only_tracker_token(tmp_path):
    completed, _root = _run_test_symphony_launcher(
        tmp_path,
        symphony_body=(
            "#!/bin/sh\n"
            "printf '%s|%s|%s\\n' \"${GH_TOKEN-unset}\" \"${GITHUB_TOKEN-unset}\" "
            "\"${SYMPHONY_AGENT_GITHUB_TOKEN-unset}\"\n"
        ),
    )

    assert completed.returncode == 0, completed.stderr
    assert completed.stdout.strip() == "unset|tracker-token|unset"


def test_symphony_launcher_preserves_explicit_codex_home(tmp_path):
    override = tmp_path / "custom-codex-home"
    override.mkdir()
    (override / "auth.json").write_text("custom-login", encoding="utf-8")
    (override / "config.toml").write_text("model = 'custom'\n", encoding="utf-8")

    completed, _root = _run_test_symphony_launcher(tmp_path, SYMPHONY_CODEX_HOME=str(override))

    assert completed.returncode == 0, completed.stderr
    assert completed.stdout.strip() == f"{override}|unset"
    assert (override / "config.toml").read_text(encoding="utf-8") == "model = 'custom'\n"


def test_symphony_launcher_uses_readable_system_ca_bundle(tmp_path):
    completed, _root = _run_test_symphony_launcher(
        tmp_path,
        symphony_body='#!/bin/sh\nprintf "%s\\n" "${SSL_CERT_FILE-unset}"\n',
    )

    assert completed.returncode == 0, completed.stderr
    assert completed.stdout.strip() == "/etc/ssl/cert.pem"


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


def test_symphony_launcher_force_stops_preflight_that_ignores_alarm(tmp_path):
    started_at = time.monotonic()
    completed, _root = _run_test_symphony_launcher(
        tmp_path,
        FAKE_CODEX_IGNORE_ALARM="1",
        SYMPHONY_PREFLIGHT_TIMEOUT_SECONDS="1",
    )

    assert completed.returncode != 0
    assert time.monotonic() - started_at < 2.5
    assert "does not contain a valid ChatGPT login" in completed.stderr


def test_symphony_launcher_force_stops_term_ignoring_preflight_descendant(tmp_path):
    child_pid_file = tmp_path / "term-ignoring-child.pid"
    started_at = time.monotonic()
    completed, _root = _run_test_symphony_launcher(
        tmp_path,
        FAKE_CODEX_CHILD_IGNORES_TERM="1",
        FAKE_CODEX_CHILD_PID_FILE=str(child_pid_file),
        SYMPHONY_PREFLIGHT_TIMEOUT_SECONDS="1",
    )

    assert completed.returncode != 0
    assert time.monotonic() - started_at < 2.5
    child_pid = int(child_pid_file.read_text(encoding="utf-8"))
    with pytest.raises(ProcessLookupError):
        os.kill(child_pid, 0)
    assert "does not contain a valid ChatGPT login" in completed.stderr


def test_symphony_launcher_treats_zombie_only_preflight_group_as_terminated(tmp_path):
    ps_called = tmp_path / "ps-called"
    started_at = time.monotonic()
    completed, _root = _run_test_symphony_launcher(
        tmp_path,
        FAKE_CODEX_CHILD_IGNORES_TERM="1",
        FAKE_CODEX_CHILD_PID_FILE=str(tmp_path / "term-ignoring-child.pid"),
        SYMPHONY_PREFLIGHT_TIMEOUT_SECONDS="1",
        ps_body=(
            "#!/bin/sh\n"
            f"printf 'called\\n' >> {shlex.quote(str(ps_called))}\n"
            "printf 'Z\\n'\n"
        ),
    )

    assert ps_called.read_text(encoding="utf-8").splitlines() == ["called"]
    assert completed.returncode != 0
    assert time.monotonic() - started_at < 2.5


def test_symphony_agent_github_access_stays_outside_codex():
    root = Path(__file__).resolve().parent.parent
    workflow = (root / "WORKFLOW.md").read_text(encoding="utf-8")
    gate = (root / "scripts" / "symphony_issue_gate.sh").read_text(encoding="utf-8")
    after_run = (root / "scripts" / "symphony_after_run.sh").read_text(encoding="utf-8")
    launcher = (root / "scripts" / "run_symphony.sh").read_text(encoding="utf-8")
    codex_config = tomllib.loads((root / ".codex" / "symphony.config.toml").read_text(encoding="utf-8"))

    assert not (root / "scripts" / "symphony-bin" / "gh").exists()
    assert "hooks:" in workflow and "before_run:" in workflow
    assert "issue-preflight --json" in gate
    assert '"$SYMPHONY_REAL_GH" issue edit' in gate
    assert "agent-github-token" in gate
    assert "agent-github-token" in after_run
    assert "agent-github-token" not in launcher
    assert "env -u SYMPHONY_AGENT_GITHUB_TOKEN" in workflow
    assert "-u GITHUB_TOKEN -u GH_TOKEN" in workflow
    assert '"$SYMPHONY_CONTROLLER_REPO_ROOT/scripts/symphony-bin/codex"' in workflow
    assert 'PATH="$repo_root/scripts/symphony-bin:$PATH"' not in launcher
    assert codex_config["model"] == "gpt-6-astra"
    assert codex_config["model_reasoning_effort"] == "high"


def test_symphony_codex_wrapper_trusts_exact_workspace_before_start(tmp_path):
    repo = Path(__file__).resolve().parent.parent
    wrapper = repo / "scripts" / "symphony-bin" / "codex"
    workspace = tmp_path / "GH-67"
    workspace.mkdir()
    codex_home = tmp_path / "codex-home"
    codex_home.mkdir()
    (codex_home / "config.toml").write_text("[features]\napps = false\n", encoding="utf-8")
    fake_codex = tmp_path / "real-codex"
    fake_codex.write_text("#!/bin/sh\nprintf 'started\\n'\n", encoding="utf-8")
    fake_codex.chmod(0o755)
    env = os.environ.copy()
    env.update({"CODEX_HOME": str(codex_home), "SYMPHONY_REAL_CODEX": str(fake_codex)})

    completed = subprocess.run(
        [str(wrapper), "app-server"],
        cwd=workspace,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )

    assert completed.returncode == 0, completed.stderr
    assert completed.stdout == "started\n"
    config = tomllib.loads((codex_home / "config.toml").read_text(encoding="utf-8"))
    assert config["projects"][str(workspace)]["trust_level"] == "trusted"


def test_symphony_codex_wrapper_rejects_config_symlink_before_start(tmp_path):
    root = Path(__file__).resolve().parent.parent
    wrapper = root / "scripts" / "symphony-bin" / "codex"
    workspace = tmp_path / "GH-67"
    workspace.mkdir()
    codex_home = tmp_path / "codex-home"
    codex_home.mkdir()
    operator_config = tmp_path / "operator-config.toml"
    operator_config.write_text("model = 'keep-me'\n", encoding="utf-8")
    (codex_home / "config.toml").symlink_to(operator_config)
    started = tmp_path / "started"
    fake_codex = tmp_path / "real-codex"
    fake_codex.write_text(f"#!/bin/sh\ntouch {shlex.quote(str(started))}\n", encoding="utf-8")
    fake_codex.chmod(0o755)
    env = os.environ.copy()
    env.update({"CODEX_HOME": str(codex_home), "SYMPHONY_REAL_CODEX": str(fake_codex)})

    completed = subprocess.run(
        [str(wrapper), "app-server"], cwd=workspace, env=env, text=True, capture_output=True
    )

    assert completed.returncode != 0
    assert "Refusing to update linked Codex config" in completed.stderr
    assert not started.exists()
    assert operator_config.read_text(encoding="utf-8") == "model = 'keep-me'\n"


def test_symphony_codex_wrapper_serializes_workspace_trust_updates(tmp_path):
    root = Path(__file__).resolve().parent.parent
    wrapper = root / "scripts" / "symphony-bin" / "codex"
    codex_home = tmp_path / "codex-home"
    codex_home.mkdir()
    (codex_home / "config.toml").write_text("[features]\napps = false\n", encoding="utf-8")
    fake_codex = tmp_path / "real-codex"
    fake_codex.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    fake_codex.chmod(0o755)
    env = os.environ.copy()
    env.update({"CODEX_HOME": str(codex_home), "SYMPHONY_REAL_CODEX": str(fake_codex)})
    workspaces = [tmp_path / "GH-67", tmp_path / "GH-68"]
    for workspace in workspaces:
        workspace.mkdir()

    processes = [
        subprocess.Popen([str(wrapper), "app-server"], cwd=workspace, env=env)
        for workspace in workspaces
    ]

    assert [process.wait() for process in processes] == [0, 0]
    config = tomllib.loads((codex_home / "config.toml").read_text(encoding="utf-8"))
    assert set(config["projects"]) == {str(workspace) for workspace in workspaces}


def _symphony_issue_gate_environment(tmp_path):
    root = Path(__file__).resolve().parent.parent
    controller = tmp_path / "controller"
    (controller / "scripts").mkdir(parents=True)
    (controller / "scripts" / "agent_harness.py").write_text("# fake\n", encoding="utf-8")
    workspace = tmp_path / "GH-67"
    workspace.mkdir()
    evidence = tmp_path / "evidence"
    evidence.mkdir()
    # This fixture stubs preflight; the immutable base was captured by the host.
    (evidence / "GH-67.base").write_text("a" * 40 + "\n")
    preflight_args = tmp_path / "preflight-args"
    gh_args = tmp_path / "gh-args"
    fake_python = tmp_path / "python3.11"
    fake_python.write_text(
        "#!/bin/sh\n"
        f'if [ "${{1:-}}" = -c ]; then exec {shlex.quote(sys.executable)} "$@"; fi\n'
        'case "${1:-}" in */symphony_delivery_controller.py)\n'
        'printf "%s|%s|%s|%s\\n" "$6" "$PWD" "${GH_TOKEN-unset}" '
        '"$(cat "$SYMPHONY_PREFLIGHT_EVIDENCE_ROOT/GH-67.claimed" 2>/dev/null || true)" '
        '>> "$FAKE_ATTEMPT_CALLS"\n'
        'printf "%s\\n" "$@" > "$FAKE_ATTEMPT_ARGS"\n'
        'if [ "$6" = invalidate-attempt ]; then exit "${FAKE_INVALIDATE_EXIT:-0}"; fi\n'
        'exit "${FAKE_ATTEMPT_EXIT:-0}";; esac\n'
        'printf "%s\\n" "$@" > "$FAKE_PREFLIGHT_ARGS"\n'
        'status=${FAKE_PREFLIGHT_EXIT:-0}\n'
        'if [ "${FAKE_PREFLIGHT_EMPTY:-0}" != 1 ]; then '
        'if [ "$status" -eq 0 ]; then printf \'{"status":"passed","issue":"GH-67"}\\n\'; '
        'else printf \'{"status":"failed","issue":"GH-67"}\\n\'; fi; fi\n'
        'exit "$status"\n',
        encoding="utf-8",
    )
    fake_python.chmod(0o755)
    fake_gh = tmp_path / "gh"
    fake_gh.write_text(
        "#!/bin/sh\n"
        'printf "%s\\n" "$@" > "$FAKE_GH_ARGS"\n'
        'exit "${FAKE_GH_EXIT:-0}"\n',
        encoding="utf-8",
    )
    fake_gh.chmod(0o755)
    fake_security = tmp_path / "security"
    fake_security.write_text("#!/bin/sh\nprintf 'controller-token\\n'\n", encoding="utf-8")
    fake_security.chmod(0o755)
    env = os.environ.copy()
    env.pop("GH_TOKEN", None)
    env.update(
        {
            "SYMPHONY_CONTROLLER_REPO_ROOT": str(controller),
            "SYMPHONY_PREFLIGHT_EVIDENCE_ROOT": str(evidence),
            "SYMPHONY_PYTHON3": str(fake_python),
            "SYMPHONY_REAL_GH": str(fake_gh),
            "SYMPHONY_SECURITY": str(fake_security),
            "FAKE_PREFLIGHT_ARGS": str(preflight_args),
            "FAKE_GH_ARGS": str(gh_args),
            "FAKE_ATTEMPT_ARGS": str(tmp_path / "attempt-args"),
            "FAKE_ATTEMPT_CALLS": str(tmp_path / "attempt-calls"),
        }
    )
    return root / "scripts" / "symphony_issue_gate.sh", workspace, evidence, env


def test_symphony_issue_gate_binds_new_attempt_after_claim_without_write_token(tmp_path):
    gate, workspace, evidence, env = _symphony_issue_gate_environment(tmp_path)

    completed = subprocess.run([str(gate)], cwd=workspace, env=env, text=True, capture_output=True)

    assert completed.returncode == 0, completed.stderr
    controller = env["SYMPHONY_CONTROLLER_REPO_ROOT"]
    assert Path(env["FAKE_ATTEMPT_CALLS"]).read_text().splitlines() == [
        f"invalidate-attempt|{controller}|unset|",
        f"begin-attempt|{controller}|unset|claimed",
    ]
    assert Path(env["FAKE_ATTEMPT_ARGS"]).read_text().splitlines() == [
        f"{controller}/scripts/symphony_delivery_controller.py",
        "--preflight-root", str(evidence), "--gh", env["SYMPHONY_REAL_GH"],
        "begin-attempt", "--workspace", str(workspace),
    ]


@pytest.mark.parametrize("failure", ["FAKE_INVALIDATE_EXIT", "FAKE_ATTEMPT_EXIT"])
def test_symphony_issue_gate_attempt_failure_prevents_worker_start(tmp_path, failure):
    gate, workspace, _evidence, env = _symphony_issue_gate_environment(tmp_path)
    env[failure] = "2"

    completed = subprocess.run([str(gate)], cwd=workspace, env=env, text=True, capture_output=True)

    assert completed.returncode == 2
    if failure == "FAKE_INVALIDATE_EXIT":
        assert not Path(env["FAKE_PREFLIGHT_ARGS"]).exists()
        assert not Path(env["FAKE_GH_ARGS"]).exists()


def test_symphony_issue_gate_claims_once_then_resumes(tmp_path):
    gate, workspace, evidence, env = _symphony_issue_gate_environment(tmp_path)

    first = subprocess.run([str(gate)], cwd=workspace, env=env, text=True, capture_output=True)
    first_args = Path(env["FAKE_PREFLIGHT_ARGS"]).read_text(encoding="utf-8")
    second = subprocess.run([str(gate)], cwd=workspace, env=env, text=True, capture_output=True)
    second_args = Path(env["FAKE_PREFLIGHT_ARGS"]).read_text(encoding="utf-8")

    assert first.returncode == 0, first.stderr
    assert "--resume" not in first_args
    assert second.returncode == 0, second.stderr
    assert "--resume" in second_args
    assert (evidence / "GH-67.claimed").exists()
    assert json.loads((evidence / "GH-67.json").read_text(encoding="utf-8"))["status"] == "passed"


def test_symphony_issue_gate_preserves_preflight_failure_evidence(tmp_path):
    gate, workspace, evidence, env = _symphony_issue_gate_environment(tmp_path)
    env["FAKE_PREFLIGHT_EXIT"] = "9"

    completed = subprocess.run([str(gate)], cwd=workspace, env=env, text=True, capture_output=True)

    assert completed.returncode == 9
    assert json.loads((evidence / "GH-67.json").read_text(encoding="utf-8"))["status"] == "failed"
    assert not Path(env["FAKE_GH_ARGS"]).exists()
    assert not (evidence / "GH-67.claimed").exists()


def test_symphony_issue_gate_replaces_empty_preflight_failure_with_json(tmp_path):
    gate, workspace, evidence, env = _symphony_issue_gate_environment(tmp_path)
    env.update({"FAKE_PREFLIGHT_EXIT": "9", "FAKE_PREFLIGHT_EMPTY": "1"})

    completed = subprocess.run([str(gate)], cwd=workspace, env=env, text=True, capture_output=True)

    assert completed.returncode == 9
    result = json.loads((evidence / "GH-67.json").read_text(encoding="utf-8"))
    assert result == {"status": "failed", "stage": "preflight", "issue": "GH-67", "exit_code": 9}


def test_symphony_issue_gate_recovers_from_ambiguous_assignment_failure(tmp_path):
    gate, workspace, evidence, env = _symphony_issue_gate_environment(tmp_path)
    env["FAKE_GH_EXIT"] = "1"

    completed = subprocess.run([str(gate)], cwd=workspace, env=env, text=True, capture_output=True)

    assert completed.returncode == 1
    result = json.loads((evidence / "GH-67.json").read_text(encoding="utf-8"))
    assert result == {"status": "failed", "stage": "assignment", "issue": "GH-67"}
    assert (evidence / "GH-67.claimed").read_text(encoding="utf-8") == "pending\n"

    env["FAKE_GH_EXIT"] = "0"
    resumed = subprocess.run([str(gate)], cwd=workspace, env=env, text=True, capture_output=True)

    assert resumed.returncode == 0, resumed.stderr
    assert "--resume" in Path(env["FAKE_PREFLIGHT_ARGS"]).read_text(encoding="utf-8")
    assert (evidence / "GH-67.claimed").read_text(encoding="utf-8") == "claimed\n"


def test_symphony_issue_gate_recovers_after_assignment_before_marker_finalize(tmp_path):
    gate, workspace, evidence, env = _symphony_issue_gate_environment(tmp_path)
    (evidence / "GH-67.claimed").write_text("pending\n", encoding="utf-8")

    completed = subprocess.run([str(gate)], cwd=workspace, env=env, text=True, capture_output=True)

    assert completed.returncode == 0, completed.stderr
    assert "--resume" in Path(env["FAKE_PREFLIGHT_ARGS"]).read_text(encoding="utf-8")


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
    started_at = time.monotonic()
    completed, _root = _run_test_symphony_launcher(
        tmp_path,
        symphony_body=(
            "#!/bin/sh\n"
            "trap '' TERM INT\n"
            "exec sleep 60\n"
        ),
        curl_body="#!/bin/sh\nexit 22\n",
        ps_body="#!/bin/sh\nprintf 'S\\n'\n",
        SYMPHONY_HEALTH_STARTUP_SECONDS="0",
        SYMPHONY_HEALTH_INTERVAL_SECONDS="1",
        SYMPHONY_HEALTH_FAILURE_LIMIT="2",
        SYMPHONY_TERMINATION_GRACE_SECONDS="0",
    )

    assert completed.returncode != 0
    assert time.monotonic() - started_at < 10
    assert "health probe failed 2 consecutive times" in completed.stderr


def _blocked_controller_python():
    return f'''#!{sys.executable}
import json
import os
from pathlib import Path
import sys
import time

if sys.argv[1] in ("-", "-c"):
    os.execv(sys.executable, [sys.executable, *sys.argv[1:]])
if sys.argv[1].endswith("symphony_delivery_controller.py"):
    command = sys.argv[6]
elif sys.argv[1].endswith("agent_harness.py") and sys.argv[2] == "runtime-status":
    command = "runtime-status"
else:
    raise SystemExit(0)
with Path(os.environ["FAKE_CONTROLLER_EVENTS"]).open("a") as stream:
    stream.write(json.dumps({{"command": command, "args": sys.argv[1:],
        "cwd": str(Path.cwd()), "gh_token": bool(os.environ.get("GH_TOKEN"))}}) + "\\n")
if command == "blocked-pending":
    raise SystemExit(int(os.environ.get("FAKE_PENDING_EXIT", "3")))
if command == "blocked-sweep":
    time.sleep(float(os.environ.get("FAKE_SWEEP_DELAY", "0")))
    raise SystemExit(int(os.environ.get("FAKE_SWEEP_EXIT", "0")))
'''


def _blocked_controller_security():
    return f'''#!{sys.executable}
import json
import os
from pathlib import Path
with Path(os.environ["FAKE_CONTROLLER_EVENTS"]).open("a") as stream:
    stream.write(json.dumps({{"command": "security", "cwd": str(Path.cwd())}}) + "\\n")
print("fixture-controller-token")
'''


def _controller_events(path):
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def _blocked_shell_environment(tmp_path):
    root = Path(__file__).resolve().parent.parent
    controller = tmp_path / "trusted controller"
    (controller / "scripts").mkdir(parents=True)
    workspace_root = tmp_path / "worker workspaces"
    workspace = workspace_root / "GH-67"
    workspace.mkdir(parents=True)
    bin_dir = tmp_path / "trusted tools"
    bin_dir.mkdir()
    for name, body in (
        ("python3.11", _blocked_controller_python()),
        ("security", _blocked_controller_security()),
    ):
        script = bin_dir / name
        script.write_text(body)
        script.chmod(0o755)
    evidence = tmp_path / "preflight"
    evidence.mkdir()
    events = tmp_path / "controller-events.jsonl"
    env = os.environ.copy()
    env.pop("GH_TOKEN", None)
    env.update({
        "SYMPHONY_CONTROLLER_REPO_ROOT": str(controller),
        "SYMPHONY_PREFLIGHT_EVIDENCE_ROOT": str(evidence),
        "SYMPHONY_WORKSPACE_ROOT": str(workspace_root),
        "SYMPHONY_PYTHON3": str(bin_dir / "python3.11"),
        "SYMPHONY_REAL_GH": str(bin_dir / "gh"),
        "SYMPHONY_SECURITY": str(bin_dir / "security"),
        "FAKE_CONTROLLER_EVENTS": str(events),
    })
    return root / "scripts" / "symphony_after_run.sh", workspace, events, env


@pytest.mark.parametrize("pending,sweep,expected", [(3, 0, 0), (2, 0, 2), (0, 0, 0), (0, 2, 2)])
def test_symphony_blocked_sweep_reads_credential_only_for_pending_report(
    tmp_path, pending, sweep, expected
):
    hook, workspace, events_path, env = _blocked_shell_environment(tmp_path)
    env.update({"FAKE_PENDING_EXIT": str(pending), "FAKE_SWEEP_EXIT": str(sweep)})

    completed = subprocess.run(
        [str(hook), "--blocked-sweep"], cwd=workspace.parent, env=env,
        text=True, capture_output=True,
    )

    assert completed.returncode == expected, completed.stderr
    events = _controller_events(events_path)
    assert [event["command"] for event in events] == (
        ["blocked-pending", "security", "blocked-sweep"] if pending == 0 else ["blocked-pending"]
    )
    assert all(event["cwd"] == env["SYMPHONY_CONTROLLER_REPO_ROOT"] for event in events)
    assert events[0]["gh_token"] is False
    expected_args = [
        f'{env["SYMPHONY_CONTROLLER_REPO_ROOT"]}/scripts/symphony_delivery_controller.py',
        "--preflight-root", env["SYMPHONY_PREFLIGHT_EVIDENCE_ROOT"],
        "--gh", env["SYMPHONY_REAL_GH"], "blocked-pending",
        "--workspace-root", str(workspace.parent),
    ]
    assert events[0]["args"] == expected_args
    if pending == 0:
        assert events[-1]["gh_token"] is True
        expected_args[5] = "blocked-sweep"
        assert events[-1]["args"] == expected_args


def test_symphony_after_run_keeps_existing_workspace_delivery(tmp_path):
    hook, workspace, events_path, env = _blocked_shell_environment(tmp_path)
    empty = subprocess.run([str(hook)], cwd=workspace, env=env, text=True, capture_output=True)
    assert empty.returncode == 0, empty.stderr
    assert _controller_events(events_path) == []
    (workspace / ".symphony").mkdir()
    (workspace / ".symphony" / "handoff.json").write_text("{}")

    completed = subprocess.run([str(hook)], cwd=workspace, env=env, text=True, capture_output=True)

    assert completed.returncode == 0, completed.stderr
    events = _controller_events(events_path)
    assert [event["command"] for event in events] == ["security", "after-run"]
    assert events[-1]["args"][-3:] == ["after-run", "--workspace", str(workspace)]
    assert events[-1]["cwd"] == env["SYMPHONY_CONTROLLER_REPO_ROOT"]
    assert events[-1]["gh_token"] is True


def test_symphony_after_run_rejects_unknown_mode_without_credential(tmp_path):
    hook, workspace, events_path, env = _blocked_shell_environment(tmp_path)

    completed = subprocess.run(
        [str(hook), "--unknown"], cwd=workspace, env=env, text=True, capture_output=True
    )

    assert completed.returncode == 2
    assert _controller_events(events_path) == []


@pytest.mark.parametrize("sweep_exit,sweep_delay", [(0, "0"), (2, "0"), (0, "30")])
def test_symphony_launcher_sweeps_each_healthy_cycle_and_bounds_failure(
    tmp_path, sweep_exit, sweep_delay
):
    events_path = tmp_path / "controller-events.jsonl"
    # Two observed cycles prove the sweep is periodic and a failed/timed-out
    # controller does not stop the otherwise healthy resident process.
    ps_counter = tmp_path / "process-checks"
    completed, _root = _run_test_symphony_launcher(
        tmp_path,
        symphony_body="#!/bin/sh\nexit 0\n",
        ps_body=(
            "#!/bin/sh\n"
            'if [ "${1:-}" != -p ]; then exit 0; fi\n'
            f"counter={shlex.quote(str(ps_counter))}\n"
            'count=$(cat "$counter" 2>/dev/null || printf 0)\n'
            'count=$((count + 1)); printf "%s\\n" "$count" > "$counter"\n'
            '[ "$count" -le 2 ] && printf "S\\n"\nexit 0\n'
        ),
        python_body=_blocked_controller_python(),
        security_body=_blocked_controller_security(),
        FAKE_CONTROLLER_EVENTS=str(events_path),
        FAKE_PENDING_EXIT="0",
        FAKE_SWEEP_EXIT=str(sweep_exit),
        FAKE_SWEEP_DELAY=sweep_delay,
        SYMPHONY_PREFLIGHT_TIMEOUT_SECONDS="1",
    )

    assert completed.returncode == 0, completed.stderr
    events = _controller_events(events_path)
    commands = [event["command"] for event in events]
    assert commands.count("blocked-pending") == 2
    assert commands.count("blocked-sweep") == 2
    assert commands.count("runtime-status") == 2
    assert all(
        not event["gh_token"] for event in events
        if event["command"] in ("blocked-pending", "runtime-status")
    )
    if sweep_exit or sweep_delay != "0":
        assert completed.stderr.count("Symphony blocked handoff sweep failed") == 2
    else:
        assert "Symphony blocked handoff sweep failed" not in completed.stderr


def test_symphony_launcher_skips_blocked_sweep_when_health_probe_fails(tmp_path):
    events_path = tmp_path / "controller-events.jsonl"
    completed, _root = _run_test_symphony_launcher(
        tmp_path,
        symphony_body="#!/bin/sh\nexec sleep 60\n",
        curl_body="#!/bin/sh\nexit 22\n",
        python_body=_blocked_controller_python(),
        security_body=_blocked_controller_security(),
        FAKE_CONTROLLER_EVENTS=str(events_path),
        FAKE_PENDING_EXIT="0",
        SYMPHONY_HEALTH_FAILURE_LIMIT="1",
        SYMPHONY_TERMINATION_GRACE_SECONDS="0",
    )

    assert completed.returncode != 0
    assert [event["command"] for event in _controller_events(events_path)] == ["runtime-status"]


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
    assert "env -u SYMPHONY_AGENT_GITHUB_TOKEN -u SYMPHONY_GITHUB_TOKEN" in workflow


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
