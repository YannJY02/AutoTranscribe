#!/usr/bin/env python3
"""Finalize native macOS UI, log, metric, and trace evidence without copying log contents."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from datetime import datetime, timezone
from pathlib import Path


PASSED_TEST_RE = re.compile(r"Test Case '.+?' passed \((?P<seconds>[0-9.]+) seconds\)\.")
FAILED_TEST_RE = re.compile(r"Test Case '.+?' failed \((?P<seconds>[0-9.]+) seconds\)\.")


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _artifact(name: str, path: Path | None) -> dict[str, object] | None:
    if path is None or not path.exists():
        return None
    payload: dict[str, object] = {
        "name": name,
        "path": str(path.resolve()),
        "kind": "directory" if path.is_dir() else "file",
    }
    if path.is_file():
        payload.update({"bytes": path.stat().st_size, "sha256": _sha256(path)})
    return payload


def finalize_proof(
    *,
    output_root: Path,
    exit_code: int,
    duration_seconds: float,
    xcodebuild_log: Path,
    unified_log: Path | None,
    result_bundle: Path | None,
    attachments_dir: Path | None,
    video: Path | None,
    trace: Path | None,
    require_video: bool = False,
    require_trace: bool = False,
) -> dict[str, object]:
    output_root.mkdir(parents=True, exist_ok=True)
    log_text = xcodebuild_log.read_text(encoding="utf-8", errors="replace") if xcodebuild_log.exists() else ""
    passed = [float(match.group("seconds")) for match in PASSED_TEST_RE.finditer(log_text)]
    failed = [float(match.group("seconds")) for match in FAILED_TEST_RE.finditer(log_text)]
    screenshots = 0
    if attachments_dir and attachments_dir.exists():
        screenshots = sum(
            1 for path in attachments_dir.rglob("*") if path.is_file() and path.suffix.casefold() in {".png", ".jpg", ".jpeg"}
        )
    unified_lines = 0
    unified_json_lines = 0
    if unified_log and unified_log.exists():
        with unified_log.open(encoding="utf-8", errors="replace") as handle:
            for line in handle:
                unified_lines += 1
                try:
                    json.loads(line)
                except json.JSONDecodeError:
                    continue
                unified_json_lines += 1
    metrics = {
        "command_exit_code": exit_code,
        "journey_duration_seconds": round(duration_seconds, 3),
        "tests_passed": len(passed),
        "tests_failed": len(failed),
        "test_duration_seconds": round(sum(passed) + sum(failed), 3),
        "screenshots": screenshots,
        "unified_log_lines": unified_lines,
        "unified_log_json_lines": unified_json_lines,
    }
    missing_required_evidence = []
    if screenshots == 0:
        missing_required_evidence.append("screenshot")
    if not passed and not failed:
        missing_required_evidence.append("test-result")
    if result_bundle is None or not result_bundle.is_dir():
        missing_required_evidence.append("xcresult")
    if unified_json_lines == 0:
        missing_required_evidence.append("unified-log")
    if require_video and (video is None or not video.is_file()):
        missing_required_evidence.append("video")
    if require_trace and (trace is None or not trace.is_dir()):
        missing_required_evidence.append("trace")
    artifacts = [
        artifact
        for artifact in (
            _artifact("xcodebuild-log", xcodebuild_log),
            _artifact("unified-log", unified_log),
            _artifact("xcresult", result_bundle),
            _artifact("screenshots", attachments_dir),
            _artifact("screen-recording", video),
            _artifact("instruments-trace", trace),
        )
        if artifact is not None
    ]
    proof: dict[str, object] = {
        "schema_version": 1,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "status": "passed" if exit_code == 0 and not failed and not missing_required_evidence else "failed",
        "capabilities": {
            "ui": "xcuitest-screenshots-and-screen-recording",
            "logs": "macos-unified-logging",
            "metrics": "proof-json",
            "trace": "instruments-xctrace",
        },
        "metrics": metrics,
        "missing_required_evidence": missing_required_evidence,
        "artifacts": artifacts,
    }
    (output_root / "metrics.json").write_text(json.dumps(metrics, indent=2) + "\n", encoding="utf-8")
    (output_root / "proof.json").write_text(json.dumps(proof, indent=2) + "\n", encoding="utf-8")
    return proof


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--exit-code", type=int, required=True)
    parser.add_argument("--duration-seconds", type=float, required=True)
    parser.add_argument("--xcodebuild-log", type=Path, required=True)
    parser.add_argument("--unified-log", type=Path)
    parser.add_argument("--result-bundle", type=Path)
    parser.add_argument("--attachments-dir", type=Path)
    parser.add_argument("--video", type=Path)
    parser.add_argument("--trace", type=Path)
    parser.add_argument("--require-video", action="store_true")
    parser.add_argument("--require-trace", action="store_true")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    proof = finalize_proof(
        output_root=args.output_root,
        exit_code=args.exit_code,
        duration_seconds=args.duration_seconds,
        xcodebuild_log=args.xcodebuild_log,
        unified_log=args.unified_log,
        result_bundle=args.result_bundle,
        attachments_dir=args.attachments_dir,
        video=args.video,
        trace=args.trace,
        require_video=args.require_video,
        require_trace=args.require_trace,
    )
    print(args.output_root / "proof.json")
    return 0 if proof["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
