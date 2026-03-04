import tempfile
import unittest
from pathlib import Path

from insightkit.data.store import InsightStore
from insightkit.ipc.server import InsightRPCServer


class TestTranscriptionStatusLimit(unittest.TestCase):
    def test_status_respects_limit_param(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = Path(tmp) / "insightkit.db"
            server = InsightRPCServer(socket_path=Path(tmp) / "sock", store=InsightStore(db))

            with server._tx_lock:
                for idx in range(6):
                    server._tx_jobs[str(idx)] = {
                        "id": str(idx),
                        "meeting_id": f"m-{idx}",
                        "source_path": f"/tmp/{idx}.wav",
                        "title": f"job-{idx}",
                        "state": "queued",
                        "progress": 0,
                        "stage": "queued",
                        "error": "",
                        "reason": "",
                        "started_at": f"2026-03-04T00:00:0{idx}Z",
                        "ended_at": "",
                    }
                    server._tx_queue.append(str(idx))

            full = server._transcription_status({})
            limited = server._transcription_status({"limit": 2})

            self.assertGreaterEqual(len(full["jobs"]), 6)
            self.assertEqual(len(limited["jobs"]), 2)
            self.assertEqual(len(limited["queue"]), 2)
            server.shutdown()


if __name__ == "__main__":
    unittest.main()
