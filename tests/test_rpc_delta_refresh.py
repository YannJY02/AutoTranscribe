import tempfile
import unittest
from pathlib import Path

from insightkit.data.store import InsightStore
from insightkit.insights.provider import RuleBasedProvider
from insightkit.insights.service import InsightService
from insightkit.ipc.server import InsightRPCServer


class TestRPCDeltaRefresh(unittest.TestCase):
    def test_delta_then_refresh_live(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = Path(tmp) / "insightkit.db"
            store = InsightStore(db)
            server = InsightRPCServer(
                socket_path=Path(tmp) / "sock",
                store=store,
                insight_service=InsightService(provider=RuleBasedProvider(), strict_mode=False),
            )

            sid = "s-1"
            server._session_start({"meeting_id": sid, "title": "demo", "source": "mixed"})
            delta = server._transcript_delta(
                {
                    "meeting_id": sid,
                    "segments": [
                        {
                            "start_ms": 0,
                            "end_ms": 1200,
                            "speaker": "spk0",
                            "source": "mixed",
                            "text": "first segment",
                            "confidence": 0.8,
                        },
                        {
                            "start_ms": 1300,
                            "end_ms": 2200,
                            "speaker": "spk1",
                            "source": "mic",
                            "text": "second segment",
                            "confidence": 0.7,
                        },
                    ],
                }
            )
            self.assertEqual(delta["ingested"], 2)

            live = server._insight_refresh_live({"meeting_id": sid, "window_sec": 120})
            self.assertEqual(live["meeting_id"], sid)
            self.assertEqual(live["mode"], "live")
            self.assertIn("updated_at", live)
            self.assertIn("insight_package", live)
            self.assertIn("provider", live)
            self.assertIn("needs_review_count", live)

            segments = store.list_segments(sid)
            self.assertEqual(segments[0]["source"], "mixed")
            self.assertEqual(segments[1]["source"], "mic")

            stopped = server._session_stop({"meeting_id": sid})
            self.assertEqual(stopped["meeting_id"], sid)
            self.assertEqual(stopped["status"], "stopped")

            server.shutdown()


if __name__ == "__main__":
    unittest.main()
