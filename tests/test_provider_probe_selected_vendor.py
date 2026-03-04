import tempfile
import unittest
from pathlib import Path
from unittest import mock

from insightkit.data.store import InsightStore
from insightkit.ipc.server import InsightRPCServer


class TestProviderProbeSelectedVendor(unittest.TestCase):
    def test_quick_check_probes_current_selected_vendor(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = Path(tmp) / "insightkit.db"
            server = InsightRPCServer(socket_path=Path(tmp) / "sock", store=InsightStore(db))

            providers_payload = {
                "selected_vendor": "doubao",
                "active_ready": True,
                "vendors": {
                    "doubao": {
                        "vendor": "doubao",
                        "base_url": "https://ark.cn-beijing.volces.com/api/v3",
                        "model_id": "doubao-seed-1-6-250615",
                        "configured": True,
                        "has_api_key": True,
                        "model_ready": True,
                    },
                },
            }

            with (
                mock.patch("insightkit.ipc.server.providers_status", return_value=providers_payload),
                mock.patch.object(
                    server,
                    "_probe_provider_cached",
                    return_value={
                        "ok": True,
                        "code": "ok",
                        "message": "连接成功。",
                        "hint": "",
                    },
                ) as probe_mock,
            ):
                report = server._diagnostics_quick_check({})
                check_ids = {item.get("id") for item in report.get("checks", [])}
                self.assertIn("analysis_provider_probe", check_ids)
                probe_mock.assert_called_once()
                self.assertEqual(probe_mock.call_args.kwargs["vendor"], "doubao")

            server.shutdown()


if __name__ == "__main__":
    unittest.main()
