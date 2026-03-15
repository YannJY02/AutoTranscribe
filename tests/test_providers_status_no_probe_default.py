import tempfile
import unittest
from pathlib import Path
from unittest import mock

from insightkit.data.store import InsightStore
from insightkit.ipc.server import InsightRPCServer


class TestProvidersStatusNoProbeDefault(unittest.TestCase):
    def test_analysis_providers_status_without_probe_active_does_not_probe(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = Path(tmp) / "insightkit.db"
            server = InsightRPCServer(socket_path=Path(tmp) / "sock", store=InsightStore(db))

            providers_payload = {
                "selected_vendor": "deepseek",
                "active_ready": True,
                "vendors": {
                    "deepseek": {
                        "vendor": "deepseek",
                        "base_url": "https://api.deepseek.com/v1",
                        "model_id": "deepseek-chat",
                        "configured": True,
                        "has_api_key": True,
                        "model_ready": True,
                    },
                },
            }

            with (
                mock.patch("insightkit.ipc.provider_probe.providers_status", return_value=providers_payload),
                mock.patch.object(server._provider_probe, "_probe_cached") as probe_mock,
            ):
                result = server._analysis_providers_status({})
                self.assertIn("active_probe_ok", result)
                self.assertIsNone(result["active_probe_ok"])
                self.assertEqual(result.get("active_probe_error_code", ""), "")
                self.assertEqual(result.get("active_probe_message", ""), "")
                probe_mock.assert_not_called()

            server.shutdown()


if __name__ == "__main__":
    unittest.main()
