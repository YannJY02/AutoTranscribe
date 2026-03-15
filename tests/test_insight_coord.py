import tempfile
import unittest
from pathlib import Path

from insightkit.data.store import InsightStore
from insightkit.insights.provider import RuleBasedProvider
from insightkit.insights.service import InsightService
from insightkit.ipc.insight_coord import InsightCoordinator


class TestInsightCoordinator(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.store = InsightStore(Path(self.tmp) / "test.db")
        self.service = InsightService(provider=RuleBasedProvider(), strict_mode=False)
        self.coord = InsightCoordinator(store=self.store, insight_service=self.service)

    def test_refresh_live_empty_session(self):
        self.store.upsert_meeting("m-1", "test", "mic", status="recording")
        result = self.coord.insight_refresh_live({"meeting_id": "m-1", "window_sec": 120})
        self.assertEqual(result["meeting_id"], "m-1")
        self.assertEqual(result["mode"], "live")
        self.assertIn("insight_package", result)

    def test_build_final(self):
        self.store.upsert_meeting("m-1", "test", "mic", status="stopped")
        result = self.coord.insight_build_final({"meeting_id": "m-1"})
        self.assertEqual(result["mode"], "final")
        self.assertIn("needs_review_count", result)

    def test_document_export_markdown(self):
        self.store.upsert_meeting("m-1", "test", "mic", status="stopped")
        out_dir = Path(self.tmp) / "export"
        result = self.coord.document_export({
            "meeting_id": "m-1",
            "format": "markdown",
            "output_dir": str(out_dir),
        })
        self.assertIn("path", result)
        self.assertTrue(Path(result["path"]).exists())


if __name__ == "__main__":
    unittest.main()
