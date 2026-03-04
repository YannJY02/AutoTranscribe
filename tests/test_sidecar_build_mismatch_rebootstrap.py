import os
import tempfile
import unittest
from pathlib import Path

from insightkit.data.store import InsightStore
from insightkit.ipc.server import InsightRPCServer


class TestSidecarBuildMismatchRebootstrap(unittest.TestCase):
    def test_sidecar_version_exposes_build_from_environment(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = Path(tmp) / "insightkit.db"
            sock = Path(tmp) / "sock"
            previous = os.environ.get("INSIGHTKIT_BUILD")
            os.environ["INSIGHTKIT_BUILD"] = "20260304099999"
            try:
                server = InsightRPCServer(socket_path=sock, store=InsightStore(db))
                version = server._sidecar_version({})
                self.assertEqual(version.get("build"), "20260304099999")
                server.shutdown()
            finally:
                if previous is None:
                    os.environ.pop("INSIGHTKIT_BUILD", None)
                else:
                    os.environ["INSIGHTKIT_BUILD"] = previous


if __name__ == "__main__":
    unittest.main()
