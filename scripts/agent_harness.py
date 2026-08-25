#!/usr/bin/env python3
"""Repository-owned checks and feedback loops for unattended coding agents."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
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
            "number,title,body,state,labels,assignees,url",
        ]
    )


def issue_preflight(issue_identifier: str, *, resume: bool = False) -> dict[str, Any]:
    number = parse_issue_number(issue_identifier)
    payload = load_issue(number)
    current_login = str(_run_json(["gh", "api", "user"]).get("login", "")) if resume else None
    errors = validate_issue(payload, allowed_assignee_login=current_login)
    blocker_states: list[dict[str, Any]] = []
    for blocker in blocker_numbers(str(payload.get("body") or "")):
        blocker_payload = _run_json(["gh", "issue", "view", str(blocker), "--json", "number,state,url"])
        blocker_states.append(blocker_payload)
        if str(blocker_payload.get("state", "")).upper() != "CLOSED":
            errors.append(f"blocker #{blocker} is still open")

    return {
        "status": "passed" if not errors else "failed",
        "issue": number,
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
        or path == "tests/test_agent_harness.py"
        or path == "tests/test_harness_maintenance.py"
        or path == "tests/test_native_app_proof.py"
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
                    ("sh" if path == "scripts/run_symphony.sh" else "bash", "-n", path)
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
        "scripts/agent_bootstrap.sh",
        "scripts/harness_maintenance.py",
        "scripts/native_app_proof.py",
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
        ("AGENTS.md", "GitHub Issues", True),
        ("docs/agents/loop-engineering.md", "GitHub Issue", True),
        ("WORKFLOW.md", "max_concurrent_agents: 2", True),
        ("WORKFLOW.md", "shell_environment_policy.inherit=core", True),
        (".codex/environments/environment.toml", 'script = "./scripts/agent_bootstrap.sh"', True),
        ("scripts/run_symphony.sh", "SYMPHONY_GITHUB_TOKEN", True),
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
    issue_parser.add_argument("--json", action="store_true")

    verify_parser = subparsers.add_parser("verify", help="Run the narrow deterministic gates for the current diff.")
    verify_parser.add_argument("--base", default="origin/main")
    verify_parser.add_argument("--mode", choices=("quick", "full"), default="full")
    verify_parser.add_argument("--issue")
    verify_parser.add_argument("--output-root", type=Path, default=None)
    verify_parser.add_argument("--dry-run", action="store_true")

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
            payload = issue_preflight(args.issue, resume=args.resume)
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
