import os
import unittest

from insightkit.insights.provider import describe_provider_error, probe_provider, providers_status


class TestAnalysisProviderProbe(unittest.TestCase):
    def test_probe_missing_key_returns_structured_error(self):
        os.environ.pop("OPENAI_API_KEY", None)
        result = probe_provider(vendor="openai", model_override="gpt-4o-mini")
        self.assertFalse(result["ok"])
        self.assertEqual(result["code"], "missing_key")
        self.assertIn("API Key", result["message"])

    def test_describe_maps_auth_and_model_errors(self):
        auth = describe_provider_error("http 401: Authentication Fails (governor)", vendor="deepseek")
        self.assertEqual(auth["code"], "auth_failed")

        model = describe_provider_error(
            "http 404: {\"error\":{\"code\":\"InvalidEndpointOrModel.NotFound\"}}",
            vendor="doubao",
        )
        self.assertEqual(model["code"], "model_not_found")
        self.assertIn("接入点", model["hint"])

    def test_status_with_probe_exposes_active_probe_fields(self):
        os.environ.pop("OPENAI_API_KEY", None)
        status = providers_status(probe_active=True)
        self.assertIn("active_probe_ok", status)
        self.assertIn("active_probe_error_code", status)
        self.assertIn("active_probe_message", status)


if __name__ == "__main__":
    unittest.main()
