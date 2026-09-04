#!/usr/bin/env python3
"""Repository-owned checks and feedback loops for unattended coding agents."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Sequence


ROOT = Path(__file__).resolve().parent.parent
REQUIRED_ISSUE_SECTIONS = (
    "Goal",
    "Context",
    "Boundary",
    "Acceptance",
    "Verification",
    "Resource class",
    "Blockers",
    "Human gates",
)
RESOURCE_CLASSES = ("isolated", "exclusive-macos")
TRIAGE_LABELS = {"needs-triage", "needs-info", "ready-for-agent", "ready-for-human", "wontfix"}
RESOURCE_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
HEADING_RE = re.compile(r"^#{2,3}\s+(?P<heading>.+?)\s*$", re.MULTILINE)
ISSUE_NUMBER_RE = re.compile(r"(?P<number>\d+)$")
BLOCKER_RE = re.compile(r"(?<![\w/])#(?P<number>\d+)\b")
LINEAR_ISSUE_LINK_RE = re.compile(r"https://linear\.app/[^/\s\"']+/issue/(?P<identifier>[A-Z][A-Z0-9]*-\d+)\b")
NO_BLOCKERS = {"none", "none.", "n/a", "not applicable"}


@dataclass(frozen=True)
class GateSpec:
    name: str
    commands: tuple[tuple[str, ...], ...]


@dataclass
class CommandResult:
    command: list[str]
    exit_code: int
    duration_seconds: float

    @property
    def ok(self) -> bool:
        return self.exit_code == 0


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def parse_issue_number(value: str) -> int:
    match = ISSUE_NUMBER_RE.search(value.strip())
    if not match:
        raise ValueError(f"invalid issue identifier: {value!r}")
    return int(match.group("number"))


def markdown_sections(body: str) -> dict[str, str]:
    matches = list(HEADING_RE.finditer(body or ""))
    sections: dict[str, str] = {}
    for index, match in enumerate(matches):
        start = match.end()
        end = matches[index + 1].start() if index + 1 < len(matches) else len(body)
        sections[match.group("heading").strip().casefold()] = body[start:end].strip()
    return sections


def _label_names(payload: dict[str, Any]) -> set[str]:
    names: set[str] = set()
    for label in payload.get("labels") or []:
        names.add(str(label.get("name", "") if isinstance(label, dict) else label))
    return names


def linear_issue_identifier(payload: dict[str, Any]) -> str | None:
    for comment in payload.get("comments") or []:
        if not isinstance(comment, dict):
            continue
        author = comment.get("author") or {}
        if not isinstance(author, dict) or author.get("login") != "linear-code":
            continue
        match = LINEAR_ISSUE_LINK_RE.search(str(comment.get("body") or ""))
        if match:
            return match.group("identifier")
    return None


def validate_issue(payload: dict[str, Any], *, allowed_assignee_login: str | None = None) -> list[str]:
    errors: list[str] = []
    if str(payload.get("state", "")).upper() != "OPEN":
        errors.append("issue must be open")
    active_triage_labels = _label_names(payload) & TRIAGE_LABELS
    if active_triage_labels != {"ready-for-agent"}:
        errors.append("issue triage state must be exactly ready-for-agent")
    assignee_logins = {
        str(assignee.get("login", ""))
        for assignee in payload.get("assignees") or []
        if isinstance(assignee, dict)
    }
    if assignee_logins and assignee_logins != {allowed_assignee_login}:
        errors.append("issue must be unassigned before an unattended agent claims it")

    sections = markdown_sections(str(payload.get("body") or ""))
    for heading in REQUIRED_ISSUE_SECTIONS:
        if not sections.get(heading.casefold(), "").strip():
            errors.append(f"missing or empty issue section: {heading}")

    resource_text = sections.get("resource class", "").casefold()
    selected = [resource for resource in RESOURCE_CLASSES if re.search(rf"\b{re.escape(resource)}\b", resource_text)]
    if len(selected) != 1:
        errors.append("Resource class must name exactly one resource class: isolated or exclusive-macos")

    human_gates = sections.get("human gates", "").strip().casefold()
    if human_gates and human_gates not in {"none", "none.", "n/a", "not applicable"}:
        errors.append("ready-for-agent issue still contains a human gate")

    blockers = sections.get("blockers", "").strip()
    blocker_contract = re.sub(r"^blocked\s+by:\s*", "", blockers, count=1, flags=re.IGNORECASE)
    blocker_remainder = BLOCKER_RE.sub("", blocker_contract).strip(" \t\r\n,.;-*")
    has_issue_blocker = bool(blocker_numbers(str(payload.get("body") or "")))
    if blockers.casefold() not in NO_BLOCKERS and (not has_issue_blocker or blocker_remainder):
        errors.append("Blockers must be None or contain only explicit #<issue> references")
    return errors


def blocker_numbers(body: str) -> list[int]:
    blockers = markdown_sections(body).get("blockers", "")
    return sorted({int(match.group("number")) for match in BLOCKER_RE.finditer(blockers)})


def _run_json(command: Sequence[str], *, cwd: Path = ROOT) -> Any:
    completed = subprocess.run(command, cwd=cwd, text=True, capture_output=True, check=False)
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout).strip()
        raise RuntimeError(f"command failed ({' '.join(command)}): {detail}")
    return json.loads(completed.stdout)


def load_issue(issue_number: int) -> dict[str, Any]:
    return _run_json(
        [
            "gh",
            "issue",
            "view",
            str(issue_number),
            "--json",
            "number,title,body,state,labels,assignees,comments,url",
        ]
    )


def issue_preflight(issue_identifier: str, *, resume: bool = False, retry: bool = False) -> dict[str, Any]:
    number = parse_issue_number(issue_identifier)
    payload = load_issue(number)
    retry_conflict = retry and bool(_label_names(payload) & TRIAGE_LABELS)
    candidate = dict(payload)
    if retry:
        candidate["labels"] = [
            label
            for label in payload.get("labels") or []
            if str(label.get("name", "") if isinstance(label, dict) else label) not in TRIAGE_LABELS
        ] + [{"name": "ready-for-agent"}]
    current_login = str(_run_json(["gh", "api", "user"]).get("login", "")) if resume else None
    errors = validate_issue(candidate, allowed_assignee_login=current_login)
    if retry_conflict:
        errors.append("CI retry preflight requires no active triage label")
    linear_issue = linear_issue_identifier(payload)
    if not linear_issue:
        errors.append("synchronized issue is missing the verified Linear linkback")
    blocker_states: list[dict[str, Any]] = []
    for blocker in blocker_numbers(str(payload.get("body") or "")):
        blocker_payload = _run_json(["gh", "issue", "view", str(blocker), "--json", "number,state,url"])
        blocker_states.append(blocker_payload)
        if str(blocker_payload.get("state", "")).upper() != "CLOSED":
            errors.append(f"blocker #{blocker} is still open")

    return {
        "status": "passed" if not errors else "failed",
        "issue": number,
        "linear_issue": linear_issue,
        "body_sha256": hashlib.sha256(str(payload.get("body") or "").encode()).hexdigest(),
        "url": payload.get("url"),
        "resource_class": next(
            (
                resource
                for resource in RESOURCE_CLASSES
                if resource in markdown_sections(str(payload.get("body") or "")).get("resource class", "").casefold()
            ),
            None,
        ),
        "blockers": blocker_states,
        "errors": errors,
    }


def gate_specs(changed_files: Sequence[str], *, mode: str, python_executable: str) -> list[GateSpec]:
    files = tuple(sorted(set(changed_files)))
    gates = [
        GateSpec(
            "diff-check",
            (("git", "diff", "--check"), ("git", "diff", "--cached", "--check")),
        )
    ]
    governance = any(
        path == "AGENTS.md"
        or path == "WORKFLOW.md"
        or path.startswith("docs/")
        or path.startswith(".github/")
        or path.startswith(".codex/")
        or path == "scripts/agent_harness.py"
        or path == "scripts/agent_bootstrap.sh"
        or path == "scripts/harness_maintenance.py"
        or path == "scripts/native_app_proof.py"
        or path == "scripts/run_symphony.sh"
        or path == "scripts/symphony_after_run.sh"
        or path == "scripts/symphony_delivery_controller.py"
        or path == "scripts/symphony_issue_gate.sh"
        or path == "tests/test_agent_harness.py"
        or path == "tests/test_harness_maintenance.py"
        or path == "tests/test_native_app_proof.py"
        or path == "tests/test_symphony_delivery_controller.py"
        for path in files
    )
    shell_scripts = tuple(path for path in files if path.endswith(".sh"))
    python_project_changed = "pyproject.toml" in files
    python_changed = python_project_changed or any(
        path.endswith(".py") and not path.startswith("tests/test_agent_harness.py") for path in files
    )
    swift_changed = any(
        (path.endswith(".swift") and not path.startswith("macos/InsightKitApp/UITests/"))
        or path in {"macos/InsightKitApp/Package.swift", "macos/InsightKitApp/Package.resolved"}
        for path in files
    )
    xcuitests_changed = any(
        path.startswith("macos/InsightKitApp/UITests/")
        or path == "macos/InsightKitApp/project.yml"
        or path == "scripts/run_uitests.sh"
        for path in files
    )
    architecture_changed = any(
        path.startswith("insightkit/ipc/")
        or path.startswith("insightkit/integration/")
        or "RPC" in path
        or "Sidecar" in path
        for path in files
    )

    if shell_scripts:
        gates.append(
            GateSpec(
                "automation-syntax",
                tuple(
                    (
                        "sh" if path in {
                            "scripts/run_symphony.sh",
                            "scripts/symphony_after_run.sh",
                            "scripts/symphony_issue_gate.sh",
                        } else "bash",
                        "-n",
                        path,
                    )
                    for path in shell_scripts
                ),
            )
        )
    if governance:
        gates.append(
            GateSpec(
                "harness-tests",
                ((python_executable, "-m", "pytest", "-q", "tests/test_agent_harness.py", "tests/test_verify_project_normalization.py"),),
            )
        )
    if mode == "full" and python_changed:
        commands: list[tuple[str, ...]] = []
        if python_project_changed:
            commands.append(("./scripts/agent_bootstrap.sh",))
        commands.append(
            (
                python_executable,
                "-m",
                "pytest",
                "tests",
                "-q",
                "--tb=short",
                "-m",
                "not integration and not requires_model and not slow",
            )
        )
        gates.append(
            GateSpec(
                "python-tests",
                tuple(commands),
            )
        )
    if mode == "full" and swift_changed:
        gates.append(GateSpec("swift-tests", (("swift", "test", "--package-path", "macos/InsightKitApp"),)))
    if mode == "full" and xcuitests_changed:
        gates.append(
            GateSpec(
                "xcuitests",
                (
                    (
                        python_executable,
                        "scripts/agent_harness.py",
                        "lock",
                        "--resource",
                        "installed-app",
                        "--timeout",
                        "1800",
                        "--",
                        "./scripts/run_uitests.sh",
                    ),
                ),
            )
        )
    if governance:
        gates.append(
            GateSpec(
                "project-normalization",
                (
                    (
                        python_executable,
                        "scripts/verify_project_normalization.py",
                        "--output-root",
                        "{output_root}/project-normalization",
                    ),
                ),
            )
        )
    if mode == "full" and architecture_changed:
        gates.append(
            GateSpec(
                "architecture-contracts",
                (
                    (
                        python_executable,
                        "scripts/verify_runtime_action_boundary.py",
                        "--output-dir",
                        "{output_root}/runtime-action-boundary",
                    ),
                    (
                        python_executable,
                        "scripts/verify_sidecar_action_registry.py",
                    ),
                    (
                        python_executable,
                        "scripts/verify_runtime_compatibility_cleanup.py",
                    ),
                ),
            )
        )
    return gates


def changed_files(base: str) -> list[str]:
    commands = (
        ["git", "diff", "--name-only", f"{base}...HEAD"],
        ["git", "diff", "--name-only"],
        ["git", "diff", "--cached", "--name-only"],
        ["git", "ls-files", "--others", "--exclude-standard"],
    )
    paths: set[str] = set()
    for command in commands:
        completed = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, check=False)
        if completed.returncode != 0:
            raise RuntimeError((completed.stderr or completed.stdout).strip())
        paths.update(line.strip() for line in completed.stdout.splitlines() if line.strip())
    return sorted(paths)


def changes_sha256(root: Path, paths: Sequence[str]) -> str:
    digest = hashlib.sha256()

    def add(value: bytes) -> None:
        digest.update(len(value).to_bytes(8, "big"))
        digest.update(value)

    root = root.expanduser().resolve()
    for relative in sorted(set(paths)):
        path = Path(relative)
        if not relative or path.is_absolute() or ".." in path.parts or any(char in relative for char in "\r\n\x00"):
            raise ValueError(f"unsafe changed path: {relative!r}")
        candidate = root / path
        add(relative.encode("utf-8"))
        try:
            metadata = candidate.lstat()
        except FileNotFoundError:
            add(b"missing")
            continue
        if candidate.is_symlink():
            raise ValueError(f"changed path must not be a symbolic link: {relative}")
        if not candidate.is_file():
            raise ValueError(f"changed path is not a regular file: {relative}")
        add(b"executable" if metadata.st_mode & 0o111 else b"file")
        digest.update(metadata.st_size.to_bytes(8, "big"))
        with candidate.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
    return digest.hexdigest()


def git_changes_sha256(root: Path, revision: str, paths: Sequence[str]) -> str:
    digest = hashlib.sha256()

    def add(value: bytes) -> None:
        digest.update(len(value).to_bytes(8, "big"))
        digest.update(value)

    root = root.expanduser().resolve()
    for relative in sorted(set(paths)):
        path = Path(relative)
        if not relative or path.is_absolute() or ".." in path.parts or any(char in relative for char in "\r\n\x00"):
            raise ValueError(f"unsafe changed path: {relative!r}")
        tree = subprocess.run(
            ["git", "ls-tree", "-z", revision, "--", relative],
            cwd=root,
            capture_output=True,
            check=False,
        )
        if tree.returncode != 0:
            raise ValueError(f"cannot inspect committed path: {relative}")
        add(relative.encode("utf-8"))
        if not tree.stdout:
            add(b"missing")
            continue
        header, separator, returned_path = tree.stdout.rstrip(b"\x00").partition(b"\t")
        fields = header.split()
        if separator != b"\t" or len(fields) != 3 or returned_path != relative.encode("utf-8"):
            raise ValueError(f"unexpected Git tree entry: {relative}")
        mode, kind, object_id = fields
        if kind != b"blob" or mode not in {b"100644", b"100755"}:
            raise ValueError(f"committed path must be a regular file: {relative}")
        blob = subprocess.run(
            ["git", "cat-file", "blob", object_id.decode("ascii")],
            cwd=root,
            capture_output=True,
            check=False,
        )
        if blob.returncode != 0:
            raise ValueError(f"cannot read committed path: {relative}")
        add(b"executable" if mode == b"100755" else b"file")
        add(blob.stdout)
    return digest.hexdigest()


def _run_command(command: Sequence[str], *, output_root: Path) -> CommandResult:
    rendered = [part.replace("{output_root}", str(output_root)) for part in command]
    env = os.environ.copy()
    env["PYTHONPATH"] = str(ROOT)
    started = time.monotonic()
    completed = subprocess.run(rendered, cwd=ROOT, check=False, env=env)
    return CommandResult(
        command=rendered,
        exit_code=completed.returncode,
        duration_seconds=round(time.monotonic() - started, 3),
    )


def _git_value(*args: str) -> str:
    completed = subprocess.run(["git", *args], cwd=ROOT, text=True, capture_output=True, check=False)
    return completed.stdout.strip() if completed.returncode == 0 else "unknown"


def installed_app_snapshot(app_path: Path, *, expected_revision: str) -> dict[str, Any]:
    plist_path = app_path.expanduser() / "Contents" / "Info.plist"
    if not plist_path.is_file():
        return {
            "installed": False,
            "path": str(app_path.expanduser()),
            "freshness": "missing",
            "posthog_transport_ready": False,
        }
    try:
        info = plistlib.loads(plist_path.read_bytes())
    except (OSError, plistlib.InvalidFileException, ValueError):
        return {
            "installed": True,
            "path": str(app_path.expanduser()),
            "freshness": "unknown",
            "posthog_transport_ready": False,
        }

    installed_revision = str(info.get("InsightKitGitRevision") or "")
    revision_matches = bool(installed_revision and expected_revision != "unknown") and (
        expected_revision.startswith(installed_revision) or installed_revision.startswith(expected_revision)
    )
    return {
        "installed": True,
        "path": str(app_path.expanduser()),
        "short_version": str(info.get("CFBundleShortVersionString") or ""),
        "build_version": str(info.get("CFBundleVersion") or ""),
        "git_revision": installed_revision,
        "freshness": "current" if revision_matches else "stale" if installed_revision else "unknown",
        "posthog_transport_ready": bool(
            info.get("InsightKitPostHogOwnerPilotHost")
            and info.get("InsightKitPostHogOwnerPilotProjectKey")
            and info.get("InsightKitPostHogOwnerPilotRetentionVerified") is True
        ),
    }


def telemetry_snapshot(telemetry_root: Path) -> dict[str, bool]:
    root = telemetry_root.expanduser()
    return {
        "product_analytics_ledger_exists": (root / "local-evidence-ledger-v1.json").is_file(),
        "sentry_disable_evidence_exists": (root / "Sentry" / "external-telemetry-disable-evidence-v1.json").is_file(),
    }


def _symphony_snapshot(url: str) -> dict[str, Any]:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "http" or parsed.hostname not in {"127.0.0.1", "localhost", "::1"}:
        raise ValueError("Symphony status URL must use HTTP on a loopback host")
    try:
        with urllib.request.urlopen(url, timeout=2) as response:  # noqa: S310 - loopback URL is operator supplied.
            payload = json.loads(response.read(1_000_000))
    except (OSError, ValueError, urllib.error.URLError):
        return {"healthy": False}
    state = payload.get("state", payload) if isinstance(payload, dict) else {}
    return {
        "healthy": True,
        "running_count": len(state.get("running") or []),
        "blocked_count": len(state.get("blocked") or []),
        "retrying_count": len(state.get("retrying") or []),
    }


def runtime_status(*, app_path: Path, telemetry_root: Path, symphony_url: str) -> dict[str, Any]:
    revision = _git_value("rev-parse", "HEAD")
    command = ["git", "ls-remote", "origin", "refs/heads/main"]
    try:
        remote = subprocess.run(
            command,
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        remote = subprocess.CompletedProcess(command, 124, "", "")
    remote_revision = remote.stdout.split()[0] if remote.returncode == 0 and remote.stdout.split() else ""
    expected_revision = remote_revision or revision
    installed = installed_app_snapshot(app_path, expected_revision=expected_revision)
    try:
        process = subprocess.run(["pgrep", "-x", "InsightKitApp"], capture_output=True, check=False)
    except OSError:
        process = subprocess.CompletedProcess(["pgrep"], 1)
    dirty = subprocess.run(
        ["git", "status", "--porcelain"], cwd=ROOT, text=True, capture_output=True, check=False
    )
    installed["running"] = process.returncode == 0
    symphony = _symphony_snapshot(symphony_url)
    payload = {
        "schema_version": 1,
        "observed_at": utc_now(),
        "repository": {
            "revision": revision,
            "branch": _git_value("branch", "--show-current"),
            "dirty": bool(dirty.stdout.strip()) if dirty.returncode == 0 else None,
            "main_revision": expected_revision,
            "main_revision_source": "remote" if remote_revision else "local-head-fallback",
            "checkout_current": revision == expected_revision,
        },
        "installed_app": installed,
        "telemetry": telemetry_snapshot(telemetry_root),
        "symphony": symphony,
    }
    payload["status"] = "passed" if installed["freshness"] == "current" and symphony["healthy"] else "degraded"
    return payload


def _write_json_atomic(path: Path, payload: dict[str, Any]) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.chmod(0o600)
    temporary.replace(path)
    return path


def _bounded_text(value: str, *, name: str, maximum: int) -> str:
    text = value.strip()
    if not text or len(text) > maximum or any(character in text for character in "\r\n\x00"):
        raise ValueError(f"{name} must be one non-empty line of at most {maximum} characters")
    return text


def write_controller_handoff(
    *,
    root: Path,
    issue: str,
    manifest_path: Path,
    summary: str,
    review_status: str,
    human_gates: Sequence[str],
    no_change: bool,
) -> Path:
    workspace = root.expanduser().resolve()
    manifest = manifest_path.expanduser().resolve()
    try:
        relative_manifest = manifest.relative_to(workspace)
    except ValueError as exc:
        raise ValueError("manifest must stay inside the workspace") from exc
    try:
        evidence = json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"cannot read harness manifest: {manifest}") from exc
    issue_number = parse_issue_number(issue)
    changed = evidence.get("changed_files") or []
    if not isinstance(changed, list) or any(not isinstance(path, str) for path in changed):
        raise ValueError("manifest changed files must be repository-relative paths")
    if evidence.get("schema_version") != 1:
        raise ValueError("unsupported harness manifest schema version")
    if evidence.get("status") != "passed" or evidence.get("issue") != issue_number:
        raise ValueError("handoff requires a passed manifest for the same issue")
    if evidence.get("mode") != "full":
        raise ValueError("handoff requires a full-mode harness manifest")
    if Path(str(evidence.get("workspace") or "")).resolve() != workspace:
        raise ValueError("handoff manifest belongs to a different workspace")
    if no_change != (not changed):
        raise ValueError("--no-change must match the manifest changed files")
    expected_digest = str(evidence.get("changes_sha256") or "")
    if not re.fullmatch(r"[0-9a-f]{64}", expected_digest) or changes_sha256(workspace, changed) != expected_digest:
        raise ValueError("manifest does not match the verified file contents")
    if review_status not in {"clear", "not-required"} or (changed and review_status != "clear"):
        raise ValueError("changed code requires a clear independent review")
    gates = evidence.get("gates") or []
    if not isinstance(gates, list) or not gates or any(
        not isinstance(gate, dict) or gate.get("status") != "passed" for gate in gates
    ):
        raise ValueError("all manifest gates must pass before handoff")

    payload = {
        "schema_version": 1,
        "status": "ready",
        "issue": f"GH-{issue_number}",
        "summary": _bounded_text(summary, name="summary", maximum=200),
        "kind": "no-change" if no_change else "changes",
        "manifest": relative_manifest.as_posix(),
        "review_status": review_status,
        "human_gates": [
            _bounded_text(gate, name="human gate", maximum=300) for gate in human_gates
        ],
        "generated_at": utc_now(),
    }
    return _write_json_atomic(workspace / ".symphony" / "handoff.json", payload)


def verify_changes(*, base: str, mode: str, issue: str | None, output_root: Path, dry_run: bool) -> dict[str, Any]:
    files = changed_files(base)
    python_executable = str(ROOT / ".venv/bin/python") if (ROOT / ".venv/bin/python").exists() else sys.executable
    gates = gate_specs(files, mode=mode, python_executable=python_executable)
    if gates and gates[0].name == "diff-check":
        gates[0] = GateSpec(
            "diff-check",
            (
                ("git", "diff", "--check"),
                ("git", "diff", "--cached", "--check"),
                ("git", "diff", "--check", f"{base}...HEAD"),
            ),
        )

    manifest: dict[str, Any] = {
        "schema_version": 1,
        "generated_at": utc_now(),
        "status": "planned" if dry_run else "running",
        "issue": parse_issue_number(issue) if issue else None,
        "base": base,
        "commit": _git_value("rev-parse", "HEAD"),
        "branch": _git_value("branch", "--show-current"),
        "workspace": str(ROOT),
        "changed_files": files,
        "changes_sha256": changes_sha256(ROOT, files),
        "mode": mode,
        "gates": [],
    }
    if dry_run:
        manifest["gates"] = [{"name": gate.name, "commands": [list(command) for command in gate.commands]} for gate in gates]
        return manifest

    output_root.mkdir(parents=True, exist_ok=True)
    failed = False
    for gate in gates:
        gate_results: list[CommandResult] = []
        for command in gate.commands:
            result = _run_command(command, output_root=output_root)
            gate_results.append(result)
            if not result.ok:
                failed = True
                break
        manifest["gates"].append(
            {
                "name": gate.name,
                "status": "passed" if gate_results and all(item.ok for item in gate_results) else "failed",
                "commands": [asdict(item) | {"ok": item.ok} for item in gate_results],
            }
        )
        if failed:
            break
    manifest["status"] = "failed" if failed else "passed"
    manifest["finished_at"] = utc_now()
    (output_root / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return manifest


def doctor(*, profile: str) -> dict[str, Any]:
    required_files = (
        "AGENTS.md",
        "CONTEXT-MAP.md",
        "WORKFLOW.md",
        "docs/agents/harness.md",
        "docs/agents/issue-tracker.md",
        "docs/agents/loop-engineering.md",
        "docs/agents/tool-boundaries.md",
        ".agents/skills/native-app-proof/SKILL.md",
        ".agents/skills/promote-feedback/SKILL.md",
        ".github/ISSUE_TEMPLATE/agent-task.yml",
        ".github/workflows/ci.yml",
        ".github/workflows/controller-handoff.yml",
        "scripts/agent_bootstrap.sh",
        "scripts/harness_maintenance.py",
        "scripts/native_app_proof.py",
        "scripts/symphony_issue_gate.sh",
        "scripts/symphony_after_run.sh",
        "scripts/symphony_delivery_controller.py",
    )
    required_commands = ["git", "python3.11"]
    if profile in {"local", "symphony"}:
        required_commands.extend(["gh", "codex", "symphony", "swift", "xcodegen"])
    if profile == "app-proof":
        required_commands.extend(["xcodebuild", "xcrun", "xcodegen"])

    checks: list[dict[str, Any]] = []
    for relative in required_files:
        exists = (ROOT / relative).exists()
        checks.append({"check": f"file:{relative}", "ok": exists, "detail": "present" if exists else "missing"})
    for command in required_commands:
        resolved = shutil.which(command)
        checks.append({"check": f"command:{command}", "ok": bool(resolved), "detail": resolved or "not found"})
    for path in (Path("/usr/sbin/screencapture"), Path("/usr/bin/log")) if profile == "app-proof" else ():
        checks.append(
            {
                "check": f"file:{path}",
                "ok": path.is_file(),
                "detail": "present" if path.is_file() else "missing",
            }
        )
    if profile == "app-proof":
        probes = (
            ("xcodebuild", "-version"),
            ("xcrun", "--find", "xcresulttool"),
            ("xcrun", "--find", "xctrace"),
        )
        failures: list[str] = []
        for probe in probes:
            try:
                completed = subprocess.run(probe, text=True, capture_output=True, check=False)
            except OSError:
                failures.append(" ".join(probe))
                continue
            if completed.returncode != 0:
                failures.append(" ".join(probe))
        checks.append(
            {
                "check": "xcode-runtime",
                "ok": not failures,
                "detail": "full Xcode tools available" if not failures else {"failed": failures},
            }
        )

    text_checks = (
        ("AGENTS.md", "canonical task, PRD, priority, and detailed-status source", True),
        ("AGENTS.md", "GitHub Issues", True),
        ("docs/agents/issue-tracker.md", "canonical task and PRD source", True),
        ("docs/agents/loop-engineering.md", "GitHub Issue", True),
        ("WORKFLOW.md", "max_concurrent_agents: 2", True),
        ("WORKFLOW.md", "shell_environment_policy.inherit=core", True),
        (".codex/environments/environment.toml", 'script = "./scripts/agent_bootstrap.sh"', True),
        ("scripts/run_symphony.sh", "SYMPHONY_GITHUB_TOKEN", True),
        ("scripts/run_symphony.sh", "agent-github-token", False),
        ("scripts/symphony_after_run.sh", "agent-github-token", True),
        ("scripts/run_symphony.sh", "gh auth token", False),
        ("AGENTS.md", "tracked as local markdown files", False),
    )
    for relative, needle, expected in text_checks:
        path = ROOT / relative
        present = path.exists() and needle in path.read_text(encoding="utf-8")
        checks.append(
            {
                "check": f"text:{relative}:{needle}",
                "ok": present is expected,
                "detail": "matched" if present is expected else "authority drift",
            }
        )

    hardcoded_paths: list[str] = []
    workflows_root = ROOT / ".agents/workflows"
    for path in sorted(workflows_root.glob("*.md")) if workflows_root.exists() else []:
        if "/Users/" in path.read_text(encoding="utf-8"):
            hardcoded_paths.append(str(path.relative_to(ROOT)))
    checks.append(
        {
            "check": "worktree-safe-workflows",
            "ok": not hardcoded_paths,
            "detail": hardcoded_paths or "no hardcoded checkout paths",
        }
    )
    return {"status": "passed" if all(item["ok"] for item in checks) else "failed", "profile": profile, "checks": checks}


def run_with_lock(*, resource: str, timeout: float, command: Sequence[str]) -> int:
    if not RESOURCE_RE.fullmatch(resource):
        raise ValueError("resource must contain only lowercase letters, digits, and hyphens")
    if not command:
        raise ValueError("lock requires a command after --")
    lock_path = Path(tempfile.gettempdir()) / f"insightkit-agent-{os.getuid()}-{resource}.lock"
    with lock_path.open("a+", encoding="utf-8") as lock_file:
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    print(f"timed out waiting for resource lock: {resource}", file=sys.stderr)
                    return 75
                time.sleep(0.1)
        lock_file.seek(0)
        lock_file.truncate()
        lock_file.write(json.dumps({"pid": os.getpid(), "resource": resource, "acquired_at": utc_now()}) + "\n")
        lock_file.flush()
        return subprocess.run(command, cwd=ROOT, check=False).returncode


def default_output_root() -> Path:
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    return ROOT / "logs" / "harness" / stamp


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    doctor_parser = subparsers.add_parser("doctor", help="Check the local harness contract and required tools.")
    doctor_parser.add_argument("--profile", choices=("local", "ci", "symphony", "app-proof"), default="local")
    doctor_parser.add_argument("--json", action="store_true")

    issue_parser = subparsers.add_parser("issue-preflight", help="Validate a GitHub issue before unattended execution.")
    issue_parser.add_argument("--issue", required=True)
    issue_parser.add_argument("--resume", action="store_true", help="Allow assignment to the current GitHub user.")
    issue_parser.add_argument("--retry", action="store_true", help="Validate whether failed CI may safely restore ready-for-agent.")
    issue_parser.add_argument("--json", action="store_true")

    verify_parser = subparsers.add_parser("verify", help="Run the narrow deterministic gates for the current diff.")
    verify_parser.add_argument("--base", default="origin/main")
    verify_parser.add_argument("--mode", choices=("quick", "full"), default="full")
    verify_parser.add_argument("--issue")
    verify_parser.add_argument("--output-root", type=Path, default=None)
    verify_parser.add_argument("--dry-run", action="store_true")

    handoff_parser = subparsers.add_parser("handoff", help="Write a bounded handoff for the host controller.")
    handoff_parser.add_argument("--issue", required=True)
    handoff_parser.add_argument("--manifest", type=Path, required=True)
    handoff_parser.add_argument("--summary", required=True)
    handoff_parser.add_argument("--review-status", choices=("clear", "not-required"), required=True)
    handoff_parser.add_argument("--human-gate", action="append", default=[])
    handoff_parser.add_argument("--no-change", action="store_true")

    runtime_parser = subparsers.add_parser("runtime-status", help="Snapshot installed-app and automation freshness.")
    runtime_parser.add_argument("--app", type=Path, default=Path("~/Applications/InsightKit.app"))
    runtime_parser.add_argument(
        "--telemetry-root",
        type=Path,
        default=Path("~/Library/Application Support/InsightKit/Telemetry"),
    )
    runtime_parser.add_argument("--symphony-url", default="http://127.0.0.1:4000/api/v1/state")
    runtime_parser.add_argument("--output", type=Path)
    runtime_parser.add_argument("--require-fresh", action="store_true")
    runtime_parser.add_argument("--json", action="store_true")

    lock_parser = subparsers.add_parser("lock", help="Run a command while holding a cross-worktree resource lock.")
    lock_parser.add_argument("--resource", required=True)
    lock_parser.add_argument("--timeout", type=float, default=1800)
    lock_parser.add_argument("remainder", nargs=argparse.REMAINDER)

    return parser


def print_result(payload: dict[str, Any], *, as_json: bool) -> None:
    if as_json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return
    print(f"status: {payload['status']}")
    if payload.get("errors"):
        for error in payload["errors"]:
            print(f"- {error}")
    if payload.get("gates"):
        for gate in payload["gates"]:
            print(f"- {gate['name']}: {gate.get('status', 'planned')}")


def main() -> int:
    args = build_parser().parse_args()
    try:
        if args.command == "doctor":
            payload = doctor(profile=args.profile)
            print_result(payload, as_json=args.json)
            return 0 if payload["status"] == "passed" else 1
        if args.command == "issue-preflight":
            payload = issue_preflight(args.issue, resume=args.resume, retry=args.retry)
            print_result(payload, as_json=args.json)
            return 0 if payload["status"] == "passed" else 1
        if args.command == "verify":
            output_root = (args.output_root or default_output_root()).expanduser().resolve()
            payload = verify_changes(
                base=args.base,
                mode=args.mode,
                issue=args.issue,
                output_root=output_root,
                dry_run=args.dry_run,
            )
            print_result(payload, as_json=False)
            if not args.dry_run:
                print(f"manifest: {output_root / 'manifest.json'}")
            return 0 if payload["status"] in {"passed", "planned"} else 1
        if args.command == "handoff":
            path = write_controller_handoff(
                root=ROOT,
                issue=args.issue,
                manifest_path=args.manifest,
                summary=args.summary,
                review_status=args.review_status,
                human_gates=args.human_gate,
                no_change=args.no_change,
            )
            print(path)
            return 0
        if args.command == "runtime-status":
            payload = runtime_status(
                app_path=args.app.expanduser(),
                telemetry_root=args.telemetry_root.expanduser(),
                symphony_url=args.symphony_url,
            )
            if args.output:
                _write_json_atomic(args.output.expanduser(), payload)
            print_result(payload, as_json=args.json)
            return 1 if args.require_fresh and payload["status"] != "passed" else 0
        if args.command == "lock":
            command = list(args.remainder)
            if command and command[0] == "--":
                command = command[1:]
            return run_with_lock(resource=args.resource, timeout=args.timeout, command=command)
    except (RuntimeError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        return 2
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
