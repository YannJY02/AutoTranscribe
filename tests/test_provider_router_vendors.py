import unittest
from unittest import mock

from insightkit.insights.provider import available_vendors, providers_status, resolve_profile


class TestProviderRouterVendors(unittest.TestCase):
    def test_supports_expected_vendors(self):
        self.assertEqual(
            available_vendors(),
            ["openai", "gemini", "deepseek", "qwen", "doubao"],
        )

    def test_can_resolve_doubao_profile(self):
        profile = resolve_profile(vendor="doubao")
        self.assertEqual(profile.vendor, "doubao")
        self.assertTrue(profile.base_url.startswith("https://"))

    def test_deepseek_uses_current_v4_defaults(self):
        with mock.patch.dict("os.environ", {}, clear=True):
            profile = resolve_profile(vendor="deepseek")

        self.assertEqual(profile.base_url, "https://api.deepseek.com")
        self.assertEqual(profile.model_id, "deepseek-v4-flash")

    def test_status_defaults_to_deepseek_without_environment_override(self):
        with mock.patch.dict("os.environ", {}, clear=True):
            status = providers_status()

        self.assertEqual(status["selected_vendor"], "deepseek")
        self.assertEqual(status["vendors"]["deepseek"]["model_id"], "deepseek-v4-flash")

    def test_status_contains_all_vendors(self):
        status = providers_status()
        vendors = status.get("vendors", {})
        for vendor in ["openai", "gemini", "deepseek", "qwen", "doubao"]:
            self.assertIn(vendor, vendors)


if __name__ == "__main__":
    unittest.main()
