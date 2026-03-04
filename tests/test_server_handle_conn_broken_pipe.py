import json
import tempfile
import unittest
from pathlib import Path

from insightkit.data.store import InsightStore
from insightkit.ipc.server import InsightRPCServer


class _BrokenPipeConn:
    def __init__(self, payload: bytes):
        self._payload = payload

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def recv(self, _n: int) -> bytes:
        return self._payload

    def sendall(self, _data: bytes) -> None:
        raise BrokenPipeError(32, "Broken pipe")


class TestServerHandleConnBrokenPipe(unittest.TestCase):
    def test_broken_pipe_during_send_is_suppressed(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = Path(tmp) / "insightkit.db"
            server = InsightRPCServer(socket_path=Path(tmp) / "sock", store=InsightStore(db))
            payload = json.dumps(
                {
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "sidecar.status",
                    "params": {},
                }
            ).encode("utf-8")
            conn = _BrokenPipeConn(payload)

            # Must not raise traceback-level exception.
            server._handle_conn(conn)  # noqa: SLF001
            server.shutdown()


if __name__ == "__main__":
    unittest.main()
