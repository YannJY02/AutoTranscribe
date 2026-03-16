#!/usr/bin/env python3
"""Smoke test: call every RPC method via the actual Unix socket."""

import json
import socket
from pathlib import Path

SOCKET_PATH = Path("/tmp/insightkit.sock")


def rpc_call(method: str, params: dict | None = None) -> dict:
    """Legacy short-lived connection: one request per socket."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.connect(str(SOCKET_PATH))
        req = json.dumps({"id": 1, "method": method, "params": params or {}})
        s.sendall(req.encode("utf-8"))
        data = s.recv(4 * 1024 * 1024)
        return json.loads(data.decode("utf-8"))


def _send_line(conn: socket.socket, obj: dict) -> None:
    line = json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n"
    conn.sendall(line.encode("utf-8"))


def test_persistent_connection() -> tuple[int, int]:
    """Persistent NDJSON connection: handshake then multiple requests."""
    print("\n--- Persistent Connection Mode ---")
    passed = 0
    failed = 0

    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.settimeout(10)
    try:
        conn.connect(str(SOCKET_PATH))
        reader = conn.makefile("rb")

        # Handshake
        _send_line(conn, {"insightkit": "1.0"})
        ack = json.loads(reader.readline().decode("utf-8"))
        if ack.get("insightkit") == "1.0" and ack.get("push"):
            print("  PASS  handshake")
            passed += 1
        else:
            print(f"  FAIL  handshake: {ack}")
            failed += 1
            return passed, failed

        # Multiple requests on the same connection
        methods = [
            ("sidecar.status", {}),
            ("sidecar.version", {}),
            ("transcription.status", {}),
        ]
        for i, (method, params) in enumerate(methods, start=1):
            try:
                _send_line(conn, {"id": i, "method": method, "params": params})
                resp = json.loads(reader.readline().decode("utf-8"))
                if resp.get("id") != i:
                    print(f"  FAIL  persistent {method}: id mismatch {resp.get('id')} != {i}")
                    failed += 1
                elif "error" in resp and resp["error"]:
                    print(f"  FAIL  persistent {method}: {resp['error']}")
                    failed += 1
                else:
                    print(f"  PASS  persistent {method}")
                    passed += 1
            except Exception as exc:
                print(f"  FAIL  persistent {method}: {exc}")
                failed += 1
    except Exception as exc:
        print(f"  FAIL  persistent connection: {exc}")
        failed += 1
    finally:
        conn.close()

    return passed, failed


def main() -> int:
    if not SOCKET_PATH.exists():
        print(f"FAIL: socket not found at {SOCKET_PATH}")
        print("Start sidecar first: python3 scripts/insight_sidecar.py")
        return 1

    # --- Legacy mode ---
    print("--- Legacy Short-Connection Mode ---")
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

    # --- Persistent mode ---
    p, f = test_persistent_connection()
    passed += p
    failed += f

    total = passed + failed
    print(f"\n{passed} passed, {failed} failed out of {total} checks")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
