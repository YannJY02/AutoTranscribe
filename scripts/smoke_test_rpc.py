#!/usr/bin/env python3
"""Smoke test: call every RPC method via the actual Unix socket."""

import json
import socket
import sys
from pathlib import Path

SOCKET_PATH = Path("/tmp/insightkit.sock")

def rpc_call(method: str, params: dict | None = None) -> dict:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.connect(str(SOCKET_PATH))
        req = json.dumps({"id": 1, "method": method, "params": params or {}})
        s.sendall(req.encode("utf-8"))
        data = s.recv(4 * 1024 * 1024)
        return json.loads(data.decode("utf-8"))

def main() -> int:
    if not SOCKET_PATH.exists():
        print(f"FAIL: socket not found at {SOCKET_PATH}")
        print("Start sidecar first: python3 scripts/insight_sidecar.py")
        return 1

    methods = [
        ("sidecar.status", {}),
        ("sidecar.version", {}),
        ("sidecar.ensure_ready", {"timeout_sec": 3}),
        ("asr.runtime.status", {}),
        ("analysis.providers.status", {"probe_active": False}),
        ("diagnostics.quick_check", {"probe_timeout_sec": 3}),
        ("module.capabilities", {}),
        ("transcription.status", {}),
    ]

    passed = 0
    failed = 0
    for method, params in methods:
        try:
            resp = rpc_call(method, params)
            if "error" in resp and resp["error"]:
                print(f"  FAIL  {method}: {resp['error']}")
                failed += 1
            else:
                print(f"  PASS  {method}")
                passed += 1
        except Exception as exc:
            print(f"  FAIL  {method}: {exc}")
            failed += 1

    print(f"\n{passed} passed, {failed} failed out of {len(methods)} methods")
    return 1 if failed else 0

if __name__ == "__main__":
    raise SystemExit(main())
