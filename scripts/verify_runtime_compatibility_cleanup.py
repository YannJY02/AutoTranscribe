#!/usr/bin/env python3
"""Verify runtime compatibility shims and write durable proof JSON."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from tempfile import TemporaryDirectory

from insightkit.data.store import InsightStore
from insightkit.ipc.server import InsightRPCServer


INVENTORY_PATH = Path(".scratch/sidecar-action-registry/compatibility-inventory.md")


def verify_runtime_compatibility_cleanup() -> dict[str, object]:
    result = subprocess.run(
        [sys.executable, "-m", "pytest", "tests/test_runtime_compatibility_cleanup.py", "-q"],
        check=False,
        text=True,
        capture_output=True,
    )
    with TemporaryDirectory() as tmp:
        server = InsightRPCServer(store=InsightStore(db_path=Path(tmp) / "insightkit.db"))
        try:
            compatibility_routes = server._sidecar_compatibility_routes({})
        finally:
            server.shutdown()

    findings: list[dict[str, object]] = []
    if result.returncode != 0:
        findings.append({"code": "focused_tests_failed", "returncode": result.returncode})
    if not INVENTORY_PATH.exists():
        findings.append({"code": "missing_inventory", "path": str(INVENTORY_PATH)})
    routes = compatibility_routes.get("routes") or []
    if not routes:
        findings.append({"code": "missing_compatibility_routes"})

    return {
        "status": "passed" if not findings else "failed",
        "command": "python3 -m pytest tests/test_runtime_compatibility_cleanup.py -q",
        "returncode": result.returncode,
        "inventory_path": str(INVENTORY_PATH),
        "compatibility_routes": routes,
        "findings": findings,
        "stdout": result.stdout[-4000:],
        "stderr": result.stderr[-4000:],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("logs") / "diagnostics" / datetime.now().strftime("%Y-%m-%d") / f"runtime-compatibility-cleanup-{datetime.now().strftime('%Y%m%d-%H%M%S')}",
    )
    args = parser.parse_args()

    proof = verify_runtime_compatibility_cleanup()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    proof_path = args.output_dir / "proof.json"
    proof_path.write_text(json.dumps(proof, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"wrote proof: {proof_path}")
    print(f"status: {proof['status']}")
    return 0 if proof["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
