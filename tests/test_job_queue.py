import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from insightkit.data.store import InsightStore
from insightkit.insights.service import InsightService
from insightkit.ipc.job_queue import JobQueue
from insightkit.ipc.watch_bridge import WatchBridge


class TestJobQueue(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.store = InsightStore(Path(self.tmp) / "test.db")
        self.store.init_schema()
        self.service = mock.MagicMock(spec=InsightService)
        self.watch = WatchBridge()
        self.queue = JobQueue(store=self.store, insight_service=self.service, watch_bridge=self.watch)

    def tearDown(self):
        self.queue.shutdown()

    def test_import_file_creates_job(self):
        media = Path(self.tmp) / "demo.wav"
        media.write_bytes(b"fake")
        result = self.queue.transcription_import_file({"file_path": str(media)})
        self.assertIn("job_id", result)
        self.assertEqual(result["state"], "queued")

    def test_import_file_requires_path(self):
        with self.assertRaises(ValueError):
            self.queue.transcription_import_file({"file_path": ""})

    def test_import_file_requires_existing_file(self):
        with self.assertRaises(FileNotFoundError):
            self.queue.transcription_import_file({"file_path": "/nonexistent/file.wav"})

    def test_status_returns_shape(self):
        result = self.queue.transcription_status({})
        self.assertIn("watcher", result)
        self.assertIn("queue", result)
        self.assertIn("jobs", result)

    def test_cancel_nonexistent_job_raises(self):
        with self.assertRaises(ValueError):
            self.queue.transcription_cancel_job({"job_id": "no-such-id"})

    def test_cancel_queued_job(self):
        media = Path(self.tmp) / "demo.wav"
        media.write_bytes(b"fake")
        with mock.patch("insightkit.ipc.job_queue.run_transcription_job", side_effect=lambda **kw: time.sleep(5)):
            imported = self.queue.transcription_import_file({"file_path": str(media)})
            job_id = imported["job_id"]
            # Give worker a moment to potentially pick it up
            time.sleep(0.1)
            result = self.queue.transcription_cancel_job({"job_id": job_id, "reason": "test"})
            self.assertIn(result["state"], {"cancelled", "running"})


if __name__ == "__main__":
    unittest.main()
