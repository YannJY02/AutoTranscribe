#!/usr/bin/env python3
"""Verify the currently selected InsightKit analysis provider without logging secrets."""

from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Callable

ROOT_DIR = Path(__file__).resolve().parent.parent
DEFAULT_CONFIG = Path.home() / "Library" / "Application Support" / "InsightKit" / "runtime_config_v1.json"
KEYCHAIN_SERVICE = "com.yannjy.insightkit.keys"
VENDOR_ENV = {
    "openai": ("OPENAI_BASE_URL", "OPENAI_MODEL", "OPENAI_API_KEY"),
    "gemini": ("GEMINI_BASE_URL", "GEMINI_MODEL", "GEMINI_API_KEY"),
    "deepseek": ("DEEPSEEK_BASE_URL", "DEEPSEEK_MODEL", "DEEPSEEK_API_KEY"),
    "qwen": ("QWEN_BASE_URL", "QWEN_MODEL", "QWEN_API_KEY"),
    "doubao": ("DOUBAO_BASE_URL", "DOUBAO_MODEL", "DOUBAO_API_KEY"),
}


class StepTimeout(TimeoutError):
    pass


def _today_dir() -> Path:
    return ROOT_DIR / "logs" / "diagnostics" / datetime.now().strftime("%Y-%m-%d")


def _iso_now() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def load_config(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def active_profile(config: dict[str, Any]) -> dict[str, Any]:
    analysis = config.get("analysis") or {}
    vendor = str(analysis.get("selectedVendor") or "deepseek").strip().lower()
    providers = analysis.get("providers") or []
    for profile in providers:
        if str(profile.get("vendor") or "").strip().lower() == vendor:
            return {
                "vendor": vendor,
                "base_url": str(profile.get("baseURL") or "").strip(),
                "model_id": str(profile.get("modelID") or "").strip(),
                "api_key_ref": str(profile.get("apiKeyRef") or f"vendor.{vendor}.api_key").strip(),
            }
    raise RuntimeError(f"active provider profile not found: {vendor}")


def keychain_read(account: str, timeout_sec: float) -> tuple[str, dict[str, Any]]:
    started = time.monotonic()
    cmd = [
        "security",
        "find-generic-password",
        "-s",
        KEYCHAIN_SERVICE,
        "-a",
        account,
        "-w",
    ]
    try:
        result = subprocess.run(
            cmd,
            text=True,
            capture_output=True,
            timeout=max(1.0, timeout_sec),
            check=False,
        )
    except subprocess.TimeoutExpired:
        return "", {
            "service": KEYCHAIN_SERVICE,
            "account": account,
            "status": "timeout",
            "duration_sec": round(time.monotonic() - started, 3),
        }

    secret = result.stdout.strip()
    status = "found" if result.returncode == 0 and secret else "missing"
    if result.returncode != 0 and result.stderr.strip():
        status = "error"
    return secret if status == "found" else "", {
        "service": KEYCHAIN_SERVICE,
        "account": account,
        "status": status,
        "returncode": result.returncode,
        "duration_sec": round(time.monotonic() - started, 3),
    }


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
        cleaned.append(
            {
                "speaker": str(row.get("speaker") or row.get("speaker_label") or "SPEAKER_00"),
                "start_ms": int(row.get("start_ms", row.get("start", 0)) or 0),
                "end_ms": int(row.get("end_ms", row.get("end", 0)) or 0),
                "text": text,
            }
        )
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
    fallback = ROOT_DIR / "logs" / "diagnostics" / "2026-05-25" / "real-import-e2e-20260525-162100" / "Records"
    candidates = sorted(fallback.glob("*/transcript.json"))
    if candidates:
        return candidates[0]
    raise RuntimeError("no real-import transcript sample found under logs/diagnostics/2026-05-25")


def with_timeout(label: str, timeout_sec: int, fn: Callable[[], Any]) -> Any:
    def _handler(signum: int, frame: Any) -> None:
        _ = (signum, frame)
        raise StepTimeout(f"{label} timed out after {timeout_sec}s")

    previous = signal.signal(signal.SIGALRM, _handler)
    signal.alarm(max(1, int(timeout_sec)))
    try:
        return fn()
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous)


def configure_provider_env(profile: dict[str, Any], api_key: str, strict_mode: bool) -> None:
    vendor = profile["vendor"]
    base_env, model_env, key_env = VENDOR_ENV[vendor]
    os.environ["INSIGHTKIT_PROVIDER_VENDOR"] = vendor
    os.environ["INSIGHTKIT_PROVIDER_MODEL"] = profile["model_id"]
    os.environ["INSIGHTKIT_STRICT_MODE"] = "1" if strict_mode else "0"
    os.environ[base_env] = profile["base_url"]
    os.environ[model_env] = profile["model_id"]
    os.environ[key_env] = api_key


def run_provider_probe(profile: dict[str, Any], timeout_sec: int) -> dict[str, Any]:
    from insightkit.insights.provider import probe_provider

    started = time.monotonic()
    try:
        result = with_timeout(
            "provider probe",
            timeout_sec,
            lambda: probe_provider(
                vendor=profile["vendor"],
                model_override=profile["model_id"],
                base_url_override=profile["base_url"],
            ),
        )
        return {
            "attempted": True,
            "ok": bool(result.get("ok")),
            "code": str(result.get("code") or ""),
            "message": str(result.get("message") or ""),
            "hint": str(result.get("hint") or ""),
            "duration_sec": round(time.monotonic() - started, 3),
        }
    except Exception as exc:
        return {
            "attempted": True,
            "ok": False,
            "code": "exception",
            "message": str(exc),
            "hint": "Provider probe failed before a valid response was received.",
            "duration_sec": round(time.monotonic() - started, 3),
        }


def run_final_build(profile: dict[str, Any], rows: list[dict[str, Any]], timeout_sec: int) -> dict[str, Any]:
    from insightkit.insights.service import InsightService

    started = time.monotonic()
    try:
        service = InsightService(default_vendor=profile["vendor"])
        package = with_timeout(
            "provider final build",
            timeout_sec,
            lambda: service.build_final(
                rows,
                provider_vendor=profile["vendor"],
                provider_model=profile["model_id"],
                strict_mode=True,
            ),
        )
        return {
            "attempted": True,
            "ok": True,
            "duration_sec": round(time.monotonic() - started, 3),
            "provider_vendor": str(service.last_call_meta.get("vendor") or ""),
            "provider_model": str(service.last_call_meta.get("model") or ""),
            "title": str(package.get("session_overview", {}).get("title") or ""),
            "topics_count": len(package.get("session_overview", {}).get("topics") or []),
            "highlights_count": len(package.get("highlight_insights") or []),
            "decisions_count": len(package.get("decision_ledger") or []),
            "actions_count": len(package.get("action_tracks") or []),
            "chapters_count": len(package.get("timeline_beats") or []),
        }
    except Exception as exc:
        return {
            "attempted": True,
            "ok": False,
            "duration_sec": round(time.monotonic() - started, 3),
            "message": str(exc),
        }


def run_local_fallback(rows: list[dict[str, Any]]) -> dict[str, Any]:
    from insightkit.insights.service import InsightService

    started = time.monotonic()
    try:
        service = InsightService(strict_mode=False)
        package = service.build_local_extractive(rows)
        return {
            "ok": True,
            "duration_sec": round(time.monotonic() - started, 3),
            "provider_vendor": str(service.last_call_meta.get("vendor") or ""),
            "provider_model": str(service.last_call_meta.get("model") or ""),
            "title": str(package.get("session_overview", {}).get("title") or ""),
            "topics_count": len(package.get("session_overview", {}).get("topics") or []),
            "highlights_count": len(package.get("highlight_insights") or []),
            "decisions_count": len(package.get("decision_ledger") or []),
            "actions_count": len(package.get("action_tracks") or []),
            "chapters_count": len(package.get("timeline_beats") or []),
        }
    except Exception as exc:
        return {
            "ok": False,
            "duration_sec": round(time.monotonic() - started, 3),
            "message": str(exc),
        }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--transcript-json", type=Path, default=None)
    parser.add_argument("--rows", type=int, default=6)
    parser.add_argument("--keychain-timeout-sec", type=float, default=5)
    parser.add_argument("--probe-timeout-sec", type=int, default=25)
    parser.add_argument("--final-timeout-sec", type=int, default=75)
    parser.add_argument("--skip-final-build", action="store_true")
    parser.add_argument("--output", type=Path, default=None)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    proof_path = args.output or (_today_dir() / "current-provider-validation-proof.json")
    proof_path.parent.mkdir(parents=True, exist_ok=True)

    config = load_config(args.config)
    profile = active_profile(config)
    transcript_path = args.transcript_json or default_transcript_path()
    rows = load_transcript_rows(transcript_path, max(1, args.rows))

    strict_mode = bool((config.get("strict") or {}).get("strictMode", True))
    api_key, keychain = keychain_read(profile["api_key_ref"], args.keychain_timeout_sec)

    proof: dict[str, Any] = {
        "generated_at": _iso_now(),
        "config_path": str(args.config),
        "transcript_sample": {
            "path": str(transcript_path),
            "rows_used": len(rows),
            "text_redacted": True,
        },
        "selected_provider": {
            "vendor": profile["vendor"],
            "base_url": profile["base_url"],
            "model_id": profile["model_id"],
            "api_key_ref": profile["api_key_ref"],
        },
        "strict_mode": strict_mode,
        "keychain": keychain,
        "provider_probe": {"attempted": False, "ok": False},
        "provider_final_build": {"attempted": False, "ok": False},
        "local_extractive_fallback": run_local_fallback(rows),
    }

    if api_key:
        configure_provider_env(profile, api_key, strict_mode)
        proof["provider_probe"] = run_provider_probe(profile, args.probe_timeout_sec)
        if not args.skip_final_build and proof["provider_probe"].get("ok"):
            proof["provider_final_build"] = run_final_build(profile, rows, args.final_timeout_sec)
    else:
        proof["provider_probe"] = {
            "attempted": False,
            "ok": False,
            "code": "key_unavailable",
            "message": "No API key was available from Keychain within the bounded lookup.",
        }

    if proof["provider_final_build"].get("ok"):
        proof["outcome"] = "verified_real_provider_final_build"
    elif proof["provider_probe"].get("ok"):
        proof["outcome"] = "verified_real_provider_probe_only"
    elif proof["local_extractive_fallback"].get("ok"):
        proof["outcome"] = "fallback_only_provider_unverified"
    else:
        proof["outcome"] = "provider_unverified_and_fallback_failed"

    proof_path.write_text(json.dumps(proof, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"wrote proof: {proof_path}")
    print(f"outcome: {proof['outcome']}")
    print(
        "provider:",
        f"{profile['vendor']} {profile['model_id']} probe_ok={proof['provider_probe'].get('ok')} "
        f"final_ok={proof['provider_final_build'].get('ok')}",
    )
    print(f"fallback_ok: {proof['local_extractive_fallback'].get('ok')}")
    return 0 if proof["outcome"] != "provider_unverified_and_fallback_failed" else 1


if __name__ == "__main__":
    sys.path.insert(0, str(ROOT_DIR))
    raise SystemExit(main())
