#!/usr/bin/env python3
"""Verify the ASR Runtime Profile slice and write a durable proof JSON."""

from __future__ import annotations

import argparse
import json
from datetime import datetime
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Any

from insightkit.data.store import InsightStore
from insightkit.ipc.server import InsightRPCServer
from scripts.asr_runtime_profile import APPLE_SPEECH_ENGINE, ASR_PROFILE_SCHEMA_VERSION


REQUIRED_PROFILE_FIELDS = {
    "schema_version",
    "configured_engine",
    "active_engine",
    "engine_profiles",
    "live_asr",
    "final_media_asr",
    "warm",
    "backend",
    "diarization",
    "technical_status",
    "degradation",
    "user_recovery_hint",
}


def _asr_check(diagnostics: dict[str, Any]) -> dict[str, Any]:
    for item in diagnostics.get("checks") or []:
        if isinstance(item, dict) and item.get("id") == "asr_runtime":
            return item
    return {}


def verify_asr_runtime_profile() -> dict[str, Any]:
    with TemporaryDirectory() as tmp:
        server = InsightRPCServer(store=InsightStore(db_path=Path(tmp) / "insightkit.db"))
        try:
            status_response = server._dispatch({
                "id": 1,
                "method": "asr.runtime.status",
                "params": {},
            })
            diagnostics = server._diagnostics_quick_check({"probe_timeout_sec": 1})
        finally:
            server.shutdown()

    status = status_response.get("result") or {}
    profile = status.get("profile") or {}
    diagnostics_asr = _asr_check(diagnostics)
    diagnostics_profile = diagnostics_asr.get("runtime_profile") or {}

    findings: list[dict[str, Any]] = []
    missing = sorted(REQUIRED_PROFILE_FIELDS - set(profile))
    if missing:
        findings.append({"code": "missing_profile_fields", "fields": missing})
    if profile.get("schema_version") != ASR_PROFILE_SCHEMA_VERSION:
        findings.append({
            "code": "profile_schema_mismatch",
            "expected": ASR_PROFILE_SCHEMA_VERSION,
            "actual": profile.get("schema_version"),
        })
    if APPLE_SPEECH_ENGINE not in (profile.get("engine_profiles") or {}):
        findings.append({"code": "missing_apple_speech_peer_engine"})
    if "ready" not in (profile.get("live_asr") or {}):
        findings.append({"code": "missing_live_asr_readiness"})
    if "ready" not in (profile.get("final_media_asr") or {}):
        findings.append({"code": "missing_final_media_asr_readiness"})
    for key in ("schema_version", "active_engine", "technical_status"):
        if diagnostics_profile.get(key) != profile.get(key):
            findings.append({
                "code": "diagnostics_profile_mismatch",
                "field": key,
                "status_value": profile.get(key),
                "diagnostics_value": diagnostics_profile.get(key),
            })

    return {
        "status": "passed" if not findings else "failed",
        "rpc_method": "asr.runtime.status",
        "profile_schema_version": profile.get("schema_version"),
        "active_engine": profile.get("active_engine"),
        "configured_engine": profile.get("configured_engine"),
        "technical_status": profile.get("technical_status"),
        "live_asr_ready": (profile.get("live_asr") or {}).get("ready"),
        "final_media_asr_ready": (profile.get("final_media_asr") or {}).get("ready"),
        "apple_speech_profile": (profile.get("engine_profiles") or {}).get(APPLE_SPEECH_ENGINE, {}),
        "diagnostics_asr_status": diagnostics_asr.get("status"),
        "diagnostics_profile_status": diagnostics_profile.get("technical_status"),
        "sidecar_dispatch_path_checked": "result" in status_response,
        "installed_app_smoke": "not_run_profile_status_only_no_installed_bundle_behavior_changed",
        "findings": findings,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("logs") / "diagnostics" / datetime.now().strftime("%Y-%m-%d") / f"asr-runtime-profile-{datetime.now().strftime('%Y%m%d-%H%M%S')}",
    )
    args = parser.parse_args()

    proof = verify_asr_runtime_profile()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    proof_path = args.output_dir / "proof.json"
    proof_path.write_text(json.dumps(proof, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"wrote proof: {proof_path}")
    print(f"status: {proof['status']}")
    return 0 if proof["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
