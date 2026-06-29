#!/usr/bin/env python3
"""Verify the Sidecar Action Registry and write a durable proof JSON."""

from __future__ import annotations

import argparse
import json
from datetime import datetime
from pathlib import Path
from tempfile import TemporaryDirectory

from insightkit.data.store import InsightStore
from insightkit.ipc.server import InsightRPCServer


REQUIRED_ACTIONS = {
    "record.save",
    "transcript.recover",
    "media.transcribe_final",
    "runtime.transcript.replace",
    "smart_minutes.generate",
}
VALID_STATES = {"available", "unavailable", "degraded", "unsupported", "busy"}


def verify_registry() -> dict[str, object]:
    with TemporaryDirectory() as tmp:
        server = InsightRPCServer(store=InsightStore(db_path=Path(tmp) / "insightkit.db"))
        try:
            registry = server._sidecar_action_registry({})
            version = server._sidecar_version({})
        finally:
            server.shutdown()

    actions = registry.get("actions") or []
    names = {str(action.get("name") or "") for action in actions if isinstance(action, dict)}
    states = {str(action.get("state") or "") for action in actions if isinstance(action, dict)}
    missing = sorted(REQUIRED_ACTIONS - names)
    invalid_states = sorted(state for state in states if state not in VALID_STATES)
    version_actions = {
        str(action.get("name") or "")
        for action in ((version.get("action_registry") or {}).get("actions") or [])
        if isinstance(action, dict)
    }
    version_missing = sorted(REQUIRED_ACTIONS - version_actions)
    findings = []
    if missing:
        findings.append({"code": "missing_registry_actions", "actions": missing})
    if invalid_states:
        findings.append({"code": "invalid_registry_states", "states": invalid_states})
    if version_missing:
        findings.append({"code": "version_registry_missing_actions", "actions": version_missing})

    return {
        "status": "passed" if not findings else "failed",
        "registry_version": registry.get("registry_version", ""),
        "action_count": len(actions),
        "required_actions": sorted(REQUIRED_ACTIONS),
        "states": sorted(states),
        "capability_method_present": "sidecar.action_registry" in (version.get("capabilities") or []),
        "findings": findings,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("logs") / "diagnostics" / datetime.now().strftime("%Y-%m-%d") / f"sidecar-action-registry-{datetime.now().strftime('%Y%m%d-%H%M%S')}",
    )
    args = parser.parse_args()

    proof = verify_registry()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    proof_path = args.output_dir / "proof.json"
    proof_path.write_text(json.dumps(proof, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"wrote proof: {proof_path}")
    print(f"status: {proof['status']}")
    return 0 if proof["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
