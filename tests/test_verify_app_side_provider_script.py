import unittest

from scripts.verify_app_side_provider import selected_vendor_payload, summarize_final_result


class TestVerifyAppSideProviderScript(unittest.TestCase):
    def test_selected_vendor_payload_extracts_active_vendor(self):
        status = {
            "selected_vendor": "deepseek",
            "vendors": {
                "deepseek": {
                    "base_url": "https://api.deepseek.com",
                    "model_id": "deepseek-v4-flash",
                    "configured": True,
                    "has_api_key": True,
                    "model_ready": True,
                }
            },
        }

        payload = selected_vendor_payload(status)

        self.assertEqual(payload["vendor"], "deepseek")
        self.assertTrue(payload["has_api_key"])

    def test_summarize_final_result_keeps_provider_and_counts(self):
        result = {
            "provider_vendor": "deepseek",
            "provider_model": "deepseek-v4-flash",
            "strict_mode": True,
            "needs_review_count": 2,
            "insight_package": {
                "session_overview": {"title": "Title", "topics": ["a", "b"]},
                "highlight_insights": [{"quote": "q"}],
                "speaker_perspectives": [{"speaker": "A"}],
                "decision_ledger": [{"decision": "d"}],
                "action_tracks": [{"task": "t"}],
                "timeline_beats": [{"title": "c"}],
            },
        }

        summary = summarize_final_result(result)

        self.assertTrue(summary["ok"])
        self.assertEqual(summary["provider_vendor"], "deepseek")
        self.assertEqual(summary["provider_model"], "deepseek-v4-flash")
        self.assertEqual(summary["topics_count"], 2)
        self.assertEqual(summary["chapters_count"], 1)


if __name__ == "__main__":
    unittest.main()
