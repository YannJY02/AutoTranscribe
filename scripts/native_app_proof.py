#!/usr/bin/env python3
"""Finalize privacy-safe native macOS UI, log, metric, and trace evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
from datetime import datetime, timezone
from pathlib import Path


PASSED_TEST_RE = re.compile(r"Test Case '.+?' passed \((?P<seconds>[0-9.]+) seconds\)\.")
FAILED_TEST_RE = re.compile(r"Test Case '.+?' failed \((?P<seconds>[0-9.]+) seconds\)\.")
TEST_RESULT_RE = re.compile(
    r"Test Case '-\[[^ ]+\.(?P<suite>[^ ]+) (?P<test>[^]]+)\]' (?P<status>passed|failed)"
)
REQUIRED_SURFACES = {
    "home", "live", "import", "records", "settings", "restart-persistence", "failure-recovery"
}
VALID_RUNGS = {"deterministic", "runtime-integration", "packaged-app", "xcuitest", "manual-only"}
EXCLUSIVE_RUNGS = {"packaged-app", "xcuitest"}
LOCK_PREFIX = [
    "python3.11", "scripts/agent_harness.py", "lock", "--resource", "installed-app", "--timeout", "1800", "--"
]
REPOSITORY_ROOT = Path(__file__).resolve().parent.parent


def _display_path(path: Path) -> str:
    try:
        relative = path.resolve().relative_to(Path.home().resolve()).as_posix()
        return "$HOME" if relative == "." else f"$HOME/{relative}"
    except ValueError:
        return str(path)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _artifact(name: str, path: Path | None, output_root: Path) -> dict[str, object] | None:
    if path is None or not path.exists():
        return None
    try:
        artifact_path = path.resolve().relative_to(output_root.resolve()).as_posix()
    except ValueError:
        artifact_path = path.name
    payload: dict[str, object] = {
        "name": name,
        "path": artifact_path,
        "kind": "directory" if path.is_dir() else "file",
    }
    if path.is_file():
        payload.update({"bytes": path.stat().st_size, "sha256": _sha256(path)})
    return payload


def _copy_evidence(source: Path | None, destination: Path) -> Path | None:
    if source is None or not source.exists():
        return None
    try:
        source.resolve().relative_to(destination.parent.resolve())
        _redact_text_file(source)
        return source
    except ValueError:
        pass
    if source.is_dir():
        shutil.copytree(source, destination)
    else:
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        _redact_text_file(destination)
    return destination


def _redact_text_file(path: Path) -> None:
    if not path.is_file() or path.suffix.casefold() not in {".json", ".log", ".ndjson", ".txt"}:
        return
    text = path.read_text(encoding="utf-8", errors="replace")
    text = re.sub(r"/Users/[^/\s\"']+", "$HOME", text)
    text = re.sub(r"(?i)(authorization:\s*bearer\s+)[^\s\"']+", r"\1<redacted>", text)
    text = re.sub(r"\bsk-[A-Za-z0-9_-]{12,}\b", "<redacted-api-key>", text)
    path.write_text(text, encoding="utf-8")


def _sanitize_text_artifacts(output_root: Path) -> None:
    for path in output_root.rglob("*"):
        _redact_text_file(path)


def _manifest_files(output_root: Path) -> list[dict[str, object]]:
    files = []
    for path in sorted(output_root.rglob("*")):
        if not path.is_file() or path.name == "manifest.json":
            continue
        files.append({
            "name": path.relative_to(output_root).as_posix(),
            "bytes": path.stat().st_size,
            "sha256": _sha256(path),
        })
    return files


def _classify_failure(
    exit_code: int,
    log_text: str,
    missing: list[str],
    explicit_classification: str | None = None,
) -> str:
    if explicit_classification:
        return explicit_classification
    lowered = log_text.casefold()
    if "swift-plugin-server' produced malformed response" in lowered:
        return "test-defect"
    if any(token in lowered for token in (
        "not authorized", "operation not permitted", "you don’t have permission",
        "timed out while enabling automation mode", "screen recording permission",
    )):
        return "macos-permission-or-capture"
    if exit_code == 0 and missing:
        return "test-defect"
    return "test-defect"


def validate_claim_matrix(matrix: dict[str, object]) -> dict[str, object]:
    errors: list[str] = []
    claims = matrix.get("claims")
    if not isinstance(claims, list):
        claims = []
        errors.append("claims must be a list")
    surfaces: set[str] = set()
    manual_only_count = 0
    for index, claim in enumerate(claims):
        if not isinstance(claim, dict):
            errors.append(f"claim[{index}] must be an object")
            continue
        surface = claim.get("surface")
        rung = claim.get("rung")
        command = claim.get("command")
        if isinstance(surface, str):
            surfaces.add(surface)
        if rung not in VALID_RUNGS:
            errors.append(f"claim[{index}] has invalid rung")
        if rung == "manual-only":
            manual_only_count += 1
            for field in ("build", "scenario", "expected_observation", "remaining_uncertainty"):
                if not claim.get(field):
                    errors.append(f"claim[{index}] manual-only claim missing {field}")
            if claim.get("result") == "passed":
                errors.append(f"claim[{index}] unobserved manual-only claim cannot pass")
        elif not isinstance(command, list) or not command:
            errors.append(f"claim[{index}] runnable claim missing command")
        elif rung in EXCLUSIVE_RUNGS and command[: len(LOCK_PREFIX)] != LOCK_PREFIX:
            errors.append(f"claim[{index}] exclusive command is not installed-app locked")
        elif rung not in EXCLUSIVE_RUNGS and command[: len(LOCK_PREFIX)] == LOCK_PREFIX:
            errors.append(f"claim[{index}] deterministic command must remain non-interfering")
        if isinstance(command, list):
            command_strings = [str(item) for item in command]
            for item in command_strings:
                if item.startswith(("tests/", "scripts/")) and not (REPOSITORY_ROOT / item).exists():
                    errors.append(f"claim[{index}] command target does not exist: {item}")
            if "--filter" in command_strings:
                filter_index = command_strings.index("--filter") + 1
                if filter_index >= len(command_strings):
                    errors.append(f"claim[{index}] swift filter is missing")
                else:
                    swift_tests = "\n".join(
                        path.read_text(encoding="utf-8", errors="replace")
                        for path in (REPOSITORY_ROOT / "macos/InsightKitApp/Tests").rglob("*.swift")
                    )
                    if command_strings[filter_index] not in swift_tests:
                        errors.append(f"claim[{index}] swift filter selects no declared test")
            for item in command_strings:
                if item.startswith("INSIGHTKIT_UITEST_SELECTED_TESTS="):
                    selected = item.partition("=")[2].split(",")
                    for test_name in selected:
                        suite, separator, method = test_name.partition("/")
                        matching_files = list(
                            (REPOSITORY_ROOT / "macos/InsightKitApp/UITests").rglob(f"{suite}.swift")
                        )
                        declared = any(
                            method in path.read_text(encoding="utf-8", errors="replace")
                            for path in matching_files
                        )
                        if not separator or not declared:
                            errors.append(f"claim[{index}] UI selection is not declared: {test_name}")
    missing_surfaces = sorted(REQUIRED_SURFACES - surfaces)
    if missing_surfaces:
        errors.append(f"missing surfaces: {', '.join(missing_surfaces)}")
    return {
        "status": "passed" if not errors else "failed",
        "surfaces": sorted(surfaces),
        "manual_only_count": manual_only_count,
        "errors": errors,
    }


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
    result_summary: Path | None = None,
    require_video: bool = False,
    require_trace: bool = False,
    source_revision: str = "unknown",
    build: str = "unknown",
    scenario: str = "unspecified",
    selected_tests: list[str] | None = None,
    expected_screenshots: list[str] | None = None,
    failure_classification: str | None = None,
) -> dict[str, object]:
    if (output_root / "proof.json").exists() or (output_root / "manifest.json").exists():
        raise FileExistsError(f"proof output already finalized: {output_root}")
    if result_bundle is not None and result_bundle.resolve().is_relative_to(output_root.resolve()):
        raise ValueError("raw xcresult must stay outside the privacy-safe proof root")
    output_root.mkdir(parents=True, exist_ok=True)
    log_text = xcodebuild_log.read_text(encoding="utf-8", errors="replace") if xcodebuild_log.exists() else ""
    passed = [float(match.group("seconds")) for match in PASSED_TEST_RE.finditer(log_text)]
    failed = [float(match.group("seconds")) for match in FAILED_TEST_RE.finditer(log_text)]
    selected_tests = selected_tests or []
    expected_screenshots = expected_screenshots or []
    copied_log = _copy_evidence(xcodebuild_log, output_root / "xcodebuild.log")
    copied_unified = _copy_evidence(unified_log, output_root / "unified.ndjson")
    copied_result_summary = _copy_evidence(result_summary, output_root / "xcresult-summary.json")
    copied_attachments = _copy_evidence(attachments_dir, output_root / "screenshots")
    copied_video = _copy_evidence(video, output_root / "journey.mov")
    copied_trace = _copy_evidence(trace, output_root / "journey.trace")
    screenshots = 0
    screenshot_names: list[str] = []
    if copied_attachments and copied_attachments.exists():
        screenshot_paths = [
            path for path in copied_attachments.rglob("*")
            if path.is_file() and path.suffix.casefold() in {".png", ".jpg", ".jpeg"}
        ]
        screenshots = len(screenshot_paths)
        screenshot_names = [path.stem for path in screenshot_paths]
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
    test_results = {
        f"{match.group('suite')}/{match.group('test')}": match.group("status")
        for match in TEST_RESULT_RE.finditer(log_text)
    }
    for test in selected_tests:
        if test_results.get(test) != "passed":
            missing_required_evidence.append(f"selected-test:{test}")
    for expected in expected_screenshots:
        if not any(expected in name for name in screenshot_names):
            missing_required_evidence.append(f"expected-screenshot:{expected}")
    artifacts = [
        artifact
        for artifact in (
            _artifact("xcodebuild-log", copied_log, output_root),
            _artifact("unified-log", copied_unified, output_root),
            _artifact("xcresult-summary", copied_result_summary, output_root),
            _artifact("screenshots", copied_attachments, output_root),
            _artifact("screen-recording", copied_video, output_root),
            _artifact("instruments-trace", copied_trace, output_root),
        )
        if artifact is not None
    ]
    proof: dict[str, object] = {
        "schema_version": 1,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "status": "passed" if exit_code == 0 and not failed and not missing_required_evidence else "failed",
        "privacy_safe": copied_video is None and copied_trace is None,
        "source": {"revision": source_revision, "build": build},
        "scenario": scenario,
        "selected_tests": [{"name": name, "status": test_results.get(name, "missing")} for name in selected_tests],
        "capture": {
            "screenshots": {
                "scope": "target-window", "pixels": "original", "cursor": "excluded", "other_apps": "excluded"
            },
            "video": {
                "scope": "main-display", "present": copied_video is not None,
                "privacy_safe": False,
            },
        },
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
    if proof["status"] == "failed":
        proof["failure"] = {
            "classification": _classify_failure(
                exit_code, log_text, missing_required_evidence, failure_classification
            ),
            "first_failure_retained": True,
        }
    (output_root / "metrics.json").write_text(json.dumps(metrics, indent=2) + "\n", encoding="utf-8")
    (output_root / "proof.json").write_text(json.dumps(proof, indent=2) + "\n", encoding="utf-8")
    _sanitize_text_artifacts(output_root)
    manifest = {
        "schema_version": 1,
        "source": proof["source"],
        "scenario": scenario,
        "result": proof["status"],
        "files": _manifest_files(output_root),
    }
    (output_root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return proof


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--exit-code", type=int, required=True)
    parser.add_argument("--duration-seconds", type=float, required=True)
    parser.add_argument("--xcodebuild-log", type=Path, required=True)
    parser.add_argument("--unified-log", type=Path)
    parser.add_argument("--result-bundle", type=Path)
    parser.add_argument("--result-summary", type=Path)
    parser.add_argument("--attachments-dir", type=Path)
    parser.add_argument("--video", type=Path)
    parser.add_argument("--trace", type=Path)
    parser.add_argument("--require-video", action="store_true")
    parser.add_argument("--require-trace", action="store_true")
    parser.add_argument("--source-revision", default="unknown")
    parser.add_argument("--build", default="unknown")
    parser.add_argument("--scenario", default="unspecified")
    parser.add_argument("--selected-test", action="append", default=[])
    parser.add_argument("--expected-screenshot", action="append", default=[])
    parser.add_argument("--failure-classification", choices=(
        "app-defect", "test-defect", "macos-permission-or-capture"
    ))
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
        result_summary=args.result_summary,
        attachments_dir=args.attachments_dir,
        video=args.video,
        trace=args.trace,
        require_video=args.require_video,
        require_trace=args.require_trace,
        source_revision=args.source_revision,
        build=args.build,
        scenario=args.scenario,
        selected_tests=args.selected_test,
        expected_screenshots=args.expected_screenshot,
        failure_classification=args.failure_classification,
    )
    print(_display_path(args.output_root / "proof.json"))
    return 0 if proof["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
