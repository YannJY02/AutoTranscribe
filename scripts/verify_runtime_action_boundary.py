#!/usr/bin/env python3
"""Verify Runtime Action Boundary contracts and write durable proof JSON."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import datetime
from pathlib import Path


def verify_runtime_action_boundary() -> dict[str, object]:
    result = subprocess.run(
        [sys.executable, "-m", "pytest", "tests/test_runtime_action_boundary.py", "-q"],
        check=False,
        text=True,
        capture_output=True,
    )
    return {
        "status": "passed" if result.returncode == 0 else "failed",
        "command": "python3 -m pytest tests/test_runtime_action_boundary.py -q",
        "returncode": result.returncode,
        "covered_product_actions": [
            "record.save",
            "transcript.recover",
            "media.transcribe_final",
            "runtime.transcript.replace",
            "smart_minutes.generate",
        ],
        "stdout": result.stdout[-4000:],
        "stderr": result.stderr[-4000:],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("logs") / "diagnostics" / datetime.now().strftime("%Y-%m-%d") / f"runtime-action-boundary-{datetime.now().strftime('%Y%m%d-%H%M%S')}",
    )
    args = parser.parse_args()

    proof = verify_runtime_action_boundary()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    proof_path = args.output_dir / "proof.json"
    proof_path.write_text(json.dumps(proof, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"wrote proof: {proof_path}")
    print(f"status: {proof['status']}")
    return 0 if proof["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
