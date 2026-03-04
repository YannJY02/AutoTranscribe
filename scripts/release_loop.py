#!/usr/bin/env python3
"""Wrapper entry for workflow/release_loop.py with explicit sync/package controls."""

from __future__ import annotations

import argparse
import runpy
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description="Run InsightKit release loop wrapper")
    parser.add_argument("--max-rounds", type=int, default=200)
    parser.add_argument("--max-wall-time-sec", type=int, default=28800)
    parser.add_argument("--max-fail-streak", type=int, default=3)
    parser.add_argument(
        "--auto-commit",
        action=argparse.BooleanOptionalAction,
        default=False,
        help="Enable grouped local commits (no push).",
    )
    parser.add_argument(
        "--auto-package",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Auto package + install when round succeeds and P0/P1 are cleared (default: enabled).",
    )
    parser.add_argument(
        "--install-dir",
        type=str,
        default=str(Path.home() / "Applications"),
        help="Install directory for auto sync package.",
    )
    parser.add_argument(
        "--package-debug",
        action="store_true",
        help="Use debug package mode during auto sync.",
    )
    parser.add_argument(
        "--skip-sync-verify",
        action="store_true",
        help="Skip post-install verification in sync step.",
    )
    args, passthrough = parser.parse_known_args()

    target = Path(__file__).resolve().parent / "workflow" / "release_loop.py"
    forwarded = [
        str(target),
        "--max-rounds",
        str(max(1, int(args.max_rounds))),
        "--max-wall-time-sec",
        str(max(60, int(args.max_wall_time_sec))),
        "--max-fail-streak",
        str(max(1, int(args.max_fail_streak))),
        "--auto-commit" if bool(args.auto_commit) else "--no-auto-commit",
        "--auto-package" if bool(args.auto_package) else "--no-auto-package",
        "--install-dir",
        str(args.install_dir),
    ]
    if bool(args.package_debug):
        forwarded.append("--package-debug")
    if bool(args.skip_sync_verify):
        forwarded.append("--skip-sync-verify")
    if passthrough:
        forwarded.extend(passthrough)

    old_argv = sys.argv[:]
    try:
        sys.argv = forwarded
        runpy.run_path(str(target), run_name="__main__")
    finally:
        sys.argv = old_argv
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
