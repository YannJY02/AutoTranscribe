import json
import unittest

from insightkit.insights.provider import RuleBasedProvider
from insightkit.insights.service import InsightService


class TestStrictNoFallback(unittest.TestCase):
    def test_strict_mode_rejects_non_json_provider_payload(self):
        service = InsightService(provider=RuleBasedProvider(), strict_mode=True)
        with self.assertRaises(Exception):
            service.build_live([{"start_ms": 0, "end_ms": 1, "speaker": "", "text": "hello"}])

    def test_strict_mode_rejects_missing_raw_evidence_span(self):
        package = InsightService._fallback_payload(live_mode=False)
        del package["highlight_insights"][0]["evidence_span"]

        class MissingEvidenceProvider:
            def complete(self, *_args):
                return json.dumps(package)

        service = InsightService(provider=MissingEvidenceProvider(), strict_mode=True)
        with self.assertRaises(Exception):
            service.build_final([{"start_ms": 0, "end_ms": 1, "speaker": "A", "text": "hello"}])


if __name__ == "__main__":
    unittest.main()
