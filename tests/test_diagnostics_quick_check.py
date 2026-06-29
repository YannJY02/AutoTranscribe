import tempfile
import unittest
from pathlib import Path

from insightkit.data.store import InsightStore
from insightkit.ipc.server import InsightRPCServer


class TestDiagnosticsQuickCheck(unittest.TestCase):
    def test_quick_check_shape(self):
        with tempfile.TemporaryDirectory() as tmp:
            db_path = Path(tmp) / "insightkit.db"
            server = InsightRPCServer(store=InsightStore(db_path=db_path))
            result = server._diagnostics_quick_check({})

            self.assertIn(result.get("overall"), {"pass", "warn", "fail"})
            checks = result.get("checks", [])
            ids = {item.get("id") for item in checks}
            self.assertIn("sidecar", ids)
            self.assertIn("asr_runtime", ids)
            self.assertIn("analysis_provider", ids)
            self.assertIn("analysis_provider_probe", ids)
            asr_check = next(item for item in checks if item.get("id") == "asr_runtime")
            self.assertIn("runtime_profile", asr_check)
            self.assertIn("final_media_asr", asr_check["runtime_profile"])
            server.shutdown()


if __name__ == "__main__":
    unittest.main()
