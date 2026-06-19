#!/usr/bin/env python3
"""Scan InsightKit app UI source for release-blocking placeholder controls."""

from __future__ import annotations

import argparse
import json
import re
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Iterable

ROOT_DIR = Path(__file__).resolve().parent.parent
DEFAULT_DIAGNOSTICS_ROOT = ROOT_DIR / "logs" / "diagnostics"
DEFAULT_SCAN_TARGETS = ["macos/InsightKitApp/Sources/InsightKitApp"]
EXCLUDED_DIR_NAMES = {
    ".build",
    ".swiftpm",
    "DerivedData",
    "Tests",
    "UITests",
    "xcuserdata",
}
MAX_FILE_BYTES = 700_000


@dataclass(frozen=True)
class UIHygieneRule:
    name: str
    pattern: re.Pattern[str]
    severity: str = "high"


UI_RULES = [
    UIHygieneRule("todo_comment", re.compile(r"\b(?:TODO|FIXME|TBD)\b")),
    UIHygieneRule("unimplemented_text", re.compile(r"(?i)\b(?:coming soon|not implemented)\b|敬请期待|未实现|开发中")),
    UIHygieneRule("placeholder_copy", re.compile(r"占位(?!符|字符串)")),
    UIHygieneRule("empty_button_action", re.compile(r"Button\s*\([^)]*\)\s*\{\s*\}", re.DOTALL)),
    UIHygieneRule("empty_button_action_label", re.compile(r"Button\s*\{\s*\}\s*label\s*:", re.DOTALL)),
    UIHygieneRule("permanently_disabled_control", re.compile(r"\.disabled\(\s*true\s*\)")),
]


def iso_now() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def today_output_root() -> Path:
    day = datetime.now().strftime("%Y-%m-%d")
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    return DEFAULT_DIAGNOSTICS_ROOT / day / f"ui-hygiene-{stamp}"


def should_scan_file(path: Path) -> bool:
    if any(part in EXCLUDED_DIR_NAMES for part in path.parts):
        return False
    if path.suffix != ".swift":
        return False
    try:
        return path.is_file() and path.stat().st_size <= MAX_FILE_BYTES
    except OSError:
        return False


def iter_scan_files(root: Path, targets: Iterable[str]) -> list[Path]:
    files: list[Path] = []
    for target in targets:
        path = (root / target).resolve()
        if not path.exists():
            continue
        if path.is_file():
            if should_scan_file(path):
                files.append(path)
            continue
        for child in path.rglob("*.swift"):
            if should_scan_file(child):
                files.append(child)
    return sorted(set(files))


def line_number_for_offset(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def snippet_for_match(text: str, start: int, end: int) -> str:
    raw = text[start:end].strip().replace("\n", "\\n")
    return raw[:160]


def scan_text(text: str, relpath: str = "<memory>") -> list[dict[str, Any]]:
    findings: list[dict[str, Any]] = []
    for rule in UI_RULES:
        for match in rule.pattern.finditer(text):
            findings.append(
                {
                    "path": relpath,
                    "line": line_number_for_offset(text, match.start()),
                    "rule": rule.name,
                    "severity": rule.severity,
                    "snippet": snippet_for_match(text, match.start(), match.end()),
                }
            )
    return findings


def scan_file(path: Path, root: Path) -> tuple[list[dict[str, Any]], str]:
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return [], "skipped_non_utf8"
    except OSError as exc:
        return [
            {
                "path": str(path.relative_to(root)),
                "line": 0,
                "rule": "read_error",
                "severity": "medium",
                "snippet": str(exc),
            }
        ], "read_error"
    return scan_text(text, str(path.relative_to(root))), "scanned"


def scan_paths(root: Path, targets: Iterable[str]) -> dict[str, Any]:
    root = root.resolve()
    files = iter_scan_files(root, targets)
    findings: list[dict[str, Any]] = []
    skipped_non_utf8 = 0
    for path in files:
        file_findings, status = scan_file(path, root)
        if status == "skipped_non_utf8":
            skipped_non_utf8 += 1
        findings.extend(file_findings)
    return {
        "status": "passed" if not findings else "failed",
        "scanned_files": len(files),
        "skipped_non_utf8": skipped_non_utf8,
        "targets": list(targets),
        "rules": [rule.name for rule in UI_RULES],
        "findings": findings,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT_DIR, help=f"Repository root. Default: {ROOT_DIR}")
    parser.add_argument(
        "--target",
        action="append",
        dest="targets",
        help="Swift UI source path to scan. May be passed multiple times. Defaults to app Sources.",
    )
    parser.add_argument("--output-root", type=Path, default=today_output_root(), help="Directory for proof.json.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = args.root.expanduser().resolve()
    targets = args.targets or DEFAULT_SCAN_TARGETS
    output_root = args.output_root.expanduser().resolve()
    output_root.mkdir(parents=True, exist_ok=True)
    proof_path = output_root / "proof.json"
    proof = {
        "generated_at": iso_now(),
        "workspace": str(root),
        **scan_paths(root, targets),
    }
    proof_path.write_text(json.dumps(proof, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"wrote proof: {proof_path}")
    print(f"status: {proof['status']}")
    print(f"scanned_files: {proof['scanned_files']}")
    print(f"findings: {len(proof['findings'])}")
    return 0 if proof["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
