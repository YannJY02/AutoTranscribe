#!/usr/bin/env python3
"""Smoke test: call every RPC method via the actual Unix socket."""

import argparse
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

DEFAULT_SOCKET_PATH = Path(os.getenv("INSIGHTKIT_SOCKET", "/tmp/insightkit.sock"))
ROOT_DIR = Path(__file__).resolve().parent.parent
SIDECAR_SCRIPT = ROOT_DIR / "scripts" / "insight_sidecar.py"


def rpc_call(socket_path: Path, method: str, params: dict | None = None) -> dict:
    """Legacy short-lived connection: one request per socket."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(10)
        s.connect(str(socket_path))
        req = json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n"
        s.sendall(req.encode("utf-8"))
        data = s.recv(4 * 1024 * 1024)
        return json.loads(data.decode("utf-8"))


def _send_line(conn: socket.socket, obj: dict) -> None:
    line = json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n"
    conn.sendall(line.encode("utf-8"))


def test_persistent_connection(socket_path: Path) -> tuple[int, int]:
    """Persistent NDJSON connection: handshake then multiple requests."""
    print("\n--- Persistent Connection Mode ---")
    passed = 0
    failed = 0

    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.settimeout(10)
    try:
        conn.connect(str(socket_path))
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


def _probe_socket(socket_path: Path) -> bool:
    try:
        resp = rpc_call(socket_path, "sidecar.status", {})
    except Exception:
        return False
    return not resp.get("error")


def _start_sidecar(socket_path: Path, timeout_sec: float) -> subprocess.Popen[str]:
    env = os.environ.copy()
    env["INSIGHTKIT_SOCKET"] = str(socket_path)
    proc = subprocess.Popen(
        [sys.executable, str(SIDECAR_SCRIPT)],
        cwd=str(ROOT_DIR),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    deadline = time.time() + timeout_sec
    while time.time() < deadline:
        if proc.poll() is not None:
            output = proc.stdout.read() if proc.stdout else ""
            raise RuntimeError(f"sidecar exited during startup with code {proc.returncode}\n{output}")
        if socket_path.exists() and _probe_socket(socket_path):
            print(f"Started sidecar on {socket_path} (pid {proc.pid})")
            return proc
        time.sleep(0.1)
    _stop_owned_sidecar(proc, socket_path)
    raise TimeoutError(f"sidecar did not become ready within {timeout_sec:.1f}s")


def _stop_owned_sidecar(proc: subprocess.Popen[str], socket_path: Path) -> None:
    if proc.poll() is not None:
        return
    try:
        rpc_call(socket_path, "sidecar.shutdown", {})
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


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--socket-path",
        type=Path,
        default=DEFAULT_SOCKET_PATH,
        help=f"Unix socket path to verify. Default: {DEFAULT_SOCKET_PATH}",
    )
    parser.add_argument(
        "--no-start-sidecar",
        action="store_true",
        help="Fail if the socket is unavailable instead of starting a temporary sidecar.",
    )
    parser.add_argument(
        "--startup-timeout-sec",
        type=float,
        default=12,
        help="Maximum seconds to wait for an auto-started sidecar.",
    )
    parser.add_argument(
        "--leave-sidecar-running",
        action="store_true",
        help="Do not shut down a sidecar started by this smoke test.",
    )
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    socket_path: Path = args.socket_path
    owned_sidecar: subprocess.Popen[str] | None = None

    if not _probe_socket(socket_path):
        if args.no_start_sidecar:
            print(f"FAIL: no reachable sidecar socket at {socket_path}")
            return 1
        try:
            owned_sidecar = _start_sidecar(socket_path, args.startup_timeout_sec)
        except Exception as exc:
            print(f"FAIL: {exc}")
            return 1

    # --- Legacy mode ---
    print("--- Legacy Short-Connection Mode ---")
    methods = [
        ("sidecar.status", {}),
        ("sidecar.version", {}),
        ("sidecar.action_registry", {}),
        ("sidecar.compatibility_routes", {}),
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
            resp = rpc_call(socket_path, method, params)
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
    p, f = test_persistent_connection(socket_path)
    passed += p
    failed += f

    total = passed + failed
    print(f"\n{passed} passed, {failed} failed out of {total} checks")
    if owned_sidecar is not None and not args.leave_sidecar_running:
        _stop_owned_sidecar(owned_sidecar, socket_path)
        print("Stopped temporary sidecar")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
