import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from insightkit.data.store import InsightStore
from insightkit.ipc.server import InsightRPCServer


class TestTranscriptionImportRPC(unittest.TestCase):
    def test_import_file_creates_and_completes_job(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            db = tmp_path / "insightkit.db"
            store = InsightStore(db)
            server = InsightRPCServer(socket_path=tmp_path / "sock", store=store)

            media = tmp_path / "demo.wav"
            media.write_bytes(b"fake")

            def fake_runner(**kwargs):
                cb = kwargs.get("on_progress")
                if cb:
                    cb(100, "completed")
                return {
                    "meeting_id": kwargs["meeting_id"],
                    "title": "demo",
                    "source_path": kwargs["file_path"],
                    "segments_count": 3,
                    "insight_package": {},
                }

            with mock.patch("insightkit.ipc.server.run_transcription_job", side_effect=fake_runner):
                imported = server._transcription_import_file({"file_path": str(media)})
                self.assertIn("job_id", imported)
                job_id = imported["job_id"]

                deadline = time.time() + 3
                final_state = ""
                while time.time() < deadline:
                    status = server._transcription_status({})
                    jobs = status.get("jobs", [])
                    row = next((x for x in jobs if x.get("id") == job_id), None)
                    if row is None:
                        time.sleep(0.05)
                        continue
                    final_state = str(row.get("state", ""))
                    if final_state == "completed":
                        break
                    time.sleep(0.05)

                self.assertEqual(final_state, "completed")
                status = server._transcription_status({})
                self.assertIn("last_completed", status)

            server.shutdown()


if __name__ == "__main__":
    unittest.main()
