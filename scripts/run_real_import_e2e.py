#!/usr/bin/env python3
"""Run a real-media InsightKit import/export E2E proof without GUI steps."""

from __future__ import annotations

import argparse
import json
import os
import re
import socket
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Any

ROOT_DIR = Path(__file__).resolve().parent.parent
DEFAULT_SAMPLE = ROOT_DIR / "logs" / "diagnostics" / "e2e" / "real_sample_2026_5_11_en_1_30s.m4a"
DEFAULT_DIAGNOSTICS_ROOT = ROOT_DIR / "logs" / "diagnostics"
SIDECAR_SCRIPT = ROOT_DIR / "scripts" / "insight_sidecar.py"


def rpc_call(socket_path: Path, method: str, params: dict[str, Any] | None = None, timeout: float = 20) -> dict[str, Any]:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(timeout)
        client.connect(str(socket_path))
        payload = json.dumps({"id": 1, "method": method, "params": params or {}}, ensure_ascii=False) + "\n"
        client.sendall(payload.encode("utf-8"))
        data = client.recv(8 * 1024 * 1024)
    return json.loads(data.decode("utf-8"))


def rpc_result(socket_path: Path, method: str, params: dict[str, Any] | None = None, timeout: float = 20) -> dict[str, Any]:
    response = rpc_call(socket_path, method, params=params, timeout=timeout)
    if response.get("error"):
        raise RuntimeError(f"{method} failed: {response['error']}")
    result = response.get("result")
    if not isinstance(result, dict):
        raise RuntimeError(f"{method} returned non-object result: {result!r}")
    return result


def start_sidecar(socket_path: Path, db_path: Path, records_root: Path, log_path: Path, timeout_sec: float) -> subprocess.Popen[str]:
    env = os.environ.copy()
    env["INSIGHTKIT_SOCKET"] = str(socket_path)
    env["INSIGHTKIT_DB_PATH"] = str(db_path)
    env["INSIGHTKIT_RECORDS_ROOT"] = str(records_root)
    log_file = log_path.open("w", encoding="utf-8")
    proc = subprocess.Popen(
        [sys.executable, str(SIDECAR_SCRIPT)],
        cwd=str(ROOT_DIR),
        env=env,
        stdout=log_file,
        stderr=subprocess.STDOUT,
        text=True,
    )

    deadline = time.time() + timeout_sec
    while time.time() < deadline:
        if proc.poll() is not None:
            log_file.close()
            raise RuntimeError(f"sidecar exited during startup with code {proc.returncode}; see {log_path}")
        try:
            status = rpc_result(socket_path, "sidecar.status", timeout=3)
            if status.get("ready"):
                return proc
        except Exception:
            time.sleep(0.1)
    stop_sidecar(proc, socket_path)
    raise TimeoutError(f"sidecar did not become ready within {timeout_sec:.1f}s")


def stop_sidecar(proc: subprocess.Popen[str] | None, socket_path: Path) -> None:
    if proc is None or proc.poll() is not None:
        return
    try:
        rpc_result(socket_path, "sidecar.shutdown", timeout=3)
        proc.wait(timeout=5)
        return
    except Exception:
        pass
    try:
        proc.terminate()
        proc.wait(timeout=3)
    except Exception:
        proc.kill()
        proc.wait(timeout=3)


def log_progress(message: str) -> None:
    stamp = datetime.now().strftime("%H:%M:%S")
    print(f"[{stamp}] {message}", flush=True)


def wait_for_job(socket_path: Path, job_id: str, timeout_sec: float, progress_interval_sec: float) -> dict[str, Any]:
    deadline = time.time() + timeout_sec
    started = time.time()
    next_progress = started
    last_status: dict[str, Any] = {}
    while time.time() < deadline:
        status = rpc_result(socket_path, "transcription.status", {"limit": 20}, timeout=10)
        last_status = status
        jobs = status.get("jobs") or []
        job = next((row for row in jobs if row.get("id") == job_id), None)
        now = time.time()
        if now >= next_progress:
            elapsed = now - started
            if isinstance(job, dict):
                state = job.get("state", "unknown")
                stage = job.get("stage", "")
                progress_value = job.get("progress", "")
                log_progress(
                    f"import job {job_id} state={state} stage={stage} progress={progress_value} elapsed={elapsed:.0f}s"
                )
            else:
                log_progress(f"waiting for import job {job_id} to appear elapsed={elapsed:.0f}s")
            next_progress = now + max(1.0, progress_interval_sec)
        if isinstance(job, dict) and job.get("state") in {"completed", "failed", "cancelled", "paused_by_live"}:
            log_progress(f"import job {job_id} finished state={job.get('state')} progress={job.get('progress', '')}")
            return {"job": job, "status": status}
        time.sleep(1)
    try:
        rpc_result(socket_path, "transcription.cancel_job", {"job_id": job_id, "reason": "e2e_timeout"}, timeout=5)
    except Exception:
        pass
    raise TimeoutError(f"job {job_id} did not finish within {timeout_sec:.1f}s; last_status={last_status}")


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def first_search_token(transcript_rows: list[dict[str, Any]]) -> str:
    for row in transcript_rows:
        text = str(row.get("text", "") or "")
        for token in re.findall(r"[A-Za-z][A-Za-z0-9_'-]{3,}", text):
            lower = token.lower().strip("'")
            if lower not in {"this", "that", "with", "from", "have", "will", "meeting"}:
                return lower
    raise RuntimeError("no searchable token found in transcript")


def validate_record(record_path: Path) -> dict[str, Any]:
    required_files = ["metadata.json", "transcript.json", "minutes.json", "insight_package.json", "notes.md"]
    missing = [name for name in required_files if not (record_path / name).exists()]
    media_files = sorted(path.name for path in record_path.glob("recording.*"))
    if missing:
        raise RuntimeError(f"record folder is missing required files: {missing}")
    if not media_files:
        raise RuntimeError("record folder has no recording.* media file")

    metadata = load_json(record_path / "metadata.json")
    transcript = load_json(record_path / "transcript.json")
    minutes = load_json(record_path / "minutes.json")
    insight = load_json(record_path / "insight_package.json")
    analysis = metadata.get("analysis") if isinstance(metadata, dict) else None
    if not isinstance(analysis, dict):
        raise RuntimeError("metadata.json missing analysis provider metadata")
    if not str(analysis.get("provider", "") or "").strip():
        raise RuntimeError("metadata analysis metadata missing provider")
    if not str(analysis.get("source", "") or "").strip():
        raise RuntimeError("metadata analysis metadata missing source")

    if not isinstance(transcript, list) or not transcript:
        raise RuntimeError("transcript.json has no rows")
    timestamped = [
        row for row in transcript
        if int(row.get("end_ms", 0) or 0) > int(row.get("start_ms", 0) or 0)
    ]
    if not timestamped:
        raise RuntimeError("transcript.json has no timestamped rows")
    if not any(str(row.get("speaker", "") or "").strip() for row in transcript):
        raise RuntimeError("transcript.json has no speaker labels or conservative speaker fallback")

    required_minutes = ["structured_summary", "highlights", "key_decisions", "action_items", "timeline_beats"]
    missing_minutes = [key for key in required_minutes if key not in minutes]
    if missing_minutes:
        raise RuntimeError(f"minutes.json missing fields: {missing_minutes}")

    try:
        from insightkit.insights.schema_validator import validate_insight_package

        validate_insight_package(insight)
        schema_ok = True
    except Exception as exc:
        raise RuntimeError(f"insight_package.json schema validation failed: {exc}") from exc

    note_text = "00:05 E2E verification note bound to playback time."
    (record_path / "notes.md").write_text(note_text + "\n", encoding="utf-8")

    return {
        "metadata": metadata,
        "analysis": analysis,
        "transcript_rows": len(transcript),
        "timestamped_rows": len(timestamped),
        "speaker_labels": sorted({str(row.get("speaker", "") or "").strip() for row in transcript if str(row.get("speaker", "") or "").strip()}),
        "media_files": media_files,
        "minutes_keys": sorted(minutes.keys()),
        "insight_schema_ok": schema_ok,
        "note_text": note_text,
    }


def verify_exports(socket_path: Path, meeting_id: str, output_dir: Path) -> dict[str, Any]:
    output_dir.mkdir(parents=True, exist_ok=True)
    markdown = rpc_result(
        socket_path,
        "document.export",
        {"meeting_id": meeting_id, "format": "markdown", "output_dir": str(output_dir)},
        timeout=30,
    )
    pdf = rpc_result(
        socket_path,
        "document.export",
        {"meeting_id": meeting_id, "format": "pdf", "output_dir": str(output_dir)},
        timeout=60,
    )
    markdown_path = Path(str(markdown["path"]))
    pdf_path = Path(str(pdf["path"]))
    markdown_text = markdown_path.read_text(encoding="utf-8")
    required_sections = [
        "## 会议信封",
        "## 长文版结构化总结",
        "## 会议金句",
        "## 发言人总结",
        "## 关键决策",
        "## 待办事项",
        "## 智能章节",
        "## 相关链接",
        "AI 免责声明",
        "媒体回放",
    ]
    missing = [section for section in required_sections if section not in markdown_text]
    if missing:
        raise RuntimeError(f"markdown export missing sections: {missing}")
    if not pdf_path.read_bytes().startswith(b"%PDF-"):
        raise RuntimeError(f"pdf export is not a PDF: {pdf_path}")
    return {
        "markdown_path": str(markdown_path),
        "pdf_path": str(pdf_path),
        "markdown_required_sections": required_sections,
        "pdf_header": "%PDF-",
    }


def verify_fts(db_path: Path, meeting_id: str, transcript_rows: list[dict[str, Any]]) -> dict[str, Any]:
    from insightkit.data.store import InsightStore

    token = first_search_token(transcript_rows)
    store = InsightStore(db_path)
    try:
        rows = store.search_segments(meeting_id, token, limit=5)
    finally:
        store.close()
    if not rows:
        raise RuntimeError(f"FTS search returned no rows for token {token!r}")
    return {
        "query": token,
        "result_count": len(rows),
        "first_result": rows[0],
    }


def today_output_root() -> Path:
    day = datetime.now().strftime("%Y-%m-%d")
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    return DEFAULT_DIAGNOSTICS_ROOT / day / f"real-import-e2e-{stamp}"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sample", type=Path, default=DEFAULT_SAMPLE, help=f"Real media sample. Default: {DEFAULT_SAMPLE}")
    parser.add_argument("--output-root", type=Path, default=today_output_root(), help="Directory for DB, records, exports, sidecar log, and proof JSON.")
    parser.add_argument("--timeout-sec", type=float, default=240, help="Maximum seconds to wait for the import job.")
    parser.add_argument("--startup-timeout-sec", type=float, default=12, help="Maximum seconds to wait for sidecar startup.")
    parser.add_argument("--progress-interval-sec", type=float, default=10, help="Seconds between import progress heartbeat lines.")
    parser.add_argument("--leave-sidecar-running", action="store_true", help="Keep the temporary sidecar running after the proof.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    sample = args.sample.expanduser().resolve()
    if not sample.exists() or not sample.is_file():
        print(f"FAIL: sample not found: {sample}")
        return 1

    output_root = args.output_root.expanduser().resolve()
    output_root.mkdir(parents=True, exist_ok=True)
    socket_path = Path(f"/tmp/insightkit-real-e2e-{os.getpid()}.sock")
    db_path = output_root / "insightkit-e2e.db"
    records_root = output_root / "Records"
    exports_root = output_root / "exports"
    proof_path = output_root / "proof.json"
    sidecar_log = output_root / "sidecar.log"
    sidecar: subprocess.Popen[str] | None = None
    proof: dict[str, Any] = {
        "date": datetime.now().isoformat(timespec="seconds"),
        "sample": str(sample),
        "output_root": str(output_root),
        "socket_path": str(socket_path),
        "db_path": str(db_path),
        "records_root": str(records_root),
        "exports_root": str(exports_root),
        "sidecar_log": str(sidecar_log),
        "timeout_sec": args.timeout_sec,
        "startup_timeout_sec": args.startup_timeout_sec,
        "progress_interval_sec": args.progress_interval_sec,
        "status": "failed",
    }

    try:
        log_progress(f"starting temporary sidecar socket={socket_path}")
        sidecar = start_sidecar(socket_path, db_path, records_root, sidecar_log, args.startup_timeout_sec)
        proof["sidecar_pid"] = sidecar.pid
        log_progress(f"sidecar ready pid={sidecar.pid}")

        log_progress(f"submitting real media import sample={sample}")
        imported = rpc_result(
            socket_path,
            "transcription.import_file",
            {"file_path": str(sample), "title": sample.stem},
            timeout=10,
        )
        job_id = str(imported["job_id"])
        meeting_id = str(imported["meeting_id"])
        proof["import"] = imported
        log_progress(f"import submitted job_id={job_id} meeting_id={meeting_id}")

        completed = wait_for_job(socket_path, job_id, args.timeout_sec, args.progress_interval_sec)
        job = completed["job"]
        if job.get("state") != "completed":
            raise RuntimeError(f"import job ended as {job.get('state')}: {job}")
        last_completed = completed["status"].get("last_completed") or {}
        record_path = Path(str(last_completed.get("record_path", ""))).expanduser()
        if not record_path.exists():
            raise RuntimeError(f"completed job did not produce an existing record_path: {record_path}")

        proof["job"] = job
        proof["last_completed"] = last_completed
        proof["record_path"] = str(record_path)
        record = validate_record(record_path)
        transcript_rows = load_json(record_path / "transcript.json")
        proof["record_validation"] = record
        proof["fts_validation"] = verify_fts(db_path, meeting_id, transcript_rows)
        proof["exports"] = verify_exports(socket_path, meeting_id, exports_root)
        proof["status"] = "passed"
        print(f"PASS: real import E2E proof written to {proof_path}")
        print(f"Record: {record_path}")
        print(f"Markdown: {proof['exports']['markdown_path']}")
        print(f"PDF: {proof['exports']['pdf_path']}")
        return 0
    except Exception as exc:
        proof["error"] = str(exc)
        print(f"FAIL: {exc}")
        return 1
    finally:
        if sidecar is not None and not args.leave_sidecar_running:
            stop_sidecar(sidecar, socket_path)
            proof["sidecar_stopped"] = sidecar.poll() is not None
        proof_path.write_text(json.dumps(proof, ensure_ascii=False, indent=2), encoding="utf-8")


if __name__ == "__main__":
    raise SystemExit(main())
