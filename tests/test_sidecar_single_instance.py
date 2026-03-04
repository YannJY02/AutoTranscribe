import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from insightkit.data.store import InsightStore
from insightkit.ipc.server import InsightRPCServer


class TestSidecarSingleInstance(unittest.TestCase):
    def test_sidecar_version_exposes_capabilities(self):
        with tempfile.TemporaryDirectory() as tmp:
            db_path = Path(tmp) / "insightkit.db"
            server = InsightRPCServer(store=InsightStore(db_path=db_path))
            version = server._sidecar_version({})
            self.assertIn("version", version)
            self.assertIn("build", version)
            self.assertIn("capabilities", version)
            self.assertIn("sidecar.shutdown", version["capabilities"])
            status = server._sidecar_status({})
            self.assertIn("last_error_code", status)
            self.assertIn("last_latency_ms", status)
            server.shutdown()

    def test_sidecar_shutdown_returns_immediately(self):
        with tempfile.TemporaryDirectory() as tmp:
            db_path = Path(tmp) / "insightkit.db"
            server = InsightRPCServer(store=InsightStore(db_path=db_path))
            with mock.patch.object(server, "shutdown") as shutdown:
                result = server._sidecar_shutdown({})
                self.assertTrue(result.get("ok"))
                self.assertTrue(result.get("shutting_down"))
                for _ in range(20):
                    if shutdown.called:
                        break
                    time.sleep(0.02)
                self.assertTrue(shutdown.called)


if __name__ == "__main__":
    unittest.main()
