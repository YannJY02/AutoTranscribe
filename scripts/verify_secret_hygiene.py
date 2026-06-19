#!/usr/bin/env python3
"""Scan release-relevant source files for high-confidence hardcoded secrets."""

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
DEFAULT_SCAN_TARGETS = [
    "README.md",
    ".gitignore",
    "docs",
    "insightkit",
    "macos/InsightKitApp",
    "scripts",
    "tests",
]
EXCLUDED_DIR_NAMES = {
    ".build",
    ".eggs",
    ".git",
    ".idea",
    ".pytest_cache",
    ".swiftpm",
    ".venv",
    ".vscode",
    "__pycache__",
    "build",
    "DerivedData",
    "dist",
    "logs",
    "node_modules",
    "txt",
    "venv",
    "video",
    "xcuserdata",
}
EXCLUDED_FILE_SUFFIXES = {
    ".aiff",
    ".aif",
    ".app",
    ".bin",
    ".caf",
    ".dmg",
    ".heic",
    ".icns",
    ".ico",
    ".jpeg",
    ".jpg",
    ".m4a",
    ".mov",
    ".mp3",
    ".mp4",
    ".pdf",
    ".png",
    ".pt",
    ".pyc",
    ".safetensors",
    ".wav",
    ".xcresult",
    ".zip",
}
MAX_FILE_BYTES = 1_000_000


@dataclass(frozen=True)
class SecretRule:
    name: str
    pattern: re.Pattern[str]
    severity: str = "high"


SECRET_RULES = [
    SecretRule("private_key_block", re.compile(r"-----BEGIN (?:RSA |DSA |EC |OPENSSH )?PRIVATE KEY-----")),
    SecretRule("openai_api_key", re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_-]{32,}\b")),
    SecretRule("anthropic_api_key", re.compile(r"\bsk-ant-[A-Za-z0-9_-]{32,}\b")),
    SecretRule("google_api_key", re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b")),
    SecretRule("github_token", re.compile(r"\bgh[pousr]_[A-Za-z0-9_]{36,}\b")),
    SecretRule("huggingface_token", re.compile(r"\bhf_[A-Za-z0-9]{30,}\b")),
    SecretRule("stripe_live_secret", re.compile(r"\b(?:sk|rk)_live_[A-Za-z0-9]{24,}\b")),
    SecretRule("aws_access_key", re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b")),
]


def iso_now() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def today_output_root() -> Path:
    day = datetime.now().strftime("%Y-%m-%d")
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    return DEFAULT_DIAGNOSTICS_ROOT / day / f"secret-hygiene-{stamp}"


def should_scan_file(path: Path) -> bool:
    if any(part in EXCLUDED_DIR_NAMES for part in path.parts):
        return False
    if path.suffix.lower() in EXCLUDED_FILE_SUFFIXES:
        return False
    try:
        if path.stat().st_size > MAX_FILE_BYTES:
            return False
    except OSError:
        return False
    return path.is_file()


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
        for child in path.rglob("*"):
            if should_scan_file(child):
                files.append(child)
    return sorted(set(files))


def mask_secret(value: str) -> str:
    if len(value) <= 12:
        return "***"
    return f"{value[:4]}...{value[-4:]}"


def line_number_for_offset(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def scan_text(text: str, relpath: str = "<memory>") -> list[dict[str, Any]]:
    findings: list[dict[str, Any]] = []
    for rule in SECRET_RULES:
        for match in rule.pattern.finditer(text):
            findings.append(
                {
                    "path": relpath,
                    "line": line_number_for_offset(text, match.start()),
                    "rule": rule.name,
                    "severity": rule.severity,
                    "match": mask_secret(match.group(0)),
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
                "match": str(exc),
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
        "excluded_dir_names": sorted(EXCLUDED_DIR_NAMES),
        "excluded_file_suffixes": sorted(EXCLUDED_FILE_SUFFIXES),
        "findings": findings,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT_DIR, help=f"Repository root. Default: {ROOT_DIR}")
    parser.add_argument(
        "--target",
        action="append",
        dest="targets",
        help="Release-relevant path to scan. May be passed multiple times. Defaults to source/docs/scripts/tests.",
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
