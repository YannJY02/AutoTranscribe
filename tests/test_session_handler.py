import tempfile
import unittest
from pathlib import Path

from insightkit.data.store import InsightStore
from insightkit.ipc.session_handler import SessionHandler


class TestSessionHandler(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.store = InsightStore(Path(self.tmp) / "test.db")
        self.handler = SessionHandler(store=self.store)

    def test_session_start_returns_meeting_id(self):
        result = self.handler.session_start({"title": "test", "source": "mic"})
        self.assertIn("meeting_id", result)
        self.assertEqual(result["status"], "recording")

    def test_session_start_with_explicit_id(self):
        result = self.handler.session_start({"meeting_id": "m-1", "title": "demo", "source": "file"})
        self.assertEqual(result["meeting_id"], "m-1")

    def test_session_stop(self):
        self.handler.session_start({"meeting_id": "m-1", "title": "t", "source": "file"})
        result = self.handler.session_stop({"meeting_id": "m-1"})
        self.assertEqual(result["status"], "stopped")

    def test_transcript_delta_ingests_segments(self):
        self.handler.session_start({"meeting_id": "m-1", "title": "t", "source": "mic"})
        result = self.handler.transcript_delta({
            "meeting_id": "m-1",
            "segments": [
                {"start_ms": 0, "end_ms": 1000, "speaker": "spk0", "source": "mic", "text": "hello", "confidence": 0.9},
            ],
        })
        self.assertEqual(result["ingested"], 1)

    def test_transcript_list(self):
        self.handler.session_start({"meeting_id": "m-1", "title": "t", "source": "mic"})
        self.handler.transcript_delta({
            "meeting_id": "m-1",
            "segments": [
                {"start_ms": 0, "end_ms": 500, "speaker": "spk0", "source": "mic", "text": "a", "confidence": 0.8},
                {"start_ms": 600, "end_ms": 1000, "speaker": "spk0", "source": "mic", "text": "b", "confidence": 0.8},
            ],
        })
        result = self.handler.transcript_list({"meeting_id": "m-1", "limit": 1})
        self.assertEqual(len(result["segments"]), 1)

    def test_live_session_start_and_stop(self):
        result = self.handler.live_session_start({"meeting_id": "m-2", "title": "live", "source": "mixed"})
        self.assertEqual(result["state"], "running")
        stopped = self.handler.live_session_stop({"meeting_id": "m-2"})
        self.assertEqual(stopped["state"], "stopped")

    def test_live_session_status(self):
        self.handler.live_session_start({"meeting_id": "m-3", "title": "live", "source": "mixed"})
        status = self.handler.live_session_status({"meeting_id": "m-3"})
        self.assertEqual(status["state"], "running")
        self.assertEqual(status["meeting_id"], "m-3")

    def test_stream_push_audio_accepted(self):
        result = self.handler.stream_push_audio({})
        self.assertTrue(result["accepted"])


if __name__ == "__main__":
    unittest.main()
