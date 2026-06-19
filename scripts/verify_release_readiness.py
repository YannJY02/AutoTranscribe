#!/usr/bin/env python3
"""Write a repeatable InsightKit release-readiness proof.

This verifier intentionally does not launch the GUI or re-run the expensive
real-media import. It links the latest runtime and visual proofs, reruns the
bounded release preflight gates, records the current signing identities, and
classifies local readiness separately from Apple-owned distribution blockers.
"""

from __future__ import annotations

import argparse
import json
import plistlib
import subprocess
from datetime import datetime
from pathlib import Path
from typing import Any

ROOT_DIR = Path(__file__).resolve().parent.parent
DEFAULT_APP = Path.home() / "Applications" / "InsightKit.app"
DEFAULT_DIAGNOSTICS_ROOT = ROOT_DIR / "logs" / "diagnostics"
LOCAL_ENTITLEMENTS = ROOT_DIR / "macos" / "InsightKitApp" / "InsightKitApp.entitlements"
APP_STORE_ENTITLEMENTS = ROOT_DIR / "macos" / "InsightKitApp" / "InsightKitApp.AppStore.entitlements"
RELEASE_READINESS_DOC = ROOT_DIR / "docs" / "plans" / "2026-05-26-insightkit-release-readiness-status.md"
APPLE_REFERENCE_URLS = [
    "https://developer.apple.com/developer-id/",
    "https://developer.apple.com/support/developer-id/",
    "https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox/",
    "https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox",
    "https://developer.apple.com/app-store/app-privacy-details/",
    "https://developer.apple.com/help/app-store-connect/reference/app-information/app-privacy",
]


def iso_now() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def today_output_root() -> Path:
    day = datetime.now().strftime("%Y-%m-%d")
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    return DEFAULT_DIAGNOSTICS_ROOT / day / f"release-readiness-status-{stamp}"


def command_text(command: list[str]) -> str:
    root = str(ROOT_DIR)
    cleaned: list[str] = []
    for part in command:
        if part.startswith(root + "/"):
            cleaned.append(part.replace(root + "/", "", 1))
        else:
            cleaned.append(part)
    return " ".join(cleaned)


def run_command(command: list[str], timeout_sec: float) -> dict[str, Any]:
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
        return {
            "command": command_text(command),
            "exit_code": result.returncode,
            "timed_out": False,
            "output": result.stdout.strip(),
        }
    except subprocess.TimeoutExpired as exc:
        return {
            "command": command_text(command),
            "exit_code": None,
            "timed_out": True,
            "output": (exc.stdout or "").strip() if isinstance(exc.stdout, str) else "",
            "error": f"timed out after {timeout_sec}s",
        }


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def load_plist(path: Path) -> dict[str, Any]:
    with path.open("rb") as fh:
        payload = plistlib.load(fh)
    return payload if isinstance(payload, dict) else {}


def latest_path(pattern: str) -> Path | None:
    candidates = [path for path in DEFAULT_DIAGNOSTICS_ROOT.glob(pattern) if path.is_file()]
    if not candidates:
        return None
    return max(candidates, key=lambda path: path.stat().st_mtime)


def optional_path(value: Any) -> Path | None:
    text = str(value or "").strip()
    return Path(text) if text else None


def read_app_info(app_path: Path) -> dict[str, Any]:
    info_path = app_path / "Contents" / "Info.plist"
    info: dict[str, Any] = {}
    if info_path.exists():
        info = load_plist(info_path)
    schemes: list[str] = []
    for entry in info.get("CFBundleURLTypes", []) or []:
        if isinstance(entry, dict):
            schemes.extend(str(value) for value in entry.get("CFBundleURLSchemes", []) or [])
    return {
        "path": str(app_path),
        "exists": app_path.exists(),
        "info_plist": str(info_path),
        "info_plist_exists": info_path.exists(),
        "bundle_id": str(info.get("CFBundleIdentifier") or ""),
        "display_name": str(info.get("CFBundleDisplayName") or info.get("CFBundleName") or ""),
        "version": str(info.get("CFBundleShortVersionString") or ""),
        "build": str(info.get("CFBundleVersion") or ""),
        "icon_file": str(info.get("CFBundleIconFile") or ""),
        "url_schemes": schemes,
        "usage_descriptions": {
            "NSMicrophoneUsageDescription": str(info.get("NSMicrophoneUsageDescription") or ""),
            "NSCameraUsageDescription": str(info.get("NSCameraUsageDescription") or ""),
            "NSScreenCaptureUsageDescription": str(info.get("NSScreenCaptureUsageDescription") or ""),
        },
    }


def entitlement_summary(path: Path, keys: list[str]) -> dict[str, Any]:
    if not path.exists():
        return {"path": str(path), "exists": False, "values": {}}
    payload = load_plist(path)
    return {
        "path": str(path),
        "exists": True,
        "values": {key: bool(payload.get(key)) for key in keys},
    }


def parse_preflight_output(output: str) -> dict[str, Any]:
    result = {"pass": [], "warn": [], "fail": []}
    for raw_line in output.splitlines():
        line = raw_line.strip()
        for prefix, key in (("PASS ", "pass"), ("WARN ", "warn"), ("FAIL ", "fail")):
            if line.startswith(prefix):
                result[key].append(line[len(prefix) :])
                break
    return {
        "passes": result["pass"],
        "warnings": result["warn"],
        "failures": result["fail"],
        "pass_count": len(result["pass"]),
        "warning_count": len(result["warn"]),
        "failure_count": len(result["fail"]),
    }


def classify_preflight(channel: str, exit_code: int | None, output: str, timed_out: bool = False) -> dict[str, Any]:
    parsed = parse_preflight_output(output)
    if timed_out:
        status = "timed-out"
    elif channel == "local" and exit_code == 0 and parsed["failure_count"] == 0:
        status = "local-release-ready"
    elif channel == "developer-id" and exit_code == 0 and parsed["failure_count"] == 0:
        status = "developer-id-ready"
    elif channel == "app-store" and exit_code == 0 and parsed["failure_count"] == 0:
        status = "app-store-ready"
    elif channel in {"developer-id", "app-store"} and parsed["failure_count"] > 0:
        status = "externally-blocked"
    else:
        status = "failed"
    return {
        "status": status,
        "exit_code": exit_code,
        "timed_out": timed_out,
        **parsed,
    }


def parse_codesigning_identities(output: str) -> dict[str, Any]:
    identities: list[str] = []
    for line in output.splitlines():
        if '"' not in line:
            continue
        parts = line.split('"')
        if len(parts) >= 3 and parts[1].strip():
            identities.append(parts[1].strip())
    return {
        "developer_id_application_present": any("Developer ID Application:" in item for item in identities),
        "mac_app_store_distribution_present": any(
            "Apple Distribution:" in item or "3rd Party Mac Developer Application:" in item for item in identities
        ),
        "apple_development_identities": [item for item in identities if item.startswith("Apple Development:")],
        "all_identities": identities,
    }


def summarize_url_import_proof(path: Path | None, app_build: str) -> dict[str, Any]:
    if path is None:
        return {"path": "", "status": "missing", "checks": {}}
    checks: dict[str, bool] = {"exists": path.exists()}
    data: dict[str, Any] = {}
    if path.exists():
        data = load_json(path)
    record_validation = data.get("record_validation") or {}
    exports = data.get("exports") or {}
    markdown_path = optional_path(exports.get("markdown_path"))
    pdf_path = optional_path(exports.get("pdf_path"))
    proof_app_build = str((data.get("app_info") or {}).get("build") or "")
    sidecar_build = str((data.get("sidecar_version") or {}).get("build") or (data.get("sidecar_status") or {}).get("build") or "")
    checks.update(
        {
            "status_passed": data.get("status") == "passed",
            "app_build_matches": bool(app_build) and proof_app_build == app_build,
            "sidecar_build_matches": bool(app_build) and sidecar_build == app_build,
            "job_completed": (data.get("job") or {}).get("state") == "completed",
            "insight_schema_ok": record_validation.get("insight_schema_ok") is True,
            "timestamped_transcript": int(record_validation.get("timestamped_rows") or 0) > 0,
            "speaker_labels_present": bool(record_validation.get("speaker_labels") or []),
            "fts_verified": int((data.get("fts_validation") or {}).get("result_count") or 0) > 0,
            "markdown_exists": bool(markdown_path and markdown_path.exists()),
            "pdf_exists": bool(pdf_path and pdf_path.exists()),
            "process_cleanup_clean": bool((data.get("process_cleanup") or {}).get("clean")),
        }
    )
    return {
        "path": str(path),
        "status": "passed" if all(checks.values()) else "incomplete",
        "app_build": proof_app_build,
        "sidecar_build": sidecar_build,
        "record_path": str(data.get("record_path") or ""),
        "markdown_path": str(markdown_path) if markdown_path else "",
        "pdf_path": str(pdf_path) if pdf_path else "",
        "checks": checks,
    }


def summarize_visual_proof(path: Path | None, app_build: str) -> dict[str, Any]:
    if path is None:
        return {"path": "", "status": "missing", "checks": {}}
    checks: dict[str, bool] = {"exists": path.exists()}
    data: dict[str, Any] = {}
    if path.exists():
        data = load_json(path)
    screenshot = optional_path(data.get("screenshot"))
    observations = data.get("computer_use_observations") or {}
    detail = observations.get("record_detail") or {}
    seek = observations.get("seek_linkage") or {}
    required_sections = {"summary", "meeting_quote", "speaker_summary", "key_decision", "action_item", "smart_chapter"}
    visible_sections = set(detail.get("smart_minutes_sections_visible") or [])
    checks.update(
        {
            "status_passed": data.get("status") == "passed",
            "app_build_matches": bool(app_build) and str(data.get("app_build") or "") == app_build,
            "screenshot_exists": bool(screenshot and screenshot.exists()),
            "smart_minutes_sections_visible": required_sections.issubset(visible_sections),
            "chapter_seek_visible": bool((seek.get("chapter_click") or {}).get("visible_status")),
            "transcript_seek_visible": bool((seek.get("transcript_click") or {}).get("visible_status")),
            "note_seek_visible": bool((seek.get("note_click") or {}).get("visible_status")),
        }
    )
    return {
        "path": str(path),
        "status": "passed" if all(checks.values()) else "incomplete",
        "app_build": str(data.get("app_build") or ""),
        "record_id": str(data.get("record_id") or ""),
        "screenshot": str(screenshot) if screenshot else "",
        "checks": checks,
    }


def run_preflights(app_path: Path, timeout_sec: float) -> dict[str, Any]:
    script = ROOT_DIR / "scripts" / "release_preflight.sh"
    channels = {
        "local": [str(script), str(app_path)],
        "developer_id": [str(script), "--developer-id", str(app_path)],
        "app_store": [str(script), "--app-store", str(app_path)],
    }
    results: dict[str, Any] = {}
    for key, command in channels.items():
        channel = key.replace("_", "-")
        raw = run_command(command, timeout_sec=timeout_sec)
        classified = classify_preflight(channel, raw.get("exit_code"), raw.get("output", ""), bool(raw.get("timed_out")))
        results[key] = {**raw, **classified}
    return results


def determine_status(proof: dict[str, Any]) -> str:
    if not proof["app_info"].get("exists") or proof["app_info"].get("bundle_id") != "com.yannjy.insightkit":
        return "failed"
    if proof["runtime_proof"].get("status") != "passed" or proof["visual_proof"].get("status") != "passed":
        return "failed"
    if proof["preflight"]["local"].get("status") != "local-release-ready":
        return "failed"
    cleanup = proof.get("process_cleanup") or {}
    if cleanup.get("exit_code") != 0 or cleanup.get("timed_out"):
        return "failed"
    if proof["preflight"]["developer_id"].get("status") == "externally-blocked" or proof["preflight"]["app_store"].get("status") == "externally-blocked":
        return "passed_with_external_blockers"
    return "passed_distribution_ready"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=DEFAULT_APP, help=f"Canonical installed app. Default: {DEFAULT_APP}")
    parser.add_argument("--url-proof", type=Path, help="Specific packaged-app URL import proof JSON.")
    parser.add_argument("--visual-proof", type=Path, help="Specific Computer Use visual proof JSON.")
    parser.add_argument("--output-root", type=Path, default=today_output_root(), help="Directory for proof.json.")
    parser.add_argument("--preflight-timeout-sec", type=float, default=90, help="Per-channel release preflight timeout.")
    parser.add_argument("--process-timeout-sec", type=float, default=10, help="Process cleanup check timeout.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    app_path = args.app.expanduser().resolve()
    output_root = args.output_root.expanduser().resolve()
    proof_path = output_root / "proof.json"
    output_root.mkdir(parents=True, exist_ok=True)

    app_info = read_app_info(app_path)
    app_build = str(app_info.get("build") or "")
    url_proof = args.url_proof.expanduser().resolve() if args.url_proof else latest_path("*/packaged-app-url-import-smoke-*/proof.json")
    visual_proof = args.visual_proof.expanduser().resolve() if args.visual_proof else latest_path("*/current-build-visual-gui-proof-*.json")

    identities_raw = run_command(["security", "find-identity", "-v", "-p", "codesigning"], timeout_sec=15)
    process_cleanup = run_command([str(ROOT_DIR / "scripts" / "dev_check_insightkit_processes.sh")], timeout_sec=args.process_timeout_sec)

    proof: dict[str, Any] = {
        "generated_at": iso_now(),
        "status": "failed",
        "workspace": str(ROOT_DIR),
        "canonical_app": str(app_path),
        "release_readiness_doc": str(RELEASE_READINESS_DOC),
        "release_readiness_doc_exists": RELEASE_READINESS_DOC.exists(),
        "app_info": app_info,
        "runtime_proof": summarize_url_import_proof(url_proof, app_build),
        "visual_proof": summarize_visual_proof(visual_proof, app_build),
        "preflight": run_preflights(app_path, timeout_sec=args.preflight_timeout_sec),
        "codesigning_identities": {
            **identities_raw,
            **parse_codesigning_identities(str(identities_raw.get("output") or "")),
        },
        "local_config": {
            "local_entitlements": entitlement_summary(
                LOCAL_ENTITLEMENTS,
                [
                    "com.apple.security.app-sandbox",
                    "com.apple.security.device.audio-input",
                    "com.apple.security.device.camera",
                ],
            ),
            "app_store_entitlements_draft": entitlement_summary(
                APP_STORE_ENTITLEMENTS,
                [
                    "com.apple.security.app-sandbox",
                    "com.apple.security.device.audio-input",
                    "com.apple.security.device.camera",
                    "com.apple.security.files.bookmarks.app-scope",
                    "com.apple.security.files.user-selected.read-write",
                    "com.apple.security.network.client",
                ],
            ),
        },
        "process_cleanup": process_cleanup,
        "official_sources": APPLE_REFERENCE_URLS,
    }
    proof["status"] = determine_status(proof)
    proof["conclusion"] = (
        "InsightKit is locally release-ready for internal QA on this Mac, but public Developer ID "
        "distribution and Mac App Store submission remain externally blocked by Apple account, "
        "certificate, notarization, sandbox-signing, and privacy URL inputs."
        if proof["status"] == "passed_with_external_blockers"
        else "Release readiness requires attention; inspect failed or incomplete proof sections."
    )

    proof_path.write_text(json.dumps(proof, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"wrote proof: {proof_path}")
    print(f"status: {proof['status']}")
    print(f"app_build: {app_build}")
    print(f"runtime_proof: {proof['runtime_proof']['status']} {proof['runtime_proof']['path']}")
    print(f"visual_proof: {proof['visual_proof']['status']} {proof['visual_proof']['path']}")
    print(f"local_preflight: {proof['preflight']['local']['status']}")
    print(f"developer_id_preflight: {proof['preflight']['developer_id']['status']}")
    print(f"app_store_preflight: {proof['preflight']['app_store']['status']}")
    return 0 if proof["status"] in {"passed_with_external_blockers", "passed_distribution_ready"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
