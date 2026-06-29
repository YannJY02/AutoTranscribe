#!/usr/bin/env python3
"""Verify optional integration wrapper stays thin over product actions."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from tempfile import TemporaryDirectory

from insightkit.integration.attentionos_bridge import export_module


def verify_optional_integration_layer() -> dict[str, object]:
    result = subprocess.run(
        [sys.executable, "-m", "pytest", "tests/test_attentionos_bridge.py", "-q"],
        check=False,
        text=True,
        capture_output=True,
    )
    findings: list[dict[str, object]] = []
    with TemporaryDirectory() as tmp:
        module_dir = export_module(Path(tmp) / "module")
        index = (module_dir / "index.py").read_text(encoding="utf-8")
        readme = (module_dir / "README.md").read_text(encoding="utf-8")

    if result.returncode != 0:
        findings.append({"code": "wrapper_tests_failed", "returncode": result.returncode})
    if 'payload.get("action", "smart_minutes.generate")' not in index:
        findings.append({"code": "default_action_not_product_action"})
    if 'rpc_call("insight.build_final"' in index:
        findings.append({"code": "legacy_final_insight_rpc_call_remaining"})
    if '"insight.build_final": "smart_minutes.generate"' not in index:
        findings.append({"code": "legacy_final_insight_alias_missing"})
    if "Compatibility Bridge Aliases" not in readme:
        findings.append({"code": "compatibility_alias_docs_missing"})

    return {
        "status": "passed" if not findings else "failed",
        "command": "python3 -m pytest tests/test_attentionos_bridge.py -q",
        "returncode": result.returncode,
        "default_bridge_action": "smart_minutes.generate",
        "legacy_aliases": {
            "records.save": "record.save",
            "asr.transcribe_media": "media.transcribe_final",
            "transcript.replace": "runtime.transcript.replace",
            "insight.build_final": "smart_minutes.generate",
        },
        "findings": findings,
        "stdout": result.stdout[-4000:],
        "stderr": result.stderr[-4000:],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("logs") / "diagnostics" / datetime.now().strftime("%Y-%m-%d") / f"optional-integration-layer-{datetime.now().strftime('%Y%m%d-%H%M%S')}",
    )
    args = parser.parse_args()

    proof = verify_optional_integration_layer()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    proof_path = args.output_dir / "proof.json"
    proof_path.write_text(json.dumps(proof, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"wrote proof: {proof_path}")
    print(f"status: {proof['status']}")
    return 0 if proof["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
