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
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Sequence


TRIAGE_LABELS = {"needs-triage", "needs-info", "ready-for-agent", "ready-for-human", "wontfix"}
WORKSPACE_RE = re.compile(r"^GH-(?P<number>\d+)$")
LINEAR_RE = re.compile(r"^[A-Z][A-Z0-9]*-\d+$")
GATE_RE = re.compile(r"^[a-z][a-z0-9-]{0,63}$")
LOCAL_GIT_KEYS = {
    "core.repositoryformatversion",
    "core.filemode",
    "core.bare",
    "core.logallrefupdates",
    "core.ignorecase",
    "core.precomposeunicode",
    "remote.origin.url",
    "remote.origin.fetch",
    "branch.main.remote",
    "branch.main.merge",
}


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
    handoff_sha256: str


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
            or value.startswith(".git/")
            or any(character in value for character in "\r\n\x00`")
        ):
            raise DeliveryError(f"unsafe path in {label}: {value!r}")
    return paths


def _current_changes(workspace: Path) -> tuple[tuple[str, ...], tuple[str, ...]]:
    committed = _git_lines(workspace, "diff", "--name-only", "origin/main...HEAD", allow_failure=True)
    if not committed:
        committed = _git_lines(workspace, "diff", "--name-only", "HEAD")
    unstaged = _git_lines(workspace, "diff", "--name-only")
    staged = _git_lines(workspace, "diff", "--cached", "--name-only")
    untracked = _git_lines(workspace, "ls-files", "--others", "--exclude-standard")
    pending = unstaged | staged | untracked
    return tuple(sorted(committed | pending)), tuple(sorted(pending))


def load_delivery_context(workspace: Path, preflight_root: Path) -> DeliveryContext:
    workspace = workspace.expanduser().resolve()
    match = WORKSPACE_RE.fullmatch(workspace.name)
    if not match:
        raise DeliveryError("workspace must be named GH-<issue number>")
    issue_number = int(match.group("number"))
    handoff_path = workspace / ".symphony" / "handoff.json"
    try:
        handoff_bytes = handoff_path.read_bytes()
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

    manifest = _read_json(manifest_path, "harness manifest")
    preflight = _read_json(preflight_root.expanduser().resolve() / f"GH-{issue_number}.json", "issue preflight")
    if manifest.get("schema_version") != 1:
        raise DeliveryError("unsupported harness manifest schema version")
    if manifest.get("status") != "passed" or manifest.get("issue") != issue_number:
        raise DeliveryError("handoff requires a passed manifest for the same issue")
    if Path(str(manifest.get("workspace") or "")).resolve() != workspace:
        raise DeliveryError("harness manifest belongs to a different workspace")
    if preflight.get("status") != "passed" or preflight.get("issue") != issue_number:
        raise DeliveryError("issue preflight did not pass for this workspace")
    linear_issue = str(preflight.get("linear_issue") or "")
    if not LINEAR_RE.fullmatch(linear_issue):
        raise DeliveryError("issue preflight is missing a valid Linear identifier")

    changed_files = _safe_paths(manifest.get("changed_files"), "manifest changed files")
    actual_files, pending_files = _current_changes(workspace)
    if changed_files != actual_files:
        raise DeliveryError("manifest changed files do not match the current repository changes")
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
        pending_files=pending_files,
        gates=gates,
        human_gates=tuple(gate.strip() for gate in human_gates if gate.strip()),
        handoff_sha256=hashlib.sha256(handoff_bytes).hexdigest(),
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
        "## Verified changes",
        "",
        *[f"- `{path}`" for path in context.changed_files],
        "",
        "## Harness gates",
        "",
        *[f"- {gate}: passed" for gate in context.gates],
    ]
    if context.human_gates:
        lines.extend(["", "## Human gates", "", *[f"- {gate}" for gate in context.human_gates]])
    return "\n".join(lines).rstrip() + "\n"


class DeliveryController:
    def __init__(self, *, preflight_root: Path, repository: str, gh: str) -> None:
        self.preflight_root = preflight_root.expanduser().resolve()
        self.repository = repository
        self.gh = gh

    def _gh(self, args: Sequence[str], *, cwd: Path, input_text: str | None = None) -> str:
        return _run([self.gh, *args], cwd=cwd, input_text=input_text).stdout.strip()

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
        current = self._gh(
            ["api", f"repos/{self.repository}/issues/{context.issue_number}", "--jq", ".labels[].name"],
            cwd=context.workspace,
        ).splitlines()
        labels = [label for label in current if label not in TRIAGE_LABELS]
        if target:
            labels.append(target)
        self._gh(
            ["api", "--method", "PUT", f"repos/{self.repository}/issues/{context.issue_number}/labels", "--input", "-"],
            cwd=context.workspace,
            input_text=json.dumps({"labels": labels}),
        )

    def _comment(self, context: DeliveryContext, body: str) -> None:
        self._gh(
            ["issue", "comment", str(context.issue_number), "--repo", self.repository, "--body-file", "-"],
            cwd=context.workspace,
            input_text=body,
        )

    def _prepare_branch(self, context: DeliveryContext) -> str:
        desired = branch_name(context)
        current = self._git(context, "branch", "--show-current").stdout.strip()
        if current != desired:
            if current not in {"", "main"}:
                raise DeliveryError(f"refusing to replace unexpected branch: {current}")
            exists = self._git(
                context,
                "show-ref",
                "--verify",
                "--quiet",
                f"refs/heads/{desired}",
                check=False,
            ).returncode == 0
            self._git(context, *(("switch", desired) if exists else ("switch", "-c", desired)))
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

    def _validate_git_boundary(self, context: DeliveryContext, state: dict[str, Any]) -> None:
        git_dir = context.workspace / ".git"
        if not git_dir.is_dir() or git_dir.is_symlink():
            raise DeliveryError("workspace Git directory must be a local directory")
        keys = _git_lines(context.workspace, "config", "--local", "--name-only", "--list")
        unsafe = sorted(
            key
            for key in keys
            if key not in LOCAL_GIT_KEYS and not re.fullmatch(r"branch\..+\.(remote|merge)", key)
        )
        if unsafe:
            raise DeliveryError(f"workspace contains unsupported local Git configuration: {', '.join(unsafe)}")
        expected_origin = f"https://github.com/{self.repository}.git"
        origin = self._git(context, "config", "--local", "--get", "remote.origin.url").stdout.strip()
        if origin != expected_origin:
            raise DeliveryError("workspace origin does not match the configured repository")

        head = self._git(context, "rev-parse", "HEAD").stdout.strip()
        base = self._git(context, "rev-parse", "origin/main").stdout.strip()
        current_branch = self._git(context, "branch", "--show-current").stdout.strip()
        if head == base and current_branch in {"", "main"}:
            return
        if str(state.get("controller_head") or "") == head and current_branch == branch_name(context):
            return
        raise DeliveryError("workspace HEAD was not produced by the delivery controller")

    def _deliver_changes(self, context: DeliveryContext) -> str:
        branch = self._prepare_branch(context)
        if context.pending_files:
            self._git(context, "add", "--", *context.pending_files)
            self._git(context, "commit", "-m", f"{context.linear_issue}: {context.summary}")
        ahead = self._git(context, "rev-list", "--count", "origin/main..HEAD").stdout.strip()
        if int(ahead or "0") < 1:
            raise DeliveryError("verified changes produced no commit to deliver")
        head = self._git(context, "rev-parse", "HEAD").stdout.strip()
        self._write_state(context, "delivering", controller_head=head)
        helper = f"!{shlex.quote(self.gh)} auth git-credential"
        self._git(context, "-c", f"credential.helper={helper}", "push", "--set-upstream", "origin", branch)

        existing = json.loads(
            self._gh(
                ["pr", "list", "--repo", self.repository, "--head", branch, "--state", "open", "--json", "number,url", "--limit", "1"],
                cwd=context.workspace,
            )
            or "[]"
        )
        if existing:
            return str(existing[0]["url"])
        title = self._gh(
            ["issue", "view", str(context.issue_number), "--repo", self.repository, "--json", "title", "--jq", ".title"],
            cwd=context.workspace,
        )
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as body_file:
            body_file.write(render_pull_request_body(context))
            body_path = body_file.name
        try:
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
            if state.get("pull_request") and not context.pending_files:
                raise DeliveryError("a CI retry handoff must contain a new verified change")
            self._validate_git_boundary(context, state)
            if context.kind == "no-change":
                self._comment(context, f"Controller handoff: {context.summary}\n\nNo repository change or PR is required.")
                self._set_triage(context, "ready-for-human")
                self._write_state(context, "ready-for-human")
                return True
            pull_request = self._deliver_changes(context)
            self._set_triage(context, None)
            self._comment(
                context,
                f"Controller handoff created {pull_request}. CI is running; the task will move to `ready-for-human` only after current-head CI passes.",
            )
            head = self._git(context, "rev-parse", "HEAD").stdout.strip()
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
    except (DeliveryError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
