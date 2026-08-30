import unittest
from unittest import mock

from insightkit.insights.service import InsightService
from insightkit.ipc.provider_probe import ProviderProbe


class TestProviderProbe(unittest.TestCase):
    def setUp(self):
        self.service = mock.MagicMock(spec=InsightService)
        self.probe = ProviderProbe(insight_service=self.service)

    @mock.patch("insightkit.ipc.provider_probe.providers_status", return_value={
        "selected_vendor": "openai",
        "active_ready": True,
        "vendors": {"openai": {"configured": True, "model_id": "gpt-4", "base_url": ""}},
    })
    def test_providers_status_no_probe(self, _mock_ps):
        result = self.probe.analysis_providers_status({"probe_active": False})
        self.assertIsNone(result["active_probe_ok"])

    @mock.patch("insightkit.ipc.provider_probe.providers_status", return_value={
        "selected_vendor": "openai",
        "active_ready": True,
        "vendors": {"openai": {"configured": True, "model_id": "gpt-4", "base_url": ""}},
    })
    def test_providers_status_with_probe_ok(self, _mock_ps):
        self.service.probe_provider.return_value = {"ok": True, "code": "", "message": ""}
        result = self.probe.analysis_providers_status({"probe_active": True, "probe_timeout_sec": 2})
        self.assertTrue(result["active_probe_ok"])

    def test_provider_probe_calls_service(self):
        self.service.probe_provider.return_value = {"ok": True, "code": "", "message": ""}
        result = self.probe.analysis_provider_probe({
            "provider_vendor": "openai",
            "provider_model": "gpt-4",
            "force_refresh": True,
            "probe_timeout_sec": 2,
        })
        self.assertTrue(result["ok"])

    @mock.patch("insightkit.ipc.provider_probe.providers_status", return_value={
        "selected_vendor": "openai",
        "active_ready": False,
        "vendors": {"openai": {"configured": True, "model_id": "gpt-4", "base_url": ""}},
    })
    @mock.patch("insightkit.ipc.provider_probe.runtime_status", return_value={"ready": True, "engine": "funasr", "model": {"name": "base"}})
    def test_diagnostics_quick_check_shape(self, _mock_rt, _mock_ps):
        self.service.probe_provider.return_value = {"ok": True, "code": "", "message": ""}
        result = self.probe.diagnostics_quick_check(
            {"probe_timeout_sec": 2},
            sidecar_status_fn=lambda: {"ready": True, "pid": 1},
        )
        self.assertIn("overall", result)
        self.assertIn("checks", result)
        self.assertTrue(len(result["checks"]) >= 3)

    @mock.patch("insightkit.ipc.provider_probe.providers_status")
    @mock.patch("insightkit.ipc.provider_probe.runtime_status", return_value={"ready": True, "engine": "funasr", "model": {"name": "base"}})
    def test_local_diagnostics_skip_cloud_provider(self, _mock_rt, mock_providers_status):
        with mock.patch.dict("os.environ", {"INSIGHTKIT_ANALYSIS_MODE": "local"}):
            result = self.probe.diagnostics_quick_check(
                {},
                sidecar_status_fn=lambda: {"ready": True, "pid": 1},
            )

        analysis = next(item for item in result["checks"] if item["id"] == "analysis_provider")
        self.assertEqual(analysis["status"], "pass")
        self.assertNotIn("analysis_provider_probe", {item["id"] for item in result["checks"]})
        mock_providers_status.assert_not_called()
        self.service.probe_provider.assert_not_called()


if __name__ == "__main__":
    unittest.main()
