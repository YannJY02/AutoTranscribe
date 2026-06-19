"""Tests for persistent NDJSON connection mode."""
import json
import socket
import tempfile
import threading
import time
import unittest
from pathlib import Path

from insightkit.data.store import InsightStore
from insightkit.ipc.server import InsightRPCServer


class TestPersistentConnection(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir="/private/tmp")
        tmp_path = Path(self.tmp.name)
        self.sock_path = tmp_path / "insightkit.sock"
        self.server = InsightRPCServer(
            socket_path=self.sock_path,
            store=InsightStore(tmp_path / "insightkit.db"),
        )
        self.server_thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.server_thread.start()
        self._wait_until_ready()

    def _wait_until_ready(self) -> None:
        last_error: Exception | None = None
        for _ in range(50):
            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(0.2)
            try:
                conn.connect(str(self.sock_path))
                conn.close()
                return
            except (FileNotFoundError, ConnectionRefusedError, OSError) as exc:
                last_error = exc
                conn.close()
            time.sleep(0.05)
        self.fail(f"server did not become ready at {self.sock_path}: {last_error}")

    def tearDown(self):
        self.server.shutdown()
        self.server_thread.join(timeout=2)
        self.tmp.cleanup()

    def _connect(self) -> socket.socket:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(5)
        conn.connect(str(self.sock_path))
        return conn

    @staticmethod
    def _send_line(conn: socket.socket, obj: dict) -> None:
        line = json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n"
        conn.sendall(line.encode("utf-8"))

    def test_handshake(self):
        """Client sends handshake, server replies with confirmation."""
        conn = self._connect()
        try:
            reader = conn.makefile("rb")
            self._send_line(conn, {"insightkit": "1.0"})
            reply = json.loads(reader.readline().decode("utf-8"))
            self.assertEqual(reply["insightkit"], "1.0")
            self.assertTrue(reply.get("push"))
        finally:
            conn.close()

    def test_multiple_requests_one_connection(self):
        """Multiple RPC calls over a single persistent connection."""
        conn = self._connect()
        try:
            reader = conn.makefile("rb")
            self._send_line(conn, {"insightkit": "1.0"})
            json.loads(reader.readline())  # handshake reply

            for i in range(3):
                self._send_line(conn, {"id": i + 1, "method": "sidecar.status", "params": {}})
                resp = json.loads(reader.readline().decode("utf-8"))
                self.assertEqual(resp["id"], i + 1)
                self.assertIn("result", resp)
                self.assertTrue(resp["result"]["running"])
        finally:
            conn.close()

    def test_legacy_mode_still_works(self):
        """Without handshake, old-style single-shot RPC still works."""
        conn = self._connect()
        try:
            req = json.dumps({"id": 1, "method": "sidecar.status", "params": {}}).encode("utf-8")
            conn.sendall(req)
            conn.shutdown(socket.SHUT_WR)
            data = b""
            while True:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                data += chunk
            resp = json.loads(data.decode("utf-8"))
            self.assertEqual(resp["id"], 1)
            self.assertTrue(resp["result"]["running"])
        finally:
            conn.close()

    def test_push_event_received(self):
        """Server push events reach persistent clients."""
        conn = self._connect()
        try:
            reader = conn.makefile("rb")
            self._send_line(conn, {"insightkit": "1.0"})
            json.loads(reader.readline())  # handshake reply

            # Trigger a push from the broker
            self.server._push_broker.emit("test.ping", {"ts": 123})

            raw = reader.readline()
            msg = json.loads(raw.decode("utf-8"))
            self.assertEqual(msg["event"], "test.ping")
            self.assertEqual(msg["data"]["ts"], 123)
        finally:
            conn.close()

    def test_error_response_persistent(self):
        """Unknown method returns error in persistent mode."""
        conn = self._connect()
        try:
            reader = conn.makefile("rb")
            self._send_line(conn, {"insightkit": "1.0"})
            json.loads(reader.readline())  # handshake reply

            self._send_line(conn, {"id": 99, "method": "no.such.method", "params": {}})
            resp = json.loads(reader.readline().decode("utf-8"))
            self.assertEqual(resp["id"], 99)
            self.assertIn("error", resp)
        finally:
            conn.close()


if __name__ == "__main__":
    unittest.main()
