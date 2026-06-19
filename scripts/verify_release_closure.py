#!/usr/bin/env python3
"""Run InsightKit's non-GUI release closure gates as one bounded command.

This script is intentionally a verifier, not a builder. It does not launch the
macOS app, notarize, delete artifacts, or re-run the expensive GUI/media smoke.
It refreshes the release gates that are safe to run repeatedly and links their
proof JSON into one closure ledger.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import time
from datetime import datetime
from pathlib import Path
from typing import Any

ROOT_DIR = Path(__file__).resolve().parent.parent
DEFAULT_DIAGNOSTICS_ROOT = ROOT_DIR / "logs" / "diagnostics"

PROOF_PATH_RE = re.compile(r"^wrote proof:\s*(?P<path>.+?proof\.json)\s*$", re.MULTILINE)
STATUS_RE = re.compile(r"^status:\s*(?P<status>\S+)\s*$", re.MULTILINE)

SECRET_OK = {"passed"}
UI_OK = {"passed"}
RELEASE_OK = {"passed_with_external_blockers", "passed_distribution_ready"}
GOAL_OK = {"local_personal_loop_verified_with_external_distribution_blockers", "release_ready"}


def iso_now() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def today_output_root() -> Path:
    day = datetime.now().strftime("%Y-%m-%d")
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    return DEFAULT_DIAGNOSTICS_ROOT / day / f"release-closure-{stamp}"


def command_text(command: list[str]) -> str:
    root = str(ROOT_DIR)
    cleaned: list[str] = []
    for part in command:
        if part.startswith(root + "/"):
            cleaned.append(part.replace(root + "/", "", 1))
        else:
            cleaned.append(part)
    return " ".join(cleaned)


def decode_timeout_output(value: str | bytes | None) -> str:
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return value


def parse_proof_path(output: str) -> Path | None:
    matches = list(PROOF_PATH_RE.finditer(output))
    if not matches:
        return None
    return Path(matches[-1].group("path").strip()).expanduser()


def parse_status_line(output: str) -> str:
    matches = list(STATUS_RE.finditer(output))
    return matches[-1].group("status").strip() if matches else ""


def load_json(path: Path | None) -> dict[str, Any]:
    if path is None or not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def summarize_proof(data: dict[str, Any]) -> dict[str, Any]:
    summary: dict[str, Any] = {}
    for key in ("status", "scanned_files", "findings", "status_counts", "external_blockers", "missing"):
        if key in data:
            value = data[key]
            if key in {"external_blockers", "missing", "findings"} and isinstance(value, list):
                summary[key] = len(value)
            else:
                summary[key] = value
    return summary


def run_command(name: str, command: list[str], timeout_sec: float) -> dict[str, Any]:
    start = time.monotonic()
    try:
        result = subprocess.run(
            command,
            cwd=str(ROOT_DIR),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout_sec,
            check=False,
        )
        output = result.stdout or ""
        proof_path = parse_proof_path(output)
        proof_data = load_json(proof_path)
        return {
            "name": name,
            "command": command_text(command),
            "exit_code": result.returncode,
            "timed_out": False,
            "duration_sec": round(time.monotonic() - start, 3),
            "output": output.strip(),
            "proof_path": str(proof_path) if proof_path else "",
            "proof_exists": bool(proof_path and proof_path.exists()),
            "proof_status": str(proof_data.get("status") or parse_status_line(output)),
            "proof_summary": summarize_proof(proof_data),
        }
    except subprocess.TimeoutExpired as exc:
        return {
            "name": name,
            "command": command_text(command),
            "exit_code": None,
            "timed_out": True,
            "duration_sec": round(time.monotonic() - start, 3),
            "output": decode_timeout_output(exc.stdout).strip(),
            "proof_path": "",
            "proof_exists": False,
            "proof_status": "",
            "proof_summary": {},
            "error": f"timed out after {timeout_sec}s",
        }


def child_ok(entry: dict[str, Any], allowed_statuses: set[str]) -> bool:
    return (
        entry.get("exit_code") == 0
        and not entry.get("timed_out")
        and entry.get("proof_exists") is True
        and str(entry.get("proof_status") or "") in allowed_statuses
    )


def section_lines(output: str, heading: str) -> list[str]:
    lines = output.splitlines()
    try:
        start = lines.index(heading) + 1
    except ValueError:
        return []
    end = len(lines)
    for index in range(start, len(lines)):
        if lines[index].startswith("==> "):
            end = index
            break
    return [line.strip() for line in lines[start:end] if line.strip()]


def process_check_clean(entry: dict[str, Any]) -> bool:
    output = str(entry.get("output") or "")
    app_lines = section_lines(output, "==> InsightKitApp processes")
    sidecar_lines = section_lines(output, "==> InsightKit sidecar processes")
    return (
        entry.get("exit_code") == 0
        and not entry.get("timed_out")
        and not app_lines
        and not sidecar_lines
        and "No socket:" in output
    )


def determine_closure_status(children: dict[str, dict[str, Any]]) -> str:
    required = {
        "secret_hygiene": child_ok(children.get("secret_hygiene", {}), SECRET_OK),
        "ui_hygiene": child_ok(children.get("ui_hygiene", {}), UI_OK),
        "release_readiness": child_ok(children.get("release_readiness", {}), RELEASE_OK),
        "goal_evidence": child_ok(children.get("goal_evidence", {}), GOAL_OK),
        "process_check": process_check_clean(children.get("process_check", {})),
    }
    if not all(required.values()):
        return "failed"
    if (
        children["release_readiness"].get("proof_status") == "passed_distribution_ready"
        and children["goal_evidence"].get("proof_status") == "release_ready"
    ):
        return "passed_distribution_ready"
    return "passed_local_with_external_blockers"


def build_commands(output_root: Path) -> list[tuple[str, list[str], float]]:
    secret_root = output_root / "secret-hygiene"
    ui_root = output_root / "ui-hygiene"
    release_root = output_root / "release-readiness"
    goal_root = output_root / "goal-evidence"
    return [
        ("secret_hygiene", ["python3", "scripts/verify_secret_hygiene.py", "--output-root", str(secret_root)], 45),
        ("ui_hygiene", ["python3", "scripts/verify_ui_hygiene.py", "--output-root", str(ui_root)], 45),
        (
            "release_readiness",
            ["python3", "scripts/verify_release_readiness.py", "--output-root", str(release_root)],
            420,
        ),
        (
            "goal_evidence",
            [
                "python3",
                "scripts/verify_goal_evidence.py",
                "--release-proof",
                str(release_root / "proof.json"),
                "--secret-proof",
                str(secret_root / "proof.json"),
                "--ui-proof",
                str(ui_root / "proof.json"),
                "--output-root",
                str(goal_root),
            ],
            90,
        ),
        ("process_check", ["scripts/dev_check_insightkit_processes.sh"], 15),
    ]


def build_failed_checks(children: dict[str, dict[str, Any]]) -> list[dict[str, Any]]:
    checks = [
        ("secret_hygiene", child_ok(children.get("secret_hygiene", {}), SECRET_OK)),
        ("ui_hygiene", child_ok(children.get("ui_hygiene", {}), UI_OK)),
        ("release_readiness", child_ok(children.get("release_readiness", {}), RELEASE_OK)),
        ("goal_evidence", child_ok(children.get("goal_evidence", {}), GOAL_OK)),
        ("process_check", process_check_clean(children.get("process_check", {}))),
    ]
    return [
        {
            "name": name,
            "exit_code": children.get(name, {}).get("exit_code"),
            "timed_out": children.get(name, {}).get("timed_out"),
            "proof_status": children.get(name, {}).get("proof_status"),
            "proof_path": children.get(name, {}).get("proof_path"),
        }
        for name, ok in checks
        if not ok
    ]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-root", type=Path, default=today_output_root(), help="Directory for closure proof.json.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    output_root = args.output_root.expanduser().resolve()
    output_root.mkdir(parents=True, exist_ok=True)

    children: dict[str, dict[str, Any]] = {}
    for name, command, timeout_sec in build_commands(output_root):
        children[name] = run_command(name, command, timeout_sec=timeout_sec)

    status = determine_closure_status(children)
    failed_checks = build_failed_checks(children)
    proof = {
        "generated_at": iso_now(),
        "status": status,
        "workspace": str(ROOT_DIR),
        "output_root": str(output_root),
        "children": children,
        "failed_checks": failed_checks,
        "conclusion": (
            "The local InsightKit personal-app release loop is verified by fresh non-GUI gates; public distribution "
            "still depends on the explicitly tracked Apple account, certificate, notarization, sandbox, and privacy inputs."
            if status == "passed_local_with_external_blockers"
            else "InsightKit is distribution-ready according to the local closure gates."
            if status == "passed_distribution_ready"
            else "Release closure failed; inspect failed_checks and child command output."
        ),
    }
    proof_path = output_root / "proof.json"
    proof_path.write_text(json.dumps(proof, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print(f"wrote proof: {proof_path}")
    print(f"status: {status}")
    for name in ("secret_hygiene", "ui_hygiene", "release_readiness", "goal_evidence", "process_check"):
        child = children.get(name, {})
        detail = child.get("proof_status") or ("clean" if name == "process_check" and process_check_clean(child) else "no-proof")
        print(f"{name}: exit={child.get('exit_code')} timed_out={child.get('timed_out')} status={detail}")
    if failed_checks:
        print(f"failed_checks: {len(failed_checks)}")
    return 0 if status in {"passed_local_with_external_blockers", "passed_distribution_ready"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
