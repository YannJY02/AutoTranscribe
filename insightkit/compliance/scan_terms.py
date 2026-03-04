"""Brand/IP compliance scanner for banned terms."""

from __future__ import annotations

import argparse
import fnmatch
from pathlib import Path

BANNED_TERMS = [
    "妙记",
    "智能会议纪要",
    "会议金句",
    "关键决策",
    "平替",
    "复刻",
]


def scan_text(text: str) -> list[str]:
    hits: list[str] = []
    lower = text.lower()
    for term in BANNED_TERMS:
        if term.lower() in lower:
            hits.append(term)
    return hits


def scan_paths(paths: list[Path], exclude_patterns: list[str] | None = None) -> dict[str, list[str]]:
    exclude_patterns = exclude_patterns or []
    self_file = Path(__file__).resolve()
    result: dict[str, list[str]] = {}
    for path in paths:
        if not path.exists() or path.is_dir():
            continue
        resolved = path.resolve()
        if resolved == self_file:
            continue
        if any(fnmatch.fnmatch(str(path), p) or fnmatch.fnmatch(str(resolved), p) for p in exclude_patterns):
            continue
        content = path.read_text(encoding="utf-8", errors="ignore")
        hits = scan_text(content)
        if hits:
            result[str(path)] = hits
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="Scan files for banned UI/comms terms")
    parser.add_argument("paths", nargs="+", help="files to scan")
    parser.add_argument(
        "--exclude",
        action="append",
        default=[],
        help="glob pattern for excluded files, can be repeated",
    )
    args = parser.parse_args()

    findings = scan_paths([Path(p) for p in args.paths], exclude_patterns=args.exclude)
    if not findings:
        print("OK: no banned terms found")
        return 0

    for path, terms in findings.items():
        print(f"{path}: {', '.join(sorted(set(terms)))}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
