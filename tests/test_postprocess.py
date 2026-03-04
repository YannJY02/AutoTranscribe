import unittest

from insightkit.insights.postprocess import postprocess_insight_package


class TestPostprocess(unittest.TestCase):
    def test_dedupes_and_normalizes_span(self):
        payload = {
            "session_overview": {"title": "t", "overview": "o", "topics": []},
            "highlight_insights": [
                {"quote": "A", "reason": "r", "speaker": "", "evidence_span": {"start_ms": 10, "end_ms": 5}},
                {"quote": "A", "reason": "r2", "speaker": "", "evidence_span": {"start_ms": 0, "end_ms": 1}},
            ],
            "speaker_perspectives": [],
            "decision_ledger": [],
            "action_tracks": [],
            "timeline_beats": [],
            "provenance_links": [],
        }

        out = postprocess_insight_package(payload)
        self.assertEqual(len(out["highlight_insights"]), 1)
        self.assertEqual(out["highlight_insights"][0]["evidence_span"], {"start_ms": 10, "end_ms": 10})


if __name__ == "__main__":
    unittest.main()
