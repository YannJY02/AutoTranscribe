#!/usr/bin/env python3
"""Run a repeatable installed-app URL import smoke against real media.

This is not a visual UI replacement for bounded Computer Use E2E. It verifies
that the packaged macOS app is installed, owns the `insightkit://` URL import
entrypoint, starts its app-owned sidecar, imports real media, persists the
record, supports SQLite/FTS, exports Markdown/PDF, and quits cleanly.
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Any
from urllib.parse import quote

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from run_real_import_e2e import (
    DEFAULT_SAMPLE,
    evaluate_database_oracle,
    load_json,
    rpc_result,
    validate_record,
    verify_exports,
    verify_fts,
    wait_for_job,
)

ROOT_DIR = Path(__file__).resolve().parent.parent
DEFAULT_APP = Path.home() / "Applications" / "InsightKit.app"
DEFAULT_SOCKET = Path(f"/tmp/insightkit-app-{os.getuid()}.sock")
DEFAULT_DB = Path.home() / "Library/Application Support/InsightKit/data/insightkit.db"
DEFAULT_DIAGNOSTICS_ROOT = ROOT_DIR / "logs" / "diagnostics"


def today_output_root() -> Path:
    day = datetime.now().strftime("%Y-%m-%d")
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    return DEFAULT_DIAGNOSTICS_ROOT / day / f"packaged-app-url-import-smoke-{stamp}"


def build_import_url(sample: Path) -> str:
    return f"insightkit://import?path={quote(str(sample), safe='')}"


def read_app_info(app_path: Path) -> dict[str, Any]:
    info_path = app_path / "Contents" / "Info.plist"
    with info_path.open("rb") as fh:
        info = plistlib.load(fh)
    schemes: list[str] = []
    for entry in info.get("CFBundleURLTypes", []) or []:
        schemes.extend(entry.get("CFBundleURLSchemes", []) or [])
    return {
        "path": str(app_path),
        "info_plist": str(info_path),
        "bundle_id": info.get("CFBundleIdentifier", ""),
        "display_name": info.get("CFBundleDisplayName", info.get("CFBundleName", "")),
        "version": info.get("CFBundleShortVersionString", ""),
        "build": info.get("CFBundleVersion", ""),
        "url_schemes": schemes,
    }


def run_checked(command: list[str], timeout: float = 30) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=str(ROOT_DIR),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
        check=True,
    )


def quit_app(timeout: float = 12) -> dict[str, Any]:
    proc = run_checked([str(ROOT_DIR / "scripts" / "dev_quit_insightkit_processes.sh")], timeout=timeout)
    return {
        "command": "scripts/dev_quit_insightkit_processes.sh",
        "returncode": proc.returncode,
        "output": proc.stdout.strip(),
    }


def wait_for_socket(socket_path: Path, timeout_sec: float) -> dict[str, Any]:
    deadline = time.time() + timeout_sec
    last_error = ""
    while time.time() < deadline:
        try:
            status = rpc_result(socket_path, "sidecar.status", timeout=5)
            if status.get("ready"):
                return status
        except Exception as exc:
            last_error = str(exc)
        time.sleep(0.25)
    raise TimeoutError(f"app sidecar socket did not become ready at {socket_path}: {last_error}")


def job_matches_sample(job: dict[str, Any], sample: Path) -> bool:
    source = str(job.get("source_path", "") or "")
    if not source:
        return False
    try:
        return Path(source).expanduser().resolve() == sample.expanduser().resolve()
    except Exception:
        return source == str(sample)


def wait_for_import_job(socket_path: Path, sample: Path, timeout_sec: float) -> dict[str, Any]:
    deadline = time.time() + timeout_sec
    last_status: dict[str, Any] = {}
    while time.time() < deadline:
        status = rpc_result(socket_path, "transcription.status", {"limit": 50}, timeout=10)
        last_status = status
        candidates: list[dict[str, Any]] = []
        active = status.get("active_job")
        if isinstance(active, dict):
            candidates.append(active)
        for key in ("queue", "jobs"):
            rows = status.get(key) or []
            if isinstance(rows, list):
                candidates.extend(row for row in rows if isinstance(row, dict))
        for job in candidates:
            if job_matches_sample(job, sample):
                return {"job": job, "status": status}
        time.sleep(0.5)
    raise TimeoutError(f"no import job appeared for {sample}; last_status={last_status}")


def verify_process_cleanup(socket_path: Path) -> dict[str, Any]:
    proc = run_checked([str(ROOT_DIR / "scripts" / "dev_check_insightkit_processes.sh")], timeout=8)
    output = proc.stdout.strip()
    return {
        "command": "scripts/dev_check_insightkit_processes.sh",
        "output": output,
        "socket_exists": socket_path.exists(),
        "clean": "No socket:" in output and "InsightKitApp processes\n==> InsightKit sidecar processes" in output,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=DEFAULT_APP, help=f"Installed app path. Default: {DEFAULT_APP}")
    parser.add_argument("--sample", type=Path, default=DEFAULT_SAMPLE, help=f"Real media sample. Default: {DEFAULT_SAMPLE}")
    parser.add_argument("--socket-path", type=Path, default=DEFAULT_SOCKET, help=f"App sidecar socket. Default: {DEFAULT_SOCKET}")
    parser.add_argument("--db-path", type=Path, default=DEFAULT_DB, help=f"App SQLite DB path. Default: {DEFAULT_DB}")
    parser.add_argument("--output-root", type=Path, default=today_output_root(), help="Proof and export output directory.")
    parser.add_argument("--startup-timeout-sec", type=float, default=30, help="Seconds to wait for app sidecar startup.")
    parser.add_argument("--job-discovery-timeout-sec", type=float, default=30, help="Seconds to wait for URL import job creation.")
    parser.add_argument("--timeout-sec", type=float, default=240, help="Seconds to wait for import completion.")
    parser.add_argument("--progress-interval-sec", type=float, default=10, help="Seconds between job progress lines.")
    parser.add_argument("--leave-app-running", action="store_true", help="Do not quit the app at the end.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    app_path = args.app.expanduser().resolve()
    sample = args.sample.expanduser().resolve()
    output_root = args.output_root.expanduser().resolve()
    exports_root = output_root / "exports"
    proof_path = output_root / "proof.json"
    output_root.mkdir(parents=True, exist_ok=True)

    proof: dict[str, Any] = {
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "status": "failed",
        "app": str(app_path),
        "sample": str(sample),
        "socket_path": str(args.socket_path),
        "db_path": str(args.db_path),
        "output_root": str(output_root),
    }

    try:
        if not app_path.exists():
            raise FileNotFoundError(f"app not found: {app_path}")
        if not sample.exists() or not sample.is_file():
            raise FileNotFoundError(f"sample not found: {sample}")

        app_info = read_app_info(app_path)
        proof["app_info"] = app_info
        if app_info.get("bundle_id") != "com.yannjy.insightkit":
            raise RuntimeError(f"unexpected bundle id: {app_info.get('bundle_id')}")
        if "insightkit" not in app_info.get("url_schemes", []):
            raise RuntimeError("installed app does not register insightkit:// URL scheme")

        proof["pre_quit"] = quit_app()
        open_app = run_checked(["open", str(app_path)], timeout=15)
        proof["open_app"] = {"command": f"open {app_path}", "output": open_app.stdout.strip()}
        time.sleep(1.0)

        import_url = build_import_url(sample)
        proof["import_url"] = import_url
        open_url = run_checked(["open", "-b", "com.yannjy.insightkit", import_url], timeout=15)
        proof["open_url"] = {"command": "open -b com.yannjy.insightkit insightkit://import?path=<redacted>", "output": open_url.stdout.strip()}

        proof["sidecar_status"] = wait_for_socket(args.socket_path, args.startup_timeout_sec)
        proof["sidecar_version"] = rpc_result(args.socket_path, "sidecar.version", timeout=10)

        discovered = wait_for_import_job(args.socket_path, sample, args.job_discovery_timeout_sec)
        job_id = str(discovered["job"]["id"])
        proof["discovered_job"] = discovered["job"]

        completed = wait_for_job(args.socket_path, job_id, args.timeout_sec, args.progress_interval_sec)
        job = completed["job"]
        proof["job"] = job
        proof["last_completed"] = completed["status"].get("last_completed")
        if job.get("state") != "completed":
            raise RuntimeError(f"URL import job ended as {job.get('state')}: {job}")

        last_completed = completed["status"].get("last_completed") or {}
        record_path = Path(str(last_completed.get("record_path", ""))).expanduser()
        if not record_path.exists():
            raise RuntimeError(f"completed job did not produce an existing record_path: {record_path}")

        proof["record_path"] = str(record_path)
        record = validate_record(record_path)
        transcript_rows = load_json(record_path / "transcript.json")
        proof["record_validation"] = record
        proof["fts_validation"] = verify_fts(args.db_path.expanduser(), str(job["meeting_id"]), transcript_rows)
        database_oracle = evaluate_database_oracle(
            args.db_path,
            meeting_id=str(job["meeting_id"]),
            job_id=job_id,
            expected_source_path=sample,
            expected_segment_count=len(transcript_rows),
        )
        proof["oracles"] = {"database": database_oracle}
        if not database_oracle["passed"]:
            raise RuntimeError(
                f"database oracle failed: {database_oracle['failed_assertions']}"
            )
        proof["exports"] = verify_exports(args.socket_path, str(job["meeting_id"]), exports_root)
        proof["status"] = "passed"
        print(f"PASS: packaged app URL import smoke proof written to {proof_path}")
        print(f"Record: {record_path}")
        print(f"Markdown: {proof['exports']['markdown_path']}")
        print(f"PDF: {proof['exports']['pdf_path']}")
        return 0
    except Exception as exc:
        proof["error"] = str(exc)
        print(f"FAIL: {exc}")
        return 1
    finally:
        if not args.leave_app_running:
            try:
                proof["post_quit"] = quit_app()
                proof["process_cleanup"] = verify_process_cleanup(args.socket_path)
            except Exception as exc:
                proof["cleanup_error"] = str(exc)
        proof_path.write_text(json.dumps(proof, ensure_ascii=False, indent=2), encoding="utf-8")


if __name__ == "__main__":
    raise SystemExit(main())
