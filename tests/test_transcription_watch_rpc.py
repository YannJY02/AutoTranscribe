import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from insightkit.data.store import InsightStore
from insightkit.ipc.server import InsightRPCServer


class TestTranscriptionWatchRPC(unittest.TestCase):
    def test_watch_start_and_stop(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            watch_dir = tmp_path / "watch"
            watch_dir.mkdir(parents=True)

            db = tmp_path / "insightkit.db"
            store = InsightStore(db)
            server = InsightRPCServer(socket_path=tmp_path / "sock", store=store)

            def fake_runner(**kwargs):
                cb = kwargs.get("on_progress")
                if cb:
                    cb(100, "completed")
                return {
                    "meeting_id": kwargs["meeting_id"],
                    "title": "watch-demo",
                    "source_path": kwargs["file_path"],
                    "segments_count": 1,
                    "insight_package": {},
                }

            with mock.patch("insightkit.ipc.job_queue.run_transcription_job", side_effect=fake_runner):
                started = server._transcription_watch_start({"dirs": [str(watch_dir)]})
                self.assertEqual(started["state"], "running")

                media = watch_dir / "clip.mp3"
                media.write_bytes(b"watch")

                deadline = time.time() + 8
                jobs_seen = 0
                while time.time() < deadline:
                    status = server._transcription_status({})
                    jobs_seen = len(status.get("jobs", []))
                    if jobs_seen > 0:
                        break
                    time.sleep(0.25)

                self.assertGreater(jobs_seen, 0)

                stopped = server._transcription_watch_stop({})
                self.assertEqual(stopped["state"], "stopped")

            server.shutdown()


if __name__ == "__main__":
    unittest.main()
