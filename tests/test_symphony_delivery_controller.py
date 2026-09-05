from __future__ import annotations

import json
import hashlib
import os
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

from scripts.agent_harness import changes_sha256
from scripts.symphony_delivery_controller import (
    DeliveryController,
    DeliveryError,
    branch_name,
    load_delivery_context,
    render_pull_request_body,
    should_process,
    read_worker_file,
)


def _git(*args: str, cwd: Path) -> str:
    result = subprocess.run(["git", *args], cwd=cwd, text=True, capture_output=True, check=True)
    return result.stdout.strip()


def _workspace(tmp_path: Path) -> tuple[Path, Path, Path]:
    workspace = tmp_path / "GH-95"
    workspace.mkdir()
    _git("init", "-b", "main", cwd=workspace)
    _git("config", "user.name", "Harness Test", cwd=workspace)
    _git("config", "user.email", "harness@example.invalid", cwd=workspace)
    (workspace / ".gitignore").write_text(".symphony/\nlogs/\n", encoding="utf-8")
    (workspace / "feature.txt").write_text("before\n", encoding="utf-8")
    _git("add", ".gitignore", "feature.txt", cwd=workspace)
    _git("commit", "-m", "base", cwd=workspace)
    _git("clone", "--no-local", str(workspace), str(tmp_path / "source"), cwd=tmp_path)
    (workspace / "feature.txt").write_text("after\n", encoding="utf-8")

    manifest = {
        "schema_version": 1,
        "status": "passed",
        "issue": 95,
        "workspace": str(workspace),
        "changed_files": ["feature.txt"],
        "changes_sha256": changes_sha256(workspace, ["feature.txt"]),
        "mode": "full",
        "gates": [{"name": "diff-check", "status": "passed", "commands": []}],
    }
    worker_manifest = workspace / "logs" / "harness" / "run" / "manifest.json"
    worker_manifest.parent.mkdir(parents=True)
    worker_manifest.write_text(json.dumps(manifest), encoding="utf-8")
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
    (preflight_root / "GH-95.base").write_text(_git("rev-parse", "HEAD", cwd=workspace))
    (preflight_root / "GH-95.json").write_text(
        json.dumps(
            {
                "status": "passed",
                "issue": 95,
                "linear_issue": "YAN-62",
                "body_sha256": hashlib.sha256(b"contract").hexdigest(),
                "url": "https://github.com/YannJY02/AutoTranscribe/issues/95",
                "resource_class": "isolated",
                "blockers": [],
                "errors": [],
            }
        ),
        encoding="utf-8",
    )
    return workspace, preflight_root, worker_manifest


def test_load_delivery_context_requires_passed_manifest_and_exact_current_diff(tmp_path: Path):
    workspace, preflight_root, verified_manifest = _workspace(tmp_path)

    context = load_delivery_context(workspace, preflight_root)

    assert context.issue_number == 95
    assert context.linear_issue == "YAN-62"
    assert context.changed_files == ("feature.txt",)
    assert context.gates == ("diff-check",)
    assert branch_name(context) == "codex/gh-95-yan-62"


def test_load_delivery_context_rejects_manifest_escape(tmp_path: Path):
    workspace, preflight_root, verified_manifest = _workspace(tmp_path)
    handoff_path = workspace / ".symphony" / "handoff.json"
    handoff = json.loads(handoff_path.read_text(encoding="utf-8"))
    handoff["manifest"] = "../outside.json"
    handoff_path.write_text(json.dumps(handoff), encoding="utf-8")

    with pytest.raises(DeliveryError, match="manifest must stay inside the workspace"):
        load_delivery_context(workspace, preflight_root)


def test_load_delivery_context_rejects_unknown_schema_version(tmp_path: Path):
    workspace, preflight_root, verified_manifest = _workspace(tmp_path)
    handoff_path = workspace / ".symphony" / "handoff.json"
    handoff = json.loads(handoff_path.read_text(encoding="utf-8"))
    handoff["schema_version"] = 2
    handoff_path.write_text(json.dumps(handoff), encoding="utf-8")

    with pytest.raises(DeliveryError, match="schema version"):
        load_delivery_context(workspace, preflight_root)


def test_snapshot_never_delivers_unreported_files(tmp_path: Path):
    workspace, preflight_root, verified_manifest = _workspace(tmp_path)
    (workspace / "extra.txt").write_text("not verified\n", encoding="utf-8")

    context = load_delivery_context(workspace, preflight_root)
    controller = DeliveryController(preflight_root=preflight_root, repository="YannJY02/AutoTranscribe", gh="gh", source=tmp_path / "source")
    snapshot = controller._snapshot(context, tmp_path / "snapshot", {})
    assert not (snapshot.workspace / "extra.txt").exists()


def test_load_delivery_context_rejects_changed_bytes_at_an_already_verified_path(tmp_path: Path):
    workspace, preflight_root, verified_manifest = _workspace(tmp_path)
    (workspace / "feature.txt").write_text("changed after verification\n", encoding="utf-8")

    context = load_delivery_context(workspace, preflight_root)
    controller = DeliveryController(preflight_root=preflight_root, repository="YannJY02/AutoTranscribe", gh="gh", source=tmp_path / "source")
    with pytest.raises(DeliveryError, match="verified file contents"):
        controller._snapshot(context, tmp_path / "snapshot", {})


def test_load_delivery_context_rejects_quick_harness_manifest(tmp_path: Path):
    workspace, preflight_root, verified_manifest = _workspace(tmp_path)
    manifest = json.loads(verified_manifest.read_text(encoding="utf-8"))
    manifest["mode"] = "quick"
    verified_manifest.write_text(json.dumps(manifest), encoding="utf-8")

    with pytest.raises(DeliveryError, match="full-mode"):
        load_delivery_context(workspace, preflight_root)


def test_load_delivery_context_rejects_an_incomplete_full_mode_plan(tmp_path: Path):
    workspace, preflight_root, worker_manifest = _workspace(tmp_path)
    manifest = json.loads(worker_manifest.read_text())
    manifest["gates"] = [{"name": "python-tests", "status": "passed"}]
    worker_manifest.write_text(json.dumps(manifest))
    with pytest.raises(DeliveryError, match="complete full-mode gate plan"):
        load_delivery_context(workspace, preflight_root)


def test_pull_request_body_contains_bounded_evidence_not_command_output(tmp_path: Path):
    workspace, preflight_root, verified_manifest = _workspace(tmp_path)
    context = load_delivery_context(workspace, preflight_root)

    body = render_pull_request_body(context)

    assert "Refs #95" in body
    assert "YAN-62" in body
    assert "diff-check: passed" in body
    assert "Review and merge" in body
    assert "commands" not in body


def test_delivery_state_is_idempotent_per_handoff_digest():
    assert should_process({}, "new") is True
    assert should_process({"status": "pending-ci", "handoff_sha256": "same"}, "same") is False
    assert should_process({"status": "ready-for-human", "handoff_sha256": "same"}, "same") is False
    assert should_process({"status": "failed", "handoff_sha256": "same"}, "same") is True
    assert should_process({"status": "pending-ci", "handoff_sha256": "old"}, "new") is True


def test_equivalent_manifest_timestamps_do_not_change_delivery_identity(tmp_path):
    workspace, preflight_root, verified_manifest = _workspace(tmp_path)
    before = load_delivery_context(workspace, preflight_root)
    manifest = json.loads(verified_manifest.read_text())
    manifest.update(generated_at="later", finished_at="later")
    verified_manifest.write_text(json.dumps(manifest))

    after = load_delivery_context(workspace, preflight_root)

    assert before.handoff_sha256 == after.handoff_sha256


def test_snapshot_ignores_worker_git_execution_config_and_forged_base(tmp_path: Path):
    workspace, preflight_root, verified_manifest = _workspace(tmp_path)
    (workspace / "hidden.txt").write_text("hidden ancestor")
    _git("add", "hidden.txt", cwd=workspace)
    _git("commit", "-m", "hidden worker commit", cwd=workspace)
    _git("update-ref", "refs/remotes/origin/main", "HEAD", cwd=workspace)
    marker = tmp_path / "executed"
    _git("config", "core.fsmonitor", f"touch {marker}", cwd=workspace)
    context = load_delivery_context(workspace, preflight_root)
    controller = DeliveryController(preflight_root=preflight_root, repository="YannJY02/AutoTranscribe", gh="gh", source=tmp_path / "source")
    snapshot = controller._snapshot(context, tmp_path / "snapshot", {})
    assert not marker.exists()
    assert not (snapshot.workspace / "hidden.txt").exists()
    assert _git("rev-parse", "HEAD", cwd=snapshot.workspace) == (preflight_root / "GH-95.base").read_text()


def test_controller_resets_a_worker_precreated_delivery_branch_to_the_verified_head(tmp_path: Path):
    workspace, preflight_root, verified_manifest = _workspace(tmp_path)
    verified_head = _git("rev-parse", "HEAD", cwd=workspace)
    _git("stash", "push", "--include-untracked", cwd=workspace)
    _git("switch", "-c", "codex/gh-95-yan-62", cwd=workspace)
    (workspace / "unverified.txt").write_text("worker branch payload\n", encoding="utf-8")
    _git("add", "unverified.txt", cwd=workspace)
    _git("commit", "-m", "unverified branch commit", cwd=workspace)
    _git("switch", "main", cwd=workspace)
    _git("stash", "pop", cwd=workspace)
    context = load_delivery_context(workspace, preflight_root)
    controller = DeliveryController(preflight_root=preflight_root, repository="YannJY02/AutoTranscribe", gh="gh")

    controller._prepare_branch(context)

    assert _git("rev-parse", "HEAD", cwd=workspace) == verified_head
    assert _git("branch", "--show-current", cwd=workspace) == "codex/gh-95-yan-62"
    assert not (workspace / "unverified.txt").exists()


def test_controller_repeated_handoff_is_noop_before_any_github_write(tmp_path: Path, monkeypatch):
    workspace, preflight_root, verified_manifest = _workspace(tmp_path)
    _git("update-ref", "refs/remotes/origin/main", "HEAD", cwd=workspace)
    _git("switch", "-c", "codex/gh-95-yan-62", cwd=workspace)
    _git("add", "feature.txt", cwd=workspace)
    _git("commit", "-m", "controller delivery", cwd=workspace)
    controller = DeliveryController(preflight_root=preflight_root, repository="YannJY02/AutoTranscribe", gh="gh")
    context = load_delivery_context(workspace, preflight_root)
    monkeypatch.setattr(controller, "_gh", lambda *args, **kwargs: pytest.fail("duplicate GitHub write"))
    state_path = preflight_root.parent / "delivery" / "GH-95.json"
    state_path.parent.mkdir()
    state_path.write_text(
        json.dumps({"status": "pending-ci", "handoff_sha256": context.handoff_sha256, "pull_request": "https://example.invalid/pr/1"}),
        encoding="utf-8",
    )

    assert controller.process(workspace) is False


def test_controller_stops_if_task_contract_changes_during_worker_run(tmp_path, monkeypatch):
    workspace, preflight, _ = _workspace(tmp_path)
    context = load_delivery_context(workspace, preflight)
    controller = DeliveryController(preflight_root=preflight, repository="owner/repo", gh="gh")
    monkeypatch.setattr(controller, "_issue", lambda _context: {"state": "open", "labels": [], "assignees": [], "body": "new blocker"})
    monkeypatch.setattr(controller, "_gh", lambda *args, **kwargs: "owner")
    with pytest.raises(DeliveryError, match="contract changed"):
        controller._check_claim(context)


def test_controller_refreshes_existing_pull_request_evidence(tmp_path: Path, monkeypatch):
    workspace, preflight_root, verified_manifest = _workspace(tmp_path)
    context = load_delivery_context(workspace, preflight_root)
    controller = DeliveryController(preflight_root=preflight_root, repository="YannJY02/AutoTranscribe", gh="gh")
    edits = []

    monkeypatch.setattr(controller, "_prepare_branch", lambda _context: "codex/gh-95-yan-62")
    monkeypatch.setattr(controller, "_write_state", lambda *_args, **_kwargs: None)
    monkeypatch.setattr(controller, "_check_claim", lambda _context: None)
    monkeypatch.setattr(
        "scripts.symphony_delivery_controller.git_changes_sha256",
        lambda *_args: context.changes_sha256,
    )
    monkeypatch.setattr(
        "scripts.symphony_delivery_controller._git_lines",
        lambda *_args, **_kwargs: set(context.changed_files),
    )

    def git(_context, *args, **_kwargs):
        stdout = ""
        if args[:2] == ("rev-list", "--count"):
            stdout = "1\n"
        elif args[:2] == ("rev-parse", "HEAD"):
            stdout = "a" * 40 + "\n"
        return subprocess.CompletedProcess(["git", *args], 0, stdout, "")

    def gh(args, *, cwd, input_text=None):
        del cwd, input_text
        if args[:2] == ["pr", "list"]:
            return '[{"number": 7, "url": "https://example.invalid/pr/7"}]'
        if args[:2] == ["issue", "view"]:
            return "Controller issue"
        if args[:2] == ["pr", "edit"]:
            body_path = Path(args[args.index("--body-file") + 1])
            edits.append((args, body_path.read_text(encoding="utf-8")))
            return ""
        raise AssertionError(args)

    monkeypatch.setattr(controller, "_git", git)
    monkeypatch.setattr(controller, "_gh", gh)

    assert controller._deliver_changes(context) == "https://example.invalid/pr/7"
    assert edits[0][0][2] == "7"
    assert "Close the delivery loop" in edits[0][1]


def test_snapshot_rejects_symlinked_parent_without_reading_outside(tmp_path):
    workspace = tmp_path / "worker"
    workspace.mkdir()
    (workspace / "linked").symlink_to(tmp_path)
    (tmp_path / "secret").write_text("private")
    with pytest.raises(OSError):
        read_worker_file(workspace, "linked/secret")


@pytest.mark.parametrize("path", [".GIT/config", ".Git/hooks/pre-commit", "nested/.gIt/config", ".VENV/bin/python"])
def test_delivery_rejects_case_aliases_of_protected_paths(tmp_path, path):
    workspace, preflight, manifest_path = _workspace(tmp_path)
    manifest = json.loads(manifest_path.read_text())
    manifest["changed_files"] = [path]
    manifest_path.write_text(json.dumps(manifest))
    with pytest.raises(DeliveryError, match="unsafe path"):
        load_delivery_context(workspace, preflight)


def test_host_hook_never_executes_worker_code(tmp_path, monkeypatch):
    root = Path(__file__).resolve().parents[1]
    hook = (root / "scripts/symphony_after_run.sh").read_text()
    assert 'agent_harness.py" verify' not in hook
    assert '.venv' not in hook
    assert 'cd "$SYMPHONY_CONTROLLER_REPO_ROOT"' in hook
    controller = DeliveryController(preflight_root=tmp_path, repository="owner/repo", gh="gh", source=root)
    executed_in = []
    def run(command, **kwargs):
        executed_in.append(kwargs["cwd"])
        return subprocess.CompletedProcess(command, 0, "", "")
    monkeypatch.setattr("scripts.symphony_delivery_controller._run", run)
    controller._gh(["api", "user"], cwd=tmp_path / "worker")
    assert executed_in == [root]


def test_delivery_and_retry_use_only_protected_clone_and_refresh_pr(tmp_path, monkeypatch):
    workspace, preflight, manifest_path = _workspace(tmp_path)
    remote = tmp_path / "remote.git"
    _git("init", "--bare", str(remote), cwd=tmp_path)
    controller = DeliveryController(preflight_root=preflight, repository="YannJY02/AutoTranscribe", gh="gh", source=tmp_path / "source")
    git = controller._git
    writes = []
    issue = {"state": "open", "labels": [{"name": "ready-for-agent"}], "assignees": [], "body": "contract"}

    def local_git(context, *args, **kwargs):
        assert context.workspace != workspace
        if "push" in args:
            args = ("push", str(remote), "HEAD:refs/heads/codex/gh-95-yan-62")
        elif args[:2] == ("fetch", "origin"):
            args = ("fetch", str(remote), args[2])
        return git(context, *args, **kwargs)

    def gh(args, **kwargs):
        if args[:2] == ["api", "user"]:
            return "owner"
        if args[:2] == ["api", "repos/YannJY02/AutoTranscribe/issues/95"]:
            return "\n".join(label["name"] for label in issue["labels"]) if "--jq" in args else json.dumps(issue)
        if "DELETE" in args:
            issue["labels"] = []
            return ""
        if args[:2] == ["issue", "view"]:
            return "Task"
        if args[:2] == ["pr", "list"]:
            return '[{"number":96,"url":"https://github.com/YannJY02/AutoTranscribe/pull/96"}]' if any(x[:2] == ["pr", "create"] for x in writes) else "[]"
        writes.append(args)
        return "https://github.com/YannJY02/AutoTranscribe/pull/96" if args[:2] == ["pr", "create"] else ""

    monkeypatch.setattr(controller, "_git", local_git)
    monkeypatch.setattr(controller, "_gh", gh)
    assert controller.process(workspace)
    assert controller.process(workspace) is False
    issue["labels"] = [{"name": "ready-for-agent"}]
    (workspace / "feature.txt").write_text("retry\n")
    manifest = json.loads(manifest_path.read_text())
    manifest["changes_sha256"] = changes_sha256(workspace, ["feature.txt"])
    manifest_path.write_text(json.dumps(manifest))
    assert controller.process(workspace)
    assert sum(args[:2] == ["pr", "create"] for args in writes) == 1
    assert sum(args[:2] == ["pr", "edit"] for args in writes) == 1
    assert _git("show", "codex/gh-95-yan-62:feature.txt", cwd=remote) == "retry"
    assert _git("branch", "--show-current", cwd=workspace) == "main"
    assert not list(tmp_path.glob("delivery-*"))


@pytest.mark.parametrize("scenario,target", [
    ("success", "ready-for-human"), ("failure", "ready-for-agent"),
    ("blocked", "needs-triage"), ("no-receipt", None),
    ("wrong-author", None), ("human-label", None), ("human-assignee", None),
    ("new-assignee", None), ("changed-body", None),
])
def test_ci_handoff_requires_receipt_and_preserves_human_changes(tmp_path, scenario, target):
    root = Path(__file__).resolve().parents[1]
    workflow = (root / ".github/workflows/controller-handoff.yml").read_text()
    script = textwrap.dedent(workflow.split("        run: |\n", 1)[1])
    head = "a" * 40
    metadata = {"issue": 95, "pr": 96, "head": head, "body_sha256": hashlib.sha256(b"contract").hexdigest()}
    data = {
        "pr": {"head": {"ref": "codex/gh-95-yan-62", "sha": head, "repo": {"full_name": "owner/repo"}}, "user": {"login": "other" if scenario == "wrong-author" else "owner"}, "state": "open"},
        "issue": {"state": "open", "body": "contract", "labels": [{"name": "needs-info"}] if scenario == "human-label" else [], "assignees": [{"login": "human"}] if scenario == "human-assignee" else []},
        "receipts": [[]] if scenario == "no-receipt" else [[{"user": {"login": "owner"}, "body": "<!-- insightkit-controller:" + json.dumps(metadata) + " -->"}]],
        "scenario": scenario, "reads": 0, "writes": [],
    }
    state = tmp_path / "state.json"
    state.write_text(json.dumps(data))
    gh = tmp_path / "gh"
    gh.write_text(f"#!{sys.executable}\n" + textwrap.dedent('''\
        import json, os, sys
        from pathlib import Path
        path = Path(os.environ["TEST_STATE"])
        data = json.loads(path.read_text())
        args = sys.argv[1:]
        route = next((arg for arg in args if arg.startswith("repos/")), "")
        if "--method" in args:
            method = args[args.index("--method") + 1]
            data["writes"].append(method)
            if method == "POST":
                labels = json.load(sys.stdin)["labels"]
                data["issue"]["labels"] = [{"name": label} for label in labels]
                data["target"] = labels[0]
        elif route.endswith("/comments"):
            print(json.dumps(data["receipts"]))
        elif "/pulls/" in route:
            print(data["pr"]["head"]["sha"] if "--jq" in args else json.dumps(data["pr"]))
        elif route.endswith("/issues/95"):
            data["reads"] += 1
            if data["reads"] == 2 and data["scenario"] == "new-assignee":
                data["issue"]["assignees"] = [{"login": "human"}]
            if data["reads"] == 2 and data["scenario"] == "changed-body":
                data["issue"]["body"] = "new blocker"
            print(json.dumps(data["issue"]))
        path.write_text(json.dumps(data))
    '''))
    gh.chmod(0o755)
    preflight = tmp_path / "python3"
    preflight.write_text("#!/bin/sh\nexit " + ("1" if scenario == "blocked" else "0") + "\n")
    preflight.chmod(0o755)
    env = dict(os.environ, PATH=f"{tmp_path}:{os.environ['PATH']}", TEST_STATE=str(state), GITHUB_REPOSITORY="owner/repo", GITHUB_REPOSITORY_OWNER="owner", RUN_JSON=json.dumps({"pull_requests": [{"number": 96}], "head_sha": head, "conclusion": "failure" if scenario in {"failure", "blocked"} else "success", "html_url": "https://example.invalid/run"}))
    result = subprocess.run(["bash", "-c", script], cwd=root, env=env, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    actual = json.loads(state.read_text())
    assert actual.get("target") == target
