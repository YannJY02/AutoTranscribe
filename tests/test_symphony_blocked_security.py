from __future__ import annotations

import copy
import hashlib
import json
import os
import signal
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import unquote

import pytest

from scripts import agent_harness as harness
from scripts import symphony_delivery_controller as delivery


ISSUE_ROUTE = "repos/owner/repo/issues/95"
REPORT_LIMIT = 64 * 1024
MANIFEST_LIMIT = 1024 * 1024


class RecordingGitHub:
    """Exercise the controller's real guards while refusing unknown operations."""

    def __init__(self) -> None:
        self.issue = {
            "state": "open",
            "body": "contract",
            "labels": [{"name": "ready-for-agent"}, {"name": "product"}],
            "assignees": [{"login": "controller"}],
        }
        self.comments: list[dict] = []
        self.writes: list[tuple[list[str], str | None]] = []

    def __call__(self, args, *, cwd, input_text=None):
        args = list(args)
        if args[:2] == ["api", "user"]:
            return "controller" if "--jq" in args else '{"login":"controller"}'
        route = next((value for value in args if value.startswith("repos/")), "")
        method = args[args.index("--method") + 1] if "--method" in args else "GET"
        if args[0] == "api" and method == "GET":
            if route == ISSUE_ROUTE:
                return json.dumps(self.issue)
            if route == f"{ISSUE_ROUTE}/comments":
                pages = [self.comments] if "--slurp" in args else self.comments
                return json.dumps(pages)
        if args[:2] == ["issue", "comment"] or (
            args[0] == "api" and method == "POST" and route == f"{ISSUE_ROUTE}/comments"
        ):
            if args[0] == "issue":
                assert args == ["issue", "comment", "95", "--repo", "owner/repo", "--body-file", "-"]
            self.writes.append((args, input_text))
            body = json.loads(input_text)["body"] if args[0] == "api" else input_text
            assert isinstance(body, str)
            comment = {"id": len(self.comments) + 1, "user": {"login": "controller"}, "body": body}
            self.comments.append(comment)
            return json.dumps(comment) if args[0] == "api" else "https://example.invalid/comment/1"
        if args[:2] == ["issue", "edit"] and "--remove-assignee" in args:
            assert args == ["issue", "edit", "95", "--repo", "owner/repo", "--remove-assignee", "controller"]
            self.writes.append((args, input_text))
            self.issue["assignees"] = [item for item in self.issue["assignees"] if item["login"] != "controller"]
            return ""
        if args[0] == "api" and method == "DELETE" and route.startswith(f"{ISSUE_ROUTE}/labels/"):
            label = unquote(route.rsplit("/", 1)[1])
            assert label in {"ready-for-agent", "needs-triage"}
            self.writes.append((args, input_text))
            self.issue["labels"] = [item for item in self.issue["labels"] if item["name"] != label]
            return ""
        if args[0] == "api" and method == "POST" and route == f"{ISSUE_ROUTE}/labels":
            labels = json.loads(input_text)["labels"]
            assert labels == ["needs-triage"]
            self.writes.append((args, input_text))
            existing = {item["name"] for item in self.issue["labels"]}
            self.issue["labels"].extend({"name": name} for name in labels if name not in existing)
            return ""
        pytest.fail(f"unexpected GitHub operation: {args!r}")


@dataclass
class BlockedWorkspace:
    workspace: Path
    preflight: Path
    manifest: Path
    controller: delivery.DeliveryController
    github: RecordingGitHub
    attempt_id: str

    @property
    def handoff(self) -> Path:
        return self.workspace / ".symphony/handoff.json"


def _write_json(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload), encoding="utf-8")


@pytest.fixture
def blocked_workspace(tmp_path: Path, monkeypatch) -> BlockedWorkspace:
    workspace = tmp_path / "GH-95"
    workspace.mkdir()
    preflight = tmp_path / "preflight"
    preflight.mkdir()
    source = tmp_path / "source"
    source.mkdir()
    _write_json(preflight / "GH-95.json", {
        "status": "passed", "issue": 95, "linear_issue": "YAN-68",
        "body_sha256": hashlib.sha256(b"contract").hexdigest(),
        "resource_class": "isolated", "blockers": [], "errors": [],
    })
    (preflight / "GH-95.base").write_text("a" * 40 + "\n")
    (preflight / "GH-95.claimed").write_text("claimed\n")
    controller = delivery.DeliveryController(
        preflight_root=preflight, repository="owner/repo", gh="gh", source=source,
    )
    github = RecordingGitHub()
    monkeypatch.setattr(controller, "_gh", github)

    def forbidden(*_args, **_kwargs):
        pytest.fail("blocked processing entered Git, snapshot, or code delivery")

    for method in ("_git", "_snapshot", "_prepare_branch", "_deliver_changes"):
        monkeypatch.setattr(controller, method, forbidden)
    monkeypatch.setattr(delivery, "_run", forbidden)
    monkeypatch.setattr(delivery, "_git_lines", forbidden)
    monkeypatch.setattr(delivery.subprocess, "run", forbidden)
    monkeypatch.setattr(delivery.subprocess, "Popen", forbidden)
    attempt_id = controller.begin_attempt(workspace)
    manifest = workspace / "logs/harness/run/manifest.json"
    manifest.parent.mkdir(parents=True)
    _write_json(manifest, {
        "schema_version": 1, "status": "failed", "issue": 95,
        "workspace": str(workspace), "changed_files": [],
        "changes_sha256": hashlib.sha256(b"").hexdigest(), "mode": "full",
        "gates": [{"name": "diff-check", "status": "failed", "commands": [{
            "command": ["git", "diff", "--check"], "exit_code": 1, "ok": False,
        }]}],
    })
    _write_json(workspace / ".symphony/handoff.json", {
        "schema_version": 1, "status": "blocked", "kind": "verification-blocked",
        "issue": "GH-95", "manifest": "logs/harness/run/manifest.json",
        "reason_code": "full-harness-failed", "attempt_id": attempt_id,
    })
    context = delivery.load_blocked_context(workspace, preflight)
    assert (context.attempt_id, context.failed_gate, context.exit_code) == (attempt_id, "diff-check", 1)
    assert github.writes == []
    return BlockedWorkspace(workspace, preflight, manifest, controller, github, attempt_id)


@contextmanager
def _fifo_deadline():
    """A regression to blocking open must fail rather than hang the test run."""
    previous = signal.getsignal(signal.SIGALRM)

    def expired(_signum, _frame):
        pytest.fail("reading a worker FIFO blocked instead of rejecting it")

    signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, 3)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


def _replace_with_unsafe_file(path: Path, kind: str, limit: int, outside_root: Path) -> None:
    contents = path.read_bytes()
    if kind == "oversize":
        path.write_bytes(contents + b" " * (limit + 1 - len(contents)))
        return
    path.unlink()
    if kind == "symlink":
        outside = outside_root / f"outside-{path.name}"
        outside.write_bytes(contents)
        path.symlink_to(outside)
    elif kind == "fifo":
        os.mkfifo(path)
    else:
        raise AssertionError(kind)


@pytest.mark.parametrize("document", ["handoff", "manifest"])
@pytest.mark.parametrize("kind", ["symlink", "fifo", "oversize"])
def test_blocked_controller_rejects_unsafe_reports_before_external_write(blocked_workspace, document, kind):
    data = blocked_workspace
    path = data.handoff if document == "handoff" else data.manifest
    _replace_with_unsafe_file(
        path, kind, REPORT_LIMIT if document == "handoff" else MANIFEST_LIMIT, data.workspace.parent,
    )

    with _fifo_deadline(), pytest.raises(delivery.DeliveryError):
        data.controller.process(data.workspace)

    assert data.github.writes == []


@pytest.mark.parametrize("directory", [".symphony", "logs/harness"])
def test_blocked_controller_rejects_symlinked_report_parent(blocked_workspace, directory):
    data = blocked_workspace
    original = data.workspace / directory
    outside = data.workspace.parent / "outside-reports"
    original.rename(outside)
    original.symlink_to(outside, target_is_directory=True)

    with pytest.raises(delivery.DeliveryError):
        data.controller.process(data.workspace)

    assert data.github.writes == []


@pytest.mark.parametrize("document", ["handoff", "manifest"])
def test_blocked_controller_rejects_excessive_json_nesting(blocked_workspace, document):
    data = blocked_workspace
    path = data.handoff if document == "handoff" else data.manifest
    contents = path.read_text().rstrip()
    path.write_text(contents[:-1] + ', "ignored": ' + "[" * 1500 + "0" + "]" * 1500 + "}")

    with pytest.raises(delivery.DeliveryError):
        data.controller.process(data.workspace)

    assert data.github.writes == []


@pytest.mark.parametrize("path", [".", "./"])
def test_blocked_controller_rejects_repository_root_as_changed_file(blocked_workspace, path):
    data = blocked_workspace
    manifest = json.loads(data.manifest.read_text())
    manifest["changed_files"] = [path]
    _write_json(data.manifest, manifest)

    with pytest.raises(delivery.DeliveryError):
        data.controller.process(data.workspace)

    assert data.github.writes == []


def test_blocked_controller_rejects_manifest_workspace_symlink_loop(blocked_workspace):
    data = blocked_workspace
    loop = data.workspace / "workspace-loop"
    loop.symlink_to(loop)
    manifest = json.loads(data.manifest.read_text())
    manifest["workspace"] = str(loop)
    _write_json(data.manifest, manifest)

    with pytest.raises(delivery.DeliveryError):
        data.controller.process(data.workspace)

    assert data.github.writes == []


@pytest.mark.parametrize("kind", ["symlink", "fifo", "oversize"])
def test_blocked_writer_rejects_unsafe_worker_attempt(blocked_workspace, kind):
    data = blocked_workspace
    original_report = data.handoff.read_bytes()
    _replace_with_unsafe_file(data.workspace / ".symphony/attempt.json", kind, REPORT_LIMIT, data.workspace.parent)

    with _fifo_deadline(), pytest.raises((ValueError, delivery.DeliveryError)):
        harness.write_blocked_handoff(root=data.workspace, issue="GH-95", manifest_path=data.manifest)

    assert data.handoff.read_bytes() == original_report
    assert data.github.writes == []


def test_blocked_comment_never_contains_worker_commands_output_or_free_text(blocked_workspace):
    data = blocked_workspace
    secret = "WORKER_PRIVATE_SENTINEL_73e0a2"
    manifest = json.loads(data.manifest.read_text())
    manifest.update(summary=secret, stdout=secret, stderr=secret, branch=secret, commit=secret)
    manifest["gates"][0].update(summary=secret, stdout=secret, stderr=secret)
    manifest["gates"][0]["commands"][0].update(
        command=["sh", "-c", f"printf {secret}"], stdout=secret, stderr=secret, log_path=secret,
    )
    _write_json(data.manifest, manifest)
    handoff = json.loads(data.handoff.read_text())
    handoff.update(summary=secret, human_gates=[secret], error=secret, commands=[secret])
    _write_json(data.handoff, handoff)

    assert data.controller.process(data.workspace) is True

    assert data.github.comments
    outward = json.dumps(data.github.writes)
    assert secret not in outward
    assert "insightkit-controller:" not in outward
    assert "diff-check" in outward
    assert {item["name"] for item in data.github.issue["labels"]} == {"product", "needs-triage"}


@pytest.mark.parametrize("attempt", ["previous", "forged"])
def test_blocked_report_cannot_revoke_a_different_attempt(blocked_workspace, attempt):
    data = blocked_workspace
    original_report = data.handoff.read_bytes()
    if attempt == "previous":
        assert data.controller.begin_attempt(data.workspace) != data.attempt_id
        data.handoff.write_bytes(original_report)
    else:
        handoff = json.loads(original_report)
        handoff["attempt_id"] = ("0" if data.attempt_id[0] != "0" else "1") + data.attempt_id[1:]
        _write_json(data.handoff, handoff)

    with pytest.raises(delivery.DeliveryError):
        data.controller.process(data.workspace)

    assert data.github.writes == []


@pytest.mark.parametrize("human_change", ["body", "assignment", "triage", "closed"])
def test_blocked_report_preserves_human_changes_without_external_write(blocked_workspace, human_change):
    data = blocked_workspace
    if human_change == "body":
        data.github.issue["body"] = "contract with new human acceptance criteria"
    elif human_change == "assignment":
        data.github.issue["assignees"].append({"login": "human-owner"})
    elif human_change == "triage":
        data.github.issue["labels"].append({"name": "ready-for-human"})
    else:
        data.github.issue["state"] = "closed"
    expected = copy.deepcopy(data.github.issue)

    with pytest.raises(delivery.DeliveryError):
        data.controller.process(data.workspace)

    assert data.github.issue == expected
    assert data.github.writes == []
