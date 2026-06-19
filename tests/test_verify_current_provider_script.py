import json
import tempfile
import unittest
from pathlib import Path

from scripts.verify_current_provider import active_profile, load_transcript_rows


class TestVerifyCurrentProviderScript(unittest.TestCase):
    def test_active_profile_uses_selected_vendor(self):
        config = {
            "analysis": {
                "selectedVendor": "deepseek",
                "providers": [
                    {
                        "vendor": "openai",
                        "baseURL": "https://api.openai.com/v1",
                        "modelID": "gpt-4.1-mini",
                        "apiKeyRef": "vendor.openai.api_key",
                    },
                    {
                        "vendor": "deepseek",
                        "baseURL": "https://api.deepseek.com",
                        "modelID": "deepseek-v4-flash",
                        "apiKeyRef": "vendor.deepseek.api_key",
                    },
                ],
            }
        }

        profile = active_profile(config)

        self.assertEqual(profile["vendor"], "deepseek")
        self.assertEqual(profile["model_id"], "deepseek-v4-flash")
        self.assertEqual(profile["api_key_ref"], "vendor.deepseek.api_key")

    def test_load_transcript_rows_normalizes_real_record_shape(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "transcript.json"
            path.write_text(
                json.dumps(
                    {
                        "segments": [
                            {"speaker_label": "spk0", "start_ms": 1000, "end_ms": 1800, "text": " hello "},
                            {"speaker": "spk1", "start_ms": 2000, "end_ms": 2600, "text": "world"},
                            {"speaker": "spk2", "text": ""},
                        ]
                    }
                ),
                encoding="utf-8",
            )

            rows = load_transcript_rows(path, limit=10)

        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["speaker"], "spk0")
        self.assertEqual(rows[0]["text"], "hello")
        self.assertEqual(rows[1]["speaker"], "spk1")


if __name__ == "__main__":
    unittest.main()
