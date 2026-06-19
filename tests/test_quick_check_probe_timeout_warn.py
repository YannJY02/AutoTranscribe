import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from insightkit.data.store import InsightStore
from insightkit.ipc.server import InsightRPCServer


class TestQuickCheckProbeTimeoutWarn(unittest.TestCase):
    def test_quick_check_marks_probe_timeout_as_warn(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = Path(tmp) / "insightkit.db"
            server = InsightRPCServer(socket_path=Path(tmp) / "sock", store=InsightStore(db))

            providers_payload = {
                "selected_vendor": "deepseek",
                "active_ready": True,
                "vendors": {
                    "deepseek": {
                        "vendor": "deepseek",
                        "base_url": "https://api.deepseek.com",
                        "model_id": "deepseek-v4-flash",
                        "configured": True,
                        "has_api_key": True,
                        "model_ready": True,
                    },
                },
            }

            def _slow_probe(*args, **kwargs):
                _ = args, kwargs
                time.sleep(1.2)
                return {
                    "ok": True,
                    "code": "ok",
                    "message": "连接成功。",
                    "hint": "",
                }

            with (
                mock.patch.object(server, "_sidecar_status", return_value={"pid": 1, "ready": True}),
                mock.patch("insightkit.ipc.provider_probe.runtime_status", return_value={"ready": True, "engine": "whisper", "model": {"name": "large-v3"}}),
                mock.patch("insightkit.ipc.provider_probe.providers_status", return_value=providers_payload),
                mock.patch.object(server._provider_probe, "_probe_cached", side_effect=_slow_probe),
            ):
                report = server._diagnostics_quick_check({"probe_timeout_sec": 1})
                probe = next((item for item in report.get("checks", []) if item.get("id") == "analysis_provider_probe"), {})
                self.assertEqual(probe.get("status"), "warn")
                self.assertTrue(probe.get("timed_out"))
                self.assertIn(report.get("overall"), {"warn", "fail"})

            server.shutdown()


if __name__ == "__main__":
    unittest.main()
