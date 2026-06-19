#!/usr/bin/env python3
"""Verify the provider through the running macOS app sidecar socket.

This differs from verify_current_provider.py: it does not read Keychain itself.
The macOS app must start the sidecar, and this script verifies the environment
that the app injected into that sidecar.
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Any

ROOT_DIR = Path(__file__).resolve().parent.parent
DEFAULT_SOCKET_PATH = Path(f"/tmp/insightkit-app-{os.getuid()}.sock")


def _today_dir() -> Path:
    return ROOT_DIR / "logs" / "diagnostics" / datetime.now().strftime("%Y-%m-%d")


def _iso_now() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def rpc_call(socket_path: Path, method: str, params: dict[str, Any] | None = None, timeout: float = 20) -> dict[str, Any]:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(max(1.0, timeout))
        client.connect(str(socket_path))
        request = json.dumps(
            {"id": int(time.time() * 1000) % 1_000_000, "method": method, "params": params or {}},
            ensure_ascii=False,
        ) + "\n"
        client.sendall(request.encode("utf-8"))
        data = client.recv(4 * 1024 * 1024)
    payload = json.loads(data.decode("utf-8"))
    if payload.get("error"):
        raise RuntimeError(payload["error"].get("message") or str(payload["error"]))
    return payload["result"]


def load_transcript_rows(path: Path, limit: int) -> list[dict[str, Any]]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    rows = payload.get("segments") if isinstance(payload, dict) else payload
    if not isinstance(rows, list):
        raise RuntimeError(f"transcript rows must be a list: {path}")

    cleaned: list[dict[str, Any]] = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        text = str(row.get("text") or "").strip()
        if not text:
            continue
        cleaned.append({
            "speaker": str(row.get("speaker") or row.get("speaker_label") or "SPEAKER_00"),
            "start_ms": int(row.get("start_ms", row.get("start", 0)) or 0),
            "end_ms": int(row.get("end_ms", row.get("end", 0)) or 0),
            "source": str(row.get("source") or "file"),
            "confidence": float(row.get("confidence", 0.0) or 0.0),
            "text": text,
        })
        if len(cleaned) >= limit:
            break
    if not cleaned:
        raise RuntimeError(f"no usable transcript rows in {path}")
    return cleaned


def default_transcript_path() -> Path:
    candidates = sorted(
        ROOT_DIR.glob("logs/diagnostics/2026-05-25/real-import-e2e-*/Records/*/transcript.json"),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    if candidates:
        return candidates[0]
    raise RuntimeError("no real-import transcript sample found under logs/diagnostics/2026-05-25")


def selected_vendor_payload(status: dict[str, Any]) -> dict[str, Any]:
    selected = str(status.get("selected_vendor") or "").strip().lower()
    vendors = status.get("vendors") or {}
    if not selected or selected not in vendors:
        raise RuntimeError(f"selected provider missing from status: {selected}")
    payload = dict(vendors[selected])
    payload["vendor"] = selected
    return payload


def summarize_final_result(result: dict[str, Any]) -> dict[str, Any]:
    package = result.get("insight_package") or {}
    overview = package.get("session_overview") or {}
    return {
        "ok": True,
        "provider_vendor": str(result.get("provider_vendor") or result.get("provider") or ""),
        "provider_model": str(result.get("provider_model") or ""),
        "strict_mode": bool(result.get("strict_mode", False)),
        "title": str(overview.get("title") or ""),
        "topics_count": len(overview.get("topics") or []),
        "highlights_count": len(package.get("highlight_insights") or []),
        "speaker_summaries_count": len(package.get("speaker_perspectives") or []),
        "decisions_count": len(package.get("decision_ledger") or []),
        "actions_count": len(package.get("action_tracks") or []),
        "chapters_count": len(package.get("timeline_beats") or []),
        "needs_review_count": int(result.get("needs_review_count") or 0),
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket-path", type=Path, default=DEFAULT_SOCKET_PATH)
    parser.add_argument("--transcript-json", type=Path, default=None)
    parser.add_argument("--rows", type=int, default=5)
    parser.add_argument("--probe-timeout-sec", type=int, default=30)
    parser.add_argument("--final-timeout-sec", type=int, default=120)
    parser.add_argument("--output", type=Path, default=None)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    proof_path = args.output or (_today_dir() / "app-side-provider-validation-proof.json")
    proof_path.parent.mkdir(parents=True, exist_ok=True)

    transcript_path = args.transcript_json or default_transcript_path()
    rows = load_transcript_rows(transcript_path, max(1, args.rows))
    meeting_id = f"app-provider-proof-{int(time.time())}"

    proof: dict[str, Any] = {
        "generated_at": _iso_now(),
        "socket_path": str(args.socket_path),
        "transcript_sample": {
            "path": str(transcript_path),
            "rows_used": len(rows),
            "text_redacted": True,
        },
        "sidecar_status": {},
        "providers_status": {},
        "selected_provider": {},
        "provider_probe": {"attempted": False, "ok": False},
        "final_build": {"attempted": False, "ok": False},
        "meeting_id": meeting_id,
    }

    try:
        proof["sidecar_status"] = rpc_call(args.socket_path, "sidecar.status", {}, timeout=5)
        status = rpc_call(args.socket_path, "analysis.providers.status", {"probe_active": False}, timeout=10)
        proof["providers_status"] = {
            "selected_vendor": status.get("selected_vendor"),
            "active_ready": bool(status.get("active_ready", False)),
        }
        selected = selected_vendor_payload(status)
        proof["selected_provider"] = {
            "vendor": selected.get("vendor"),
            "base_url": selected.get("base_url"),
            "model_id": selected.get("model_id"),
            "configured": bool(selected.get("configured", False)),
            "has_api_key": bool(selected.get("has_api_key", False)),
            "model_ready": bool(selected.get("model_ready", False)),
        }

        started = time.monotonic()
        try:
            probe = rpc_call(
                args.socket_path,
                "analysis.provider.probe",
                {
                    "provider_vendor": selected.get("vendor"),
                    "provider_model": selected.get("model_id"),
                    "base_url": selected.get("base_url"),
                    "force_refresh": True,
                    "probe_timeout_sec": args.probe_timeout_sec,
                },
                timeout=args.probe_timeout_sec + 10,
            )
            proof["provider_probe"] = {
                "attempted": True,
                "ok": bool(probe.get("ok")),
                "code": str(probe.get("code") or ""),
                "message": str(probe.get("message") or ""),
                "hint": str(probe.get("hint") or ""),
                "duration_sec": round(time.monotonic() - started, 3),
            }
        except Exception as exc:
            proof["provider_probe"] = {
                "attempted": True,
                "ok": False,
                "code": "exception",
                "message": str(exc),
                "duration_sec": round(time.monotonic() - started, 3),
            }

        rpc_call(args.socket_path, "session.start", {"meeting_id": meeting_id, "title": "App-side provider proof", "source": "file"}, timeout=10)
        delta = rpc_call(args.socket_path, "transcript.delta", {"meeting_id": meeting_id, "segments": rows}, timeout=10)
        proof["transcript_delta"] = {"ingested": int(delta.get("ingested") or 0)}

        started = time.monotonic()
        try:
            final_result = rpc_call(
                args.socket_path,
                "insight.build_final",
                {
                    "meeting_id": meeting_id,
                    "provider_vendor": selected.get("vendor"),
                    "provider_model": selected.get("model_id"),
                    "strict_mode": True,
                },
                timeout=args.final_timeout_sec,
            )
            proof["final_build"] = summarize_final_result(final_result)
            proof["final_build"]["duration_sec"] = round(time.monotonic() - started, 3)
        except Exception as exc:
            proof["final_build"] = {
                "attempted": True,
                "ok": False,
                "message": str(exc),
                "duration_sec": round(time.monotonic() - started, 3),
            }
        finally:
            try:
                rpc_call(args.socket_path, "session.stop", {"meeting_id": meeting_id}, timeout=10)
                proof["session_stopped"] = True
            except Exception as exc:
                proof["session_stopped"] = False
                proof["session_stop_error"] = str(exc)
    except Exception as exc:
        proof["fatal_error"] = str(exc)

    final_provider = str((proof.get("final_build") or {}).get("provider_vendor") or "")
    if final_provider and final_provider not in {"local-extractive", "stored"}:
        proof["outcome"] = "verified_app_side_cloud_final_build"
    elif proof.get("provider_probe", {}).get("ok"):
        proof["outcome"] = "verified_app_side_cloud_probe_only"
    elif proof.get("selected_provider", {}).get("has_api_key"):
        proof["outcome"] = "app_side_key_injected_but_provider_unverified"
    else:
        proof["outcome"] = "app_side_provider_unverified"

    proof_path.write_text(json.dumps(proof, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"wrote proof: {proof_path}")
    print(f"outcome: {proof['outcome']}")
    print(f"selected: {proof.get('selected_provider')}")
    print(f"probe_ok: {proof.get('provider_probe', {}).get('ok')}")
    print(f"final_provider: {proof.get('final_build', {}).get('provider_vendor')}")
    return 0 if proof["outcome"] in {"verified_app_side_cloud_final_build", "verified_app_side_cloud_probe_only", "app_side_key_injected_but_provider_unverified"} else 1


if __name__ == "__main__":
    sys.path.insert(0, str(ROOT_DIR))
    raise SystemExit(main())
