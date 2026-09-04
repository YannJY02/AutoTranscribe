#!/usr/bin/env python3
"""Validate Symphony handoffs and deliver bounded GitHub review artifacts."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
from dataclasses import dataclass, replace
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Sequence

if __package__:
    from .agent_harness import TRIAGE_LABELS, changes_sha256, git_changes_sha256, gate_specs
else:
    from agent_harness import TRIAGE_LABELS, changes_sha256, git_changes_sha256, gate_specs


WORKSPACE_RE = re.compile(r"^GH-(?P<number>\d+)$")
LINEAR_RE = re.compile(r"^[A-Z][A-Z0-9]*-\d+$")
GATE_RE = re.compile(r"^[a-z][a-z0-9-]{0,63}$")


class DeliveryError(RuntimeError):
    pass


@dataclass(frozen=True)
class DeliveryContext:
    workspace: Path
    issue_number: int
    linear_issue: str
    summary: str
    kind: str
    changed_files: tuple[str, ...]
    pending_files: tuple[str, ...]
    gates: tuple[str, ...]
    human_gates: tuple[str, ...]
    changes_sha256: str
    handoff_sha256: str
    contract_sha256: str


def read_worker_file(root: Path, relative: str) -> tuple[bytes, int]:
    """Read regular files via directory descriptors; never follow worker links."""
    parts = Path(relative).parts
    if not parts or Path(relative).is_absolute() or ".." in parts:
        raise DeliveryError("worker path must stay inside the workspace")
    directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            os.close(directory)
            directory = child
        fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        with os.fdopen(fd, "rb") as handle:
            metadata = os.fstat(handle.fileno())
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > 100_000_000:
                raise DeliveryError("worker handoff files must be bounded regular files")
            contents = handle.read(100_000_001)
            if len(contents) > 100_000_000:
                raise DeliveryError("worker file exceeds delivery limit")
            return contents, 0o755 if metadata.st_mode & 0o111 else 0o644
    finally:
        os.close(directory)


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _read_json(path: Path, label: str) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise DeliveryError(f"cannot read {label}: {path}") from exc
    if not isinstance(payload, dict):
        raise DeliveryError(f"{label} must be a JSON object")
    return payload


def _safe_git_environment() -> dict[str, str]:
    environment = os.environ.copy()
    environment.update(
        {
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "InsightKit Delivery Controller",
            "GIT_AUTHOR_EMAIL": "controller@insightkit.invalid",
            "GIT_COMMITTER_NAME": "InsightKit Delivery Controller",
            "GIT_COMMITTER_EMAIL": "controller@insightkit.invalid",
        }
    )
    return environment


def _git_command(*args: str) -> list[str]:
    return ["git", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", *args]


def _run(
    command: Sequence[str],
    *,
    cwd: Path,
    input_text: str | None = None,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        command,
        cwd=cwd,
        input=input_text,
        text=True,
        capture_output=True,
        check=False,
        env=env,
    )
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout).strip()
        raise DeliveryError(f"command failed ({' '.join(command)}): {detail}")
    return completed


def _git_lines(workspace: Path, *args: str, allow_failure: bool = False) -> set[str]:
    completed = subprocess.run(
        _git_command(*args),
        cwd=workspace,
        text=True,
        capture_output=True,
        check=False,
        env=_safe_git_environment(),
    )
    if completed.returncode != 0:
        if allow_failure:
            return set()
        raise DeliveryError((completed.stderr or completed.stdout).strip())
    return {line.strip() for line in completed.stdout.splitlines() if line.strip()}


def _safe_paths(values: Any, label: str) -> tuple[str, ...]:
    if not isinstance(values, list) or any(not isinstance(value, str) for value in values):
        raise DeliveryError(f"{label} must be a list of repository-relative paths")
    paths = tuple(sorted(set(values)))
    for value in paths:
        path = Path(value)
        if (
            not value
            or path.is_absolute()
            or ".." in path.parts
            or path.parts[0].casefold() in {".git", ".venv", ".symphony", "logs"}
            or any(part.casefold() == ".git" for part in path.parts)
            or any(character in value for character in "\r\n\x00`")
        ):
            raise DeliveryError(f"unsafe path in {label}: {value!r}")
    return paths


def load_delivery_context(workspace: Path, preflight_root: Path) -> DeliveryContext:
    workspace = workspace.expanduser().resolve()
    preflight_root = preflight_root.expanduser().resolve()
    match = WORKSPACE_RE.fullmatch(workspace.name)
    if not match:
        raise DeliveryError("workspace must be named GH-<issue number>")
    issue_number = int(match.group("number"))
    handoff_path = workspace / ".symphony" / "handoff.json"
    try:
        handoff_bytes, _ = read_worker_file(workspace, ".symphony/handoff.json")
        handoff = json.loads(handoff_bytes)
    except (OSError, json.JSONDecodeError) as exc:
        raise DeliveryError(f"cannot read controller handoff: {handoff_path}") from exc
    if not isinstance(handoff, dict) or handoff.get("status") != "ready":
        raise DeliveryError("controller handoff is not ready")
    if handoff.get("schema_version") != 1:
        raise DeliveryError("unsupported controller handoff schema version")
    if handoff.get("issue") != f"GH-{issue_number}":
        raise DeliveryError("controller handoff issue does not match the workspace")

    manifest_value = str(handoff.get("manifest") or "")
    manifest_relative = Path(manifest_value)
    if not manifest_value or manifest_relative.is_absolute() or ".." in manifest_relative.parts:
        raise DeliveryError("manifest must stay inside the workspace")
    manifest_path = (workspace / manifest_relative).resolve()
    try:
        manifest_path.relative_to(workspace)
    except ValueError as exc:
        raise DeliveryError("manifest must stay inside the workspace") from exc

    try:
        manifest_bytes, _ = read_worker_file(workspace, manifest_relative.as_posix())
        manifest = json.loads(manifest_bytes)
    except (OSError, json.JSONDecodeError) as exc:
        raise DeliveryError("cannot read worker Harness manifest") from exc
    if not isinstance(manifest, dict):
        raise DeliveryError("worker Harness manifest must be a JSON object")
    preflight = _read_json(preflight_root / f"GH-{issue_number}.json", "issue preflight")
    if manifest.get("schema_version") != 1:
        raise DeliveryError("unsupported harness manifest schema version")
    if manifest.get("status") != "passed" or manifest.get("issue") != issue_number:
        raise DeliveryError("handoff requires a passed manifest for the same issue")
    if manifest.get("mode") != "full":
        raise DeliveryError("handoff requires a full-mode harness manifest")
    if Path(str(manifest.get("workspace") or "")).resolve() != workspace:
        raise DeliveryError("harness manifest belongs to a different workspace")
    if preflight.get("status") != "passed" or preflight.get("issue") != issue_number:
        raise DeliveryError("issue preflight did not pass for this workspace")
    linear_issue = str(preflight.get("linear_issue") or "")
    if not LINEAR_RE.fullmatch(linear_issue):
        raise DeliveryError("issue preflight is missing a valid Linear identifier")
    contract_digest = str(preflight.get("body_sha256") or "")
    if not re.fullmatch(r"[0-9a-f]{64}", contract_digest):
        raise DeliveryError("issue preflight is missing the task contract digest")

    changed_files = _safe_paths(manifest.get("changed_files"), "manifest changed files")
    expected_digest = str(manifest.get("changes_sha256") or "")
    if not re.fullmatch(r"[0-9a-f]{64}", expected_digest):
        raise DeliveryError("manifest requires a file contents digest")
    kind = str(handoff.get("kind") or "")
    if kind not in {"changes", "no-change"} or (kind == "no-change") != (not changed_files):
        raise DeliveryError("handoff kind does not match the verified changes")
    if changed_files and handoff.get("review_status") != "clear":
        raise DeliveryError("changed code requires a clear independent review")

    gate_payloads = manifest.get("gates") or []
    if (
        not isinstance(gate_payloads, list)
        or not gate_payloads
        or any(not isinstance(gate, dict) or gate.get("status") != "passed" for gate in gate_payloads)
    ):
        raise DeliveryError("all harness gates must pass before delivery")
    gates = tuple(str(gate.get("name")) for gate in gate_payloads if gate.get("name"))
    if any(not GATE_RE.fullmatch(gate) for gate in gates):
        raise DeliveryError("harness gate names must use the bounded gate vocabulary")
    expected_gates = tuple(gate.name for gate in gate_specs(changed_files, mode="full", python_executable="python"))
    if gates != expected_gates:
        raise DeliveryError("manifest must report the complete full-mode gate plan")
    summary = str(handoff.get("summary") or "").strip()
    human_gates = handoff.get("human_gates") or []
    if not summary or any(character in summary for character in "\r\n\x00") or len(summary) > 200:
        raise DeliveryError("handoff summary must be one bounded line")
    if not isinstance(human_gates, list) or any(not isinstance(gate, str) for gate in human_gates):
        raise DeliveryError("human gates must be a list of strings")
    if any(not gate.strip() or len(gate.strip()) > 300 or any(char in gate for char in "\r\n\x00") for gate in human_gates):
        raise DeliveryError("human gates must be bounded one-line strings")

    return DeliveryContext(
        workspace=workspace,
        issue_number=issue_number,
        linear_issue=linear_issue,
        summary=summary,
        kind=kind,
        changed_files=changed_files,
        pending_files=changed_files,
        gates=gates,
        human_gates=tuple(gate.strip() for gate in human_gates if gate.strip()),
        changes_sha256=expected_digest,
        contract_sha256=contract_digest,
        handoff_sha256=hashlib.sha256(json.dumps({
            "issue": issue_number, "summary": summary, "kind": kind,
            "files": changed_files, "digest": expected_digest, "gates": gates,
            "review": handoff.get("review_status"), "human_gates": human_gates,
            "contract": contract_digest,
        }, sort_keys=True).encode()).hexdigest(),
    )


def branch_name(context: DeliveryContext) -> str:
    return f"codex/gh-{context.issue_number}-{context.linear_issue.lower()}"


def should_process(state: dict[str, Any], handoff_sha256: str) -> bool:
    return not (
        state.get("handoff_sha256") == handoff_sha256
        and state.get("status") in {"pending-ci", "ready-for-human"}
    )


def render_pull_request_body(context: DeliveryContext) -> str:
    lines = [
        f"Refs #{context.issue_number}",
        "",
        f"Linear: {context.linear_issue}",
        "",
        "## Summary",
        "",
        context.summary,
        "",
        "## Files bound to the worker manifest",
        "",
        *[f"- `{path}`" for path in context.changed_files],
        "",
        "## Reported local Harness gates",
        "",
        *[f"- {gate}: passed (worker report)" for gate in context.gates],
        "",
        "The controller validates the file digest, not worker execution claims. Isolated current-head CI and independent review are required before acceptance.",
    ]
    if context.human_gates:
        lines.extend(["", "## Human gates", "", *[f"- {gate}" for gate in context.human_gates]])
    return "\n".join(lines).rstrip() + "\n"


class DeliveryController:
    def __init__(self, *, preflight_root: Path, repository: str, gh: str, source: Path | None = None) -> None:
        self.preflight_root = preflight_root.expanduser().resolve()
        self.repository = repository
        self.gh = gh
        self.source = (source or Path(__file__).resolve().parents[1]).resolve()

    def _snapshot(self, context: DeliveryContext, destination: Path, state: dict[str, Any]) -> DeliveryContext:
        # Never run Git or any other executable in the worker's repository.
        base = (self.preflight_root / f"GH-{context.issue_number}.base").read_text().strip()
        if not re.fullmatch(r"[0-9a-f]{40}", base):
            raise DeliveryError("missing immutable controller baseline; re-triage the task")
        _run(_git_command("clone", "--no-local", "--no-checkout", str(self.source), str(destination)),
             cwd=self.source, env=_safe_git_environment())
        snapshot = replace(context, workspace=destination)
        self._git(snapshot, "remote", "set-url", "origin", f"https://github.com/{self.repository}.git")
        previous = str(state.get("controller_head") or "")
        if previous:
            if not re.fullmatch(r"[0-9a-f]{40}", previous):
                raise DeliveryError("invalid previous controller revision")
            self._git(snapshot, "fetch", "origin", branch_name(context))
            if self._git(snapshot, "rev-parse", "FETCH_HEAD").stdout.strip() != previous:
                raise DeliveryError("remote branch changed outside this controller; human review required")
        self._git(snapshot, "switch", "-C", branch_name(context), previous or base)
        self._git(snapshot, "read-tree", "--reset", "-u", base)
        self._git(snapshot, "update-ref", "refs/remotes/origin/main", base)
        for relative in context.changed_files:
            target = destination / relative
            first = destination / Path(relative).parts[0]
            if first.exists() and os.path.samefile(first, destination / ".git"):
                raise DeliveryError("delivery path aliases Git metadata")
            # A trusted base can itself contain links; do not copy through them.
            if any(parent.is_symlink() for parent in (target, *target.parents) if parent != destination.parent):
                raise DeliveryError("delivery path must not traverse a symbolic link")
            try:
                contents, mode = read_worker_file(context.workspace, relative)
            except FileNotFoundError:
                target.unlink(missing_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(contents)
                target.chmod(mode)
        if changes_sha256(destination, context.changed_files) != context.changes_sha256:
            raise DeliveryError("manifest does not match the verified file contents")
        actual = tuple(sorted(_git_lines(destination, "diff", "--name-only", base) |
                              _git_lines(destination, "ls-files", "--others", "--exclude-standard")))
        if actual != context.changed_files:
            raise DeliveryError("manifest changed files do not match the snapshot changes")
        return snapshot

    def _gh(self, args: Sequence[str], *, cwd: Path, input_text: str | None = None) -> str:
        return _run([self.gh, *args], cwd=self.source, input_text=input_text).stdout.strip()

    def _state_path(self, workspace: Path) -> Path:
        return self.preflight_root.parent / "delivery" / f"{workspace.name}.json"

    def _write_state(self, context: DeliveryContext, status: str, **extra: Any) -> None:
        path = self._state_path(context.workspace)
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
        payload = {
            "schema_version": 1,
            "updated_at": _utc_now(),
            "status": status,
            "issue": context.issue_number,
            "linear_issue": context.linear_issue,
            "handoff_sha256": context.handoff_sha256,
            **extra,
        }
        temporary.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        temporary.chmod(0o600)
        temporary.replace(path)

    def _set_triage(self, context: DeliveryContext, target: str | None) -> None:
        def active() -> set[str]:
            issue = self._issue(context)
            if issue.get("state") != "open" or issue.get("assignees"):
                raise DeliveryError("preserving human issue state or assignment")
            if hashlib.sha256((issue.get("body") or "").encode()).hexdigest() != context.contract_sha256:
                raise DeliveryError("task contract changed since preflight")
            return {label["name"] for label in issue.get("labels", [])} & TRIAGE_LABELS

        current = active()
        if target and current == {target}:
            return
        if current - {"ready-for-agent"}:
            raise DeliveryError(f"preserving existing triage state: {', '.join(sorted(current))}")
        if "ready-for-agent" in current:
            self._gh(
                ["api", "--method", "DELETE", f"repos/{self.repository}/issues/{context.issue_number}/labels/ready-for-agent"],
                cwd=context.workspace,
            )
        current = active()
        if current:
            raise DeliveryError(f"preserving concurrent triage state: {', '.join(sorted(current))}")
        if not target:
            return
        self._gh(
            ["api", "--method", "POST", f"repos/{self.repository}/issues/{context.issue_number}/labels", "--input", "-"],
            cwd=context.workspace,
            input_text=json.dumps({"labels": [target]}),
        )
        try:
            conflicts = active() - {target}
        except DeliveryError:
            self._gh(
                ["api", "--method", "DELETE", f"repos/{self.repository}/issues/{context.issue_number}/labels/{target}"],
                cwd=context.workspace,
            )
            raise
        if conflicts:
            self._gh(
                ["api", "--method", "DELETE", f"repos/{self.repository}/issues/{context.issue_number}/labels/{target}"],
                cwd=context.workspace,
            )
            raise DeliveryError(f"preserving concurrent triage state: {', '.join(sorted(conflicts))}")

    def _release_claim(self, context: DeliveryContext) -> None:
        login = self._gh(["api", "user", "--jq", ".login"], cwd=context.workspace)
        if not login or any(character in login for character in "\r\n\x00"):
            raise DeliveryError("cannot identify the controller GitHub account")
        self._gh(
            ["issue", "edit", str(context.issue_number), "--repo", self.repository, "--remove-assignee", login],
            cwd=context.workspace,
        )

    def _comment(self, context: DeliveryContext, body: str) -> None:
        self._gh(
            ["issue", "comment", str(context.issue_number), "--repo", self.repository, "--body-file", "-"],
            cwd=context.workspace,
            input_text=body,
        )

    def _issue(self, context: DeliveryContext) -> dict[str, Any]:
        return json.loads(self._gh(
            ["api", f"repos/{self.repository}/issues/{context.issue_number}"], cwd=self.source,
        ))

    def _check_claim(self, context: DeliveryContext) -> None:
        issue = self._issue(context)
        labels = {label["name"] for label in issue.get("labels", [])} & TRIAGE_LABELS
        login = self._gh(["api", "user", "--jq", ".login"], cwd=self.source)
        assignees = {assignee["login"] for assignee in issue.get("assignees", [])}
        if issue.get("state") != "open" or labels - {"ready-for-agent"} or assignees - {login}:
            raise DeliveryError("preserving human issue state or assignment")
        if hashlib.sha256((issue.get("body") or "").encode()).hexdigest() != context.contract_sha256:
            raise DeliveryError("task contract changed since preflight")

    def _prepare_branch(self, context: DeliveryContext) -> str:
        desired = branch_name(context)
        current = self._git(context, "branch", "--show-current").stdout.strip()
        if current != desired:
            if current not in {"", "main"}:
                raise DeliveryError(f"refusing to replace unexpected branch: {current}")
            self._git(context, "switch", "-C", desired)
        return desired

    def _git(self, context: DeliveryContext, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
        command = _git_command(*args)
        if check:
            return _run(command, cwd=context.workspace, env=_safe_git_environment())
        return subprocess.run(
            command,
            cwd=context.workspace,
            text=True,
            capture_output=True,
            check=False,
            env=_safe_git_environment(),
        )

    def _deliver_changes(self, context: DeliveryContext) -> str:
        branch = self._prepare_branch(context)
        if context.pending_files:
            self._git(context, "add", "--all")
            if self._git(context, "diff", "--cached", "--quiet", check=False).returncode:
                self._git(context, "commit", "-m", f"{context.linear_issue}: {context.summary}")
        ahead = self._git(context, "rev-list", "--count", "origin/main..HEAD").stdout.strip()
        if int(ahead or "0") < 1:
            raise DeliveryError("verified changes produced no commit to deliver")
        head = self._git(context, "rev-parse", "HEAD").stdout.strip()
        committed_files = tuple(sorted(_git_lines(context.workspace, "diff", "--name-only", "origin/main...HEAD")))
        if committed_files != context.changed_files:
            raise DeliveryError("committed paths do not match the trusted Harness evidence")
        if git_changes_sha256(context.workspace, head, context.changed_files) != context.changes_sha256:
            raise DeliveryError("committed tree does not match the trusted Harness evidence")
        self._check_claim(context)
        helper = f"!{shlex.quote(self.gh)} auth git-credential"
        self._git(context, "-c", f"credential.helper={helper}", "push", "--set-upstream", "origin", branch)
        self._write_state(context, "delivering", controller_head=head)

        existing = json.loads(
            self._gh(
                ["pr", "list", "--repo", self.repository, "--head", branch, "--state", "open", "--json", "number,url", "--limit", "1"],
                cwd=context.workspace,
            )
            or "[]"
        )
        title = self._gh(
            ["issue", "view", str(context.issue_number), "--repo", self.repository, "--json", "title", "--jq", ".title"],
            cwd=context.workspace,
        )
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as body_file:
            body_file.write(render_pull_request_body(context))
            body_path = body_file.name
        try:
            if existing:
                self._gh(
                    [
                        "pr", "edit", str(existing[0]["number"]), "--repo", self.repository,
                        "--title", f"{context.linear_issue}: {title}", "--body-file", body_path,
                    ],
                    cwd=context.workspace,
                )
                return str(existing[0]["url"])
            return self._gh(
                [
                    "pr", "create", "--repo", self.repository, "--base", "main", "--head", branch,
                    "--title", f"{context.linear_issue}: {title}", "--body-file", body_path,
                ],
                cwd=context.workspace,
            )
        finally:
            Path(body_path).unlink(missing_ok=True)

    def process(self, workspace: Path) -> bool:
        context = load_delivery_context(workspace, self.preflight_root)
        state_path = self._state_path(context.workspace)
        state = _read_json(state_path, "delivery state") if state_path.is_file() else {}
        if not should_process(state, context.handoff_sha256):
            return False
        try:
            self._check_claim(context)
            if context.kind == "no-change":
                if state.get("pull_request"):
                    raise DeliveryError("existing PR requires a changes handoff")
                self._comment(context, f"Worker reports: {context.summary}\n\nNo repository change or PR; human acceptance is required.")
                self._release_claim(context)
                self._set_triage(context, "ready-for-human")
                self._write_state(context, "ready-for-human")
                return True
            self.preflight_root.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(prefix="delivery-", dir=self.preflight_root.parent) as temporary:
                snapshot = self._snapshot(context, Path(temporary) / context.workspace.name, state)
                pull_request = self._deliver_changes(snapshot)
                head = self._git(snapshot, "rev-parse", "HEAD").stdout.strip()
            self._release_claim(context)
            self._set_triage(context, None)
            issue = self._issue(context)
            metadata = json.dumps({
                "issue": context.issue_number,
                "pr": int(pull_request.rstrip("/").split("/")[-1]),
                "head": head,
                "body_sha256": context.contract_sha256,
            }, sort_keys=True)
            self._comment(
                context,
                f"<!-- insightkit-controller:{metadata} -->\nController handoff created {pull_request}. Worker reports full Harness and review passed; isolated current-head CI must pass before `ready-for-human`.",
            )
            self._write_state(context, "pending-ci", pull_request=pull_request, controller_head=head)
            return True
        except DeliveryError as exc:
            latest = _read_json(state_path, "delivery state") if state_path.is_file() else state
            preserved = {"pull_request": latest["pull_request"]} if latest.get("pull_request") else {}
            self._write_state(
                context,
                "failed",
                error=str(exc)[:500],
                controller_head=str(latest.get("controller_head") or ""),
                **preserved,
            )
            raise


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preflight-root", type=Path, required=True)
    parser.add_argument("--repo", default="YannJY02/AutoTranscribe")
    parser.add_argument("--gh", default=shutil.which("gh") or "gh")
    subparsers = parser.add_subparsers(dest="command", required=True)
    after_parser = subparsers.add_parser("after-run")
    after_parser.add_argument("--workspace", type=Path, required=True)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    controller = DeliveryController(preflight_root=args.preflight_root, repository=args.repo, gh=args.gh)
    try:
        if not (args.workspace.expanduser() / ".symphony" / "handoff.json").is_file():
            return 0
        controller.process(args.workspace)
        return 0
    except (DeliveryError, ValueError, OSError) as exc:
        print(str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
