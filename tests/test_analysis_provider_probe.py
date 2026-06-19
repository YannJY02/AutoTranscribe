import os
import unittest
from unittest import mock

from insightkit.insights.provider import (
    GeminiProvider,
    _probe_response_ok,
    _redact_secret,
    describe_provider_error,
    probe_provider,
    providers_status,
)
from insightkit.insights.service import InsightService


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

    def test_service_uses_provider_default_model_when_no_model_override(self):
        service = InsightService(default_vendor="deepseek")

        with mock.patch("insightkit.insights.service.provider_probe") as probe:
            probe.return_value = {"ok": False, "code": "missing_key"}
            service.probe_provider()

        self.assertIsNone(probe.call_args.kwargs["model_override"])

    def test_probe_response_requires_json_ok_true(self):
        self.assertTrue(_probe_response_ok('{"ok": true}'))
        self.assertTrue(_probe_response_ok('```json\n{"ok": true}\n```'))
        self.assertFalse(_probe_response_ok("hello"))
        self.assertFalse(_probe_response_ok('{"ok": false}'))
        self.assertFalse(_probe_response_ok('{"status": "ok"}'))

    def test_redacts_common_provider_secret_shapes(self):
        text = (
            "Authorization: Bearer sk-example1234567890 "
            "DEEPSEEK_API_KEY=sk-another1234567890 "
            "hf_abcdefghijklmnopqrstuvwxyz "
            "123e4567-e89b-12d3-a456-426614174000 "
            "https://example.test/path?key=AIzaSyExampleSecret"
        )

        redacted = _redact_secret(text)

        self.assertNotIn("sk-example", redacted)
        self.assertNotIn("sk-another", redacted)
        self.assertNotIn("hf_abcdefghijklmnopqrstuvwxyz", redacted)
        self.assertNotIn("123e4567", redacted)
        self.assertNotIn("AIzaSyExampleSecret", redacted)

    def test_gemini_provider_does_not_put_key_in_url(self):
        captured = {}

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return b'{"candidates":[{"content":{"parts":[{"text":"{}"}]}}]}'

        def fake_urlopen(req, timeout):
            captured["url"] = req.full_url
            captured["headers"] = dict(req.header_items())
            captured["timeout"] = timeout
            return FakeResponse()

        provider = GeminiProvider(base_url="https://generativelanguage.googleapis.com", api_key="fake-secret")

        with mock.patch("urllib.request.urlopen", side_effect=fake_urlopen):
            provider.complete("system", "user", "gemini-test")

        self.assertNotIn("fake-secret", captured["url"])
        self.assertEqual(captured["headers"].get("X-goog-api-key"), "fake-secret")


if __name__ == "__main__":
    unittest.main()
