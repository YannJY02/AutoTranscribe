#!/usr/bin/env python3
"""Enqueue bounded recurring Codex maintenance through the existing GitHub/Symphony loop."""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import shlex
import shutil
import subprocess
import sys
from dataclasses import dataclass
from datetime import date
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
REPOSITORY = "YannJY02/AutoTranscribe"
LAUNCH_AGENT_LABEL = "com.insightkit.harness-maintenance"
SYMPHONY_LAUNCH_AGENT_LABEL = "com.insightkit.symphony"


@dataclass(frozen=True)
class MaintenanceTask:
    name: str
    title: str
    weekday: int
    goal: str
    boundary: str
    acceptance: str
    verification: str


TASKS = {
    "docs-gardening": MaintenanceTask(
        name="docs-gardening",
        title="Repair one repository-knowledge drift",
        weekday=0,
        goal="Find and repair at most one material contradiction between current code and agent-facing documentation.",
        boundary="Inspect at most five recent main commits and twelve current files. Do not scan .scratch/ or docs/Legacy/ and do not perform unrelated cleanup.",
        acceptance="The drift is fixed in the smallest authoritative document, or a no-change result records why no material drift was found.",
        verification="python3 scripts/verify_project_normalization.py",
    ),
    "feedback-promotion": MaintenanceTask(
        name="feedback-promotion",
        title="Promote one repeated feedback invariant",
        weekday=1,
        goal="Turn at most one repeated or high-impact review or bug lesson into a durable repository guardrail.",
        boundary="Inspect at most ten recent merged pull requests plus linked bugs. Promote the lesson into exactly one of Docs, Skill, Lint, or Structural Test; do not duplicate an existing rule.",
        acceptance="One evidenced invariant is promoted and verified, or a no-change result records that no repeated material lesson exists.",
        verification="python3.11 scripts/agent_harness.py verify --mode full",
    ),
    "quality-gardening": MaintenanceTask(
        name="quality-gardening",
        title="Repair one golden-principle deviation",
        weekday=4,
        goal="Find and repair at most one mechanical deviation from the repository's current architecture, validation, or error-handling rules.",
        boundary="Choose one domain and one invariant. Do not introduce a new abstraction, broad refactor, dependency, or product behavior.",
        acceptance="The smallest root-cause repair and regression check pass, or a no-change result records why no actionable deviation exists.",
        verification="python3.11 scripts/agent_harness.py verify --mode full",
    ),
}


def period_key(day: date) -> str:
    year, week, _ = day.isocalendar()
    return f"{year}-W{week:02d}"


def due_task_names(day: date) -> list[str]:
    return [task.name for task in TASKS.values() if task.weekday <= day.weekday()]


def marker_for(task: MaintenanceTask, period: str) -> str:
    return f"<!-- harness-maintenance:{task.name}:{period} -->"


def issue_body(task: MaintenanceTask, period: str) -> str:
    return f"""{marker_for(task, period)}

## Goal

{task.goal}

## Context

This is the {period} local maintenance pass. Read AGENTS.md, docs/agents/harness.md, docs/agents/tool-boundaries.md, current Context/ADRs, and the repository feedback-promotion skill before acting. Linear owns task state and priority; repository files, PRs, CI, and GitHub execution evidence own delivery proof.

## Boundary

{task.boundary}

## Acceptance

- [ ] {task.acceptance}
- [ ] The issue comment or PR names the evidence examined and the durable surface chosen.

## Verification

`{task.verification}`

## Resource class

isolated

## Blockers

None.

## Human gates

None.
"""


def _run(command: list[str], *, input_text: str | None = None) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(command, cwd=ROOT, input=input_text, text=True, capture_output=True, check=False)
    if completed.returncode != 0:
        raise RuntimeError((completed.stderr or completed.stdout).strip())
    return completed


def _bootstrap_launch_agent(domain: str, destination: Path) -> None:
    command = ["launchctl", "bootstrap", domain, str(destination)]
    try:
        _run(command)
    except RuntimeError as error:
        if str(error) != "Bootstrap failed: 5: Input/output error":
            raise
        _run(command)


def _macos_proxy_environment() -> dict[str, str]:
    if sys.platform != "darwin":
        return {}
    completed = subprocess.run(
        ["/usr/sbin/scutil", "--proxy"],
        text=True,
        capture_output=True,
        check=False,
    )
    if completed.returncode != 0:
        return {}
    settings: dict[str, str] = {}
    exceptions: list[str] = []
    reading_exceptions = False
    for line in completed.stdout.splitlines():
        if line == "  ExceptionsList : <array> {":
            reading_exceptions = True
            continue
        if reading_exceptions:
            if line == "  }":
                reading_exceptions = False
            elif line.startswith("    ") and " : " in line:
                exceptions.append(line.split(" : ", 1)[1])
            continue
        if line.startswith("  ") and not line.startswith("    ") and " : " in line:
            key, value = line[2:].split(" : ", 1)
            settings[key] = value
    environment = {
        f"{scheme}_PROXY": f"http://{settings[f'{scheme}Proxy']}:{settings[f'{scheme}Port']}"
        for scheme in ("HTTP", "HTTPS")
        if settings.get(f"{scheme}Enable") == "1"
        and settings.get(f"{scheme}Proxy")
        and settings.get(f"{scheme}Port", "").isdigit()
    }
    if environment:
        bypass = ["127.0.0.1", "localhost", *exceptions]
        # ponytail: NO_PROXY has no dotless-host wildcard; add per-client adapters if intranet hosts enter scope.
        environment["NO_PROXY"] = ",".join(dict.fromkeys(bypass))
    return environment


def _shell_proxy_exports(environment: dict[str, str]) -> str:
    return "\n".join(f"export {key}={shlex.quote(value)}" for key, value in environment.items())


def existing_issue_url(task: MaintenanceTask, period: str) -> str | None:
    marker = marker_for(task, period)
    completed = _run(
        [
            "gh",
            "issue",
            "list",
            "--repo",
            REPOSITORY,
            "--state",
            "all",
            "--search",
            f'"{marker}" in:body',
            "--limit",
            "10",
            "--json",
            "body,url",
        ]
    )
    for issue in json.loads(completed.stdout):
        if marker in str(issue.get("body", "")):
            return str(issue["url"])
    return None


def enqueue(task: MaintenanceTask, day: date, *, dry_run: bool) -> dict[str, str]:
    period = period_key(day)
    existing = None if dry_run else existing_issue_url(task, period)
    if existing:
        return {"task": task.name, "period": period, "status": "existing", "url": existing}
    if dry_run:
        return {"task": task.name, "period": period, "status": "planned", "marker": marker_for(task, period)}
    completed = _run(
        [
            "gh",
            "issue",
            "create",
            "--repo",
            REPOSITORY,
            "--title",
            f"[Harness maintenance] {task.title} ({period})",
            "--label",
            "harness:maintenance",
            "--label",
            "needs-triage",
            "--body-file",
            "-",
        ],
        input_text=issue_body(task, period),
    )
    return {"task": task.name, "period": period, "status": "created", "url": completed.stdout.strip()}


def install_launch_agent(repo_root: Path, *, load: bool, launch_agents_dir: Path | None = None) -> Path:
    repo_root = repo_root.expanduser().resolve()
    script = repo_root / "scripts" / "harness_maintenance.py"
    if not script.is_file():
        raise ValueError(f"maintenance script not found under repository: {script}")
    python = shutil.which("python3.11")
    if not python:
        raise RuntimeError("python3.11 is required")
    log_root = repo_root / "logs" / "harness"
    log_root.mkdir(parents=True, exist_ok=True)
    launch_agents = launch_agents_dir or Path.home() / "Library" / "LaunchAgents"
    launch_agents.mkdir(parents=True, exist_ok=True)
    destination = launch_agents / f"{LAUNCH_AGENT_LABEL}.plist"
    payload = {
        "Label": LAUNCH_AGENT_LABEL,
        "ProgramArguments": [python, str(script), "enqueue", "--task", "due"],
        "WorkingDirectory": str(repo_root),
        "EnvironmentVariables": {
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        },
        "StartCalendarInterval": {"Hour": 9, "Minute": 0},
        "StandardOutPath": str(log_root / "maintenance-launchd.stdout.log"),
        "StandardErrorPath": str(log_root / "maintenance-launchd.stderr.log"),
    }
    destination.write_bytes(plistlib.dumps(payload, sort_keys=True))
    if load:
        domain = f"gui/{os.getuid()}"
        subprocess.run(["launchctl", "bootout", f"{domain}/{LAUNCH_AGENT_LABEL}"], capture_output=True, check=False)
        _bootstrap_launch_agent(domain, destination)
    return destination


def install_symphony_launch_agent(
    repo_root: Path,
    *,
    load: bool,
    launch_agents_dir: Path | None = None,
) -> Path:
    repo_root = repo_root.expanduser().resolve()
    launcher = repo_root / "scripts" / "run_symphony.sh"
    workflow = repo_root / "WORKFLOW.md"
    if not launcher.is_file() or not workflow.is_file():
        raise ValueError(f"Symphony launcher or workflow not found under repository: {repo_root}")
    command_paths = {command: shutil.which(command) for command in ("symphony", "codex", "gh", "python3.11")}
    missing = [command for command, resolved in command_paths.items() if not resolved]
    if missing:
        raise RuntimeError(f"required Symphony commands not found: {', '.join(missing)}")
    command_dirs = [str(Path(resolved).parent) for resolved in command_paths.values() if resolved]
    resolved_dirs = set(command_dirs)
    original_dirs = [entry for entry in os.environ.get("PATH", "").split(os.pathsep) if entry]
    ordered_command_dirs = [entry for entry in original_dirs if entry in resolved_dirs]
    runtime_path = os.pathsep.join(
        dict.fromkeys(
            (
                *ordered_command_dirs,
                *command_dirs,
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
                "/bin",
                "/usr/sbin",
                "/sbin",
            )
        )
    )
    log_root = repo_root / "logs" / "symphony"
    log_root.mkdir(parents=True, exist_ok=True)
    launch_agents = launch_agents_dir or Path.home() / "Library" / "LaunchAgents"
    launch_agents.mkdir(parents=True, exist_ok=True)
    destination = launch_agents / f"{SYMPHONY_LAUNCH_AGENT_LABEL}.plist"
    payload = {
        "Label": SYMPHONY_LAUNCH_AGENT_LABEL,
        "ProgramArguments": ["/bin/sh", str(launcher)],
        "WorkingDirectory": str(repo_root),
        "EnvironmentVariables": {
            "PATH": runtime_path,
            "SYMPHONY_REPO_SOURCE": str(repo_root),
        },
        "KeepAlive": True,
        "RunAtLoad": True,
        "ProcessType": "Background",
        "StandardOutPath": str(log_root / "launchd.stdout.log"),
        "StandardErrorPath": str(log_root / "launchd.stderr.log"),
    }
    destination.write_bytes(plistlib.dumps(payload, sort_keys=True))
    if load:
        domain = f"gui/{os.getuid()}"
        subprocess.run(
            ["launchctl", "bootout", f"{domain}/{SYMPHONY_LAUNCH_AGENT_LABEL}"],
            capture_output=True,
            check=False,
        )
        _bootstrap_launch_agent(domain, destination)
    return destination


def _selected_tasks(selector: str, day: date) -> list[MaintenanceTask]:
    names = due_task_names(day) if selector == "due" else list(TASKS) if selector == "all" else [selector]
    return [TASKS[name] for name in names]


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for name in ("plan", "enqueue"):
        subparser = subparsers.add_parser(name)
        subparser.add_argument("--date", default=date.today().isoformat())
        subparser.add_argument("--task", choices=("due", "all", *TASKS), default="due")
    install = subparsers.add_parser("install-launch-agent")
    install.add_argument("--repo-root", type=Path, default=ROOT)
    install.add_argument("--no-load", action="store_true")
    install_symphony = subparsers.add_parser("install-symphony-launch-agent")
    install_symphony.add_argument("--repo-root", type=Path, default=ROOT)
    install_symphony.add_argument("--no-load", action="store_true")
    subparsers.add_parser("proxy-environment")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        if args.command == "proxy-environment":
            print(_shell_proxy_exports(_macos_proxy_environment()))
            return 0
        if args.command == "install-launch-agent":
            print(install_launch_agent(args.repo_root, load=not args.no_load))
            return 0
        if args.command == "install-symphony-launch-agent":
            print(install_symphony_launch_agent(args.repo_root, load=not args.no_load))
            return 0
        day = date.fromisoformat(args.date)
        tasks = _selected_tasks(args.task, day)
        results = [enqueue(task, day, dry_run=args.command == "plan") for task in tasks]
        print(json.dumps({"date": day.isoformat(), "results": results}, indent=2))
        return 0
    except (RuntimeError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
