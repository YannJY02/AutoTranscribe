import unittest

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

    def test_status_contains_all_vendors(self):
        status = providers_status()
        vendors = status.get("vendors", {})
        for vendor in ["openai", "gemini", "deepseek", "qwen", "doubao"]:
            self.assertIn(vendor, vendors)


if __name__ == "__main__":
    unittest.main()
