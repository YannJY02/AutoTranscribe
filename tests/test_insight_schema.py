import unittest

from insightkit.insights.schema_validator import SchemaValidationError, validate_insight_package


def sample_payload():
    return {
        "session_overview": {
            "title": "会话",
            "overview": "概述",
            "topics": ["a"],
        },
        "highlight_insights": [
            {
                "quote": "q",
                "reason": "r",
                "speaker": "s",
                "evidence_span": {"start_ms": 0, "end_ms": 10},
            }
        ],
        "speaker_perspectives": [
            {
                "speaker": "S1",
                "viewpoints": ["观点"],
                "evidence_spans": [{"start_ms": 0, "end_ms": 10}],
            }
        ],
        "decision_ledger": [
            {
                "problem": "p",
                "options": ["o1"],
                "decision": "d",
                "rationale": "r",
                "owner": "u",
                "evidence_span": {"start_ms": 1, "end_ms": 2},
            }
        ],
        "action_tracks": [
            {
                "task": "t",
                "owner": "u",
                "due_at": "",
                "priority": "medium",
                "status": "draft",
                "evidence_span": {"start_ms": 3, "end_ms": 8},
            }
        ],
        "timeline_beats": [
            {
                "timestamp": "00:00",
                "title": "start",
                "summary": "sum",
            }
        ],
        "provenance_links": [
            {
                "label": "原记录",
                "url": "file:///tmp/mock",
            }
        ],
    }


class TestInsightSchema(unittest.TestCase):
    def test_validate_success(self):
        validate_insight_package(sample_payload())

    def test_validate_missing_key_fails(self):
        payload = sample_payload()
        payload.pop("decision_ledger")
        with self.assertRaises(SchemaValidationError):
            validate_insight_package(payload)


if __name__ == "__main__":
    unittest.main()
