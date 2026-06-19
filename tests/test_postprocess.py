import unittest

from insightkit.insights.postprocess import postprocess_insight_package
from insightkit.insights.schema_validator import validate_insight_package


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

    def test_clamps_short_audio_timeline_timestamp_to_real_duration(self):
        payload = {
            "session_overview": {"title": "t", "overview": "o", "topics": []},
            "highlight_insights": [],
            "speaker_perspectives": [],
            "decision_ledger": [],
            "action_tracks": [],
            "timeline_beats": [
                {"timestamp": "00:11", "title": "ok", "summary": "inside duration"},
                {"timestamp": "01:13", "title": "bad", "summary": "provider overshot a 30s clip"},
                {"timestamp": "03:45", "title": "clamp", "summary": "well past duration"},
            ],
            "provenance_links": [],
        }
        transcript = [{"start_ms": 11000, "end_ms": 29735, "text": "short clip"}]

        out = postprocess_insight_package(payload, full_transcript=transcript)

        self.assertEqual(out["timeline_beats"][0]["timestamp"], "00:11")
        self.assertEqual(out["timeline_beats"][1]["timestamp"], "00:13")
        self.assertEqual(out["timeline_beats"][2]["timestamp"], "00:29")

    def test_action_tracks_with_blank_owner_remain_schema_valid(self):
        payload = {
            "session_overview": {"title": "t", "overview": "o", "topics": []},
            "highlight_insights": [],
            "speaker_perspectives": [],
            "decision_ledger": [],
            "action_tracks": [
                {
                    "task": "添加注册说明信息",
                    "owner": " ",
                    "due_at": "",
                    "priority": "medium",
                    "status": "open",
                    "needs_review": False,
                    "evidence_span": {"start_ms": 11680, "end_ms": 21815},
                }
            ],
            "timeline_beats": [],
            "provenance_links": [],
        }

        out = postprocess_insight_package(payload)

        self.assertEqual(out["action_tracks"][0]["owner"], "待分配")
        self.assertTrue(out["action_tracks"][0]["needs_review"])
        validate_insight_package(out)


if __name__ == "__main__":
    unittest.main()
