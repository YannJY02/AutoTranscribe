import unittest

from insightkit.insights.provider import RuleBasedProvider
from insightkit.insights.service import InsightService


class TestStrictNoFallback(unittest.TestCase):
    def test_strict_mode_rejects_non_json_provider_payload(self):
        service = InsightService(provider=RuleBasedProvider(), strict_mode=True)
        with self.assertRaises(Exception):
            service.build_live([{"start_ms": 0, "end_ms": 1, "speaker": "", "text": "hello"}])


if __name__ == "__main__":
    unittest.main()
