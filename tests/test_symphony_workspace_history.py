"""Exercise workspace preparation using real Git transport and a local remote."""

from __future__ import annotations

import os
import shlex
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
REMOTE_URL = "https://github.com/YannJY02/AutoTranscribe.git"


def workflow_hook(name: str) -> str:
    lines = (ROOT / "WORKFLOW.md").read_text().splitlines()
    start = lines.index(f"  {name}: |") + 1
    hook = []
    for line in lines[start:]:
        if not line.startswith("    "):
            break
        hook.append(line[4:])
    return "\n".join(hook)


def worker_history_command() -> list[str]:
    workflow = (ROOT / "WORKFLOW.md").read_text()
    command_line = next(line for line in workflow.splitlines() if line.startswith("  command: env "))
    command = shlex.split(command_line.removeprefix("  command: "))
    end = 1
    while command[end] == "-u":
        end += 2
    # Reuse the real worker credential projection; replace only the Codex binary
    # with a shell exercising the documented worker preparation command.
    refresh = workflow.split("```sh\n", 1)[1].split("```", 1)[0]
    refresh += '\ntest -z "${SYMPHONY_AGENT_GITHUB_TOKEN+x}${GITHUB_TOKEN+x}${GH_TOKEN+x}"\n'
    return command[:end] + ["/bin/sh", "-eu", "-c", refresh]


def git(root: Path, *args: str) -> str:
    return subprocess.run(
        ["git", *args], cwd=root, check=True, capture_output=True, text=True
    ).stdout.strip()


def local_remote(tmp_path: Path) -> tuple[Path, str, str]:
    source = tmp_path / "source"
    source.mkdir()
    git(source, "init", "--initial-branch=main")
    git(source, "config", "user.name", "Workspace History Test")
    git(source, "config", "user.email", "workspace@example.invalid")
    bootstrap = source / "scripts/agent_bootstrap.sh"
    bootstrap.parent.mkdir()
    bootstrap.write_text("#!/bin/sh\nexit 0\n")
    bootstrap.chmod(0o755)
    git(source, "add", ".")
    git(source, "commit", "-m", "historical source")
    historical = git(source, "rev-parse", "HEAD")
    (source / "main.txt").write_text("main successor\n")
    git(source, "add", ".")
    git(source, "commit", "-m", "main successor")
    git(source, "checkout", "-b", "bootstrap")
    (source / "bootstrap.txt").write_text("bootstrap successor\n")
    git(source, "add", ".")
    git(source, "commit", "-m", "bootstrap successor")
    bootstrap_revision = git(source, "rev-parse", "HEAD")
    git(source, "checkout", "main")
    return source, historical, bootstrap_revision


@pytest.mark.parametrize("bootstrap_ref", ["", "refs/heads/bootstrap"])
def test_after_create_preserves_history_for_sealed_evidence(tmp_path, bootstrap_ref):
    source, historical, bootstrap_revision = local_remote(tmp_path)
    workspace = tmp_path / "GH-101"
    workspace.mkdir()
    # The production hook restores the canonical origin URL. Redirect that exact
    # URL to our local remote so its optional bootstrap fetch never uses network.
    environment = os.environ | {
        "SYMPHONY_REPO_SOURCE": source.as_uri(),
        "SYMPHONY_BOOTSTRAP_REF": bootstrap_ref,
        "GIT_CONFIG_COUNT": "2",
        "GIT_CONFIG_KEY_0": f"url.{source.as_uri()}.insteadOf",
        "GIT_CONFIG_VALUE_0": REMOTE_URL,
        "GIT_CONFIG_KEY_1": "protocol.file.allow",
        "GIT_CONFIG_VALUE_1": "always",
    }
    subprocess.run(
        ["/bin/sh", "-eu", "-c", workflow_hook("after_create")],
        cwd=workspace, env=environment, check=True, capture_output=True, text=True,
    )

    assert git(workspace, "rev-parse", "--is-shallow-repository") == "false"
    assert git(workspace, "cat-file", "-t", historical) == "commit"
    if bootstrap_ref:
        assert git(workspace, "rev-parse", "HEAD") == bootstrap_revision


def test_legacy_shallow_worker_refresh_preserves_checkout_without_controller_credentials(tmp_path):
    source, historical, _ = local_remote(tmp_path)
    workspace = tmp_path / "GH-102"
    subprocess.run(
        ["git", "clone", "--depth", "1", "--no-local", source.as_uri(), str(workspace)],
        check=True, capture_output=True,
    )
    assert git(workspace, "rev-parse", "--is-shallow-repository") == "true"
    original_head = git(workspace, "rev-parse", "HEAD")
    changed_file = workspace / "main.txt"
    changed_file.write_text("preserve unfinished product work\n")
    environment = os.environ | {
        name: "synthetic-controller-credential"
        for name in ("SYMPHONY_AGENT_GITHUB_TOKEN", "GITHUB_TOKEN", "GH_TOKEN")
    }
    subprocess.run(
        worker_history_command(), cwd=workspace, env=environment,
        check=True, capture_output=True, text=True,
    )

    assert git(workspace, "rev-parse", "--is-shallow-repository") == "false"
    assert git(workspace, "cat-file", "-t", historical) == "commit"
    assert git(workspace, "rev-parse", "HEAD") == original_head
    assert changed_file.read_text() == "preserve unfinished product work\n"

    # A complete workspace needs no network refresh on the next turn.
    git(workspace, "remote", "remove", "origin")
    subprocess.run(
        worker_history_command(), cwd=workspace, env=environment,
        check=True, capture_output=True, text=True,
    )
