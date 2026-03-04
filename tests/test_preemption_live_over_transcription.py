import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from insightkit.data.store import InsightStore
from insightkit.ipc import server as server_module
from insightkit.ipc.server import InsightRPCServer


class TestPreemptionLiveOverTranscription(unittest.TestCase):
    def test_cancel_running_job_with_preemption_reason(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            db = tmp_path / "insightkit.db"
            store = InsightStore(db)
            server = InsightRPCServer(socket_path=tmp_path / "sock", store=store)

            media = tmp_path / "long.wav"
            media.write_bytes(b"long")

            def fake_runner(**kwargs):
                cancel_event = kwargs.get("cancel_event")
                cb = kwargs.get("on_progress")
                for idx in range(30):
                    if cancel_event is not None and cancel_event.is_set():
                        raise server_module.JobCancelled("job cancelled")
                    if cb:
                        cb(min(95, idx * 3), "running")
                    time.sleep(0.05)
                return {
                    "meeting_id": kwargs["meeting_id"],
                    "title": "long",
                    "source_path": kwargs["file_path"],
                    "segments_count": 4,
                    "insight_package": {},
                }

            with mock.patch("insightkit.ipc.server.run_transcription_job", side_effect=fake_runner):
                imported = server._transcription_import_file({"file_path": str(media)})
                job_id = imported["job_id"]

                deadline = time.time() + 4
                while time.time() < deadline:
                    status = server._transcription_status({})
                    active = status.get("active_job")
                    if active and active.get("id") == job_id:
                        break
                    time.sleep(0.05)

                cancelled = server._transcription_cancel_job({"job_id": job_id, "reason": "preempted_by_live"})
                self.assertEqual(cancelled["state"], "paused_by_live")

                deadline = time.time() + 4
                final_state = ""
                while time.time() < deadline:
                    status = server._transcription_status({})
                    jobs = status.get("jobs", [])
                    row = next((x for x in jobs if x.get("id") == job_id), None)
                    if row is None:
                        time.sleep(0.05)
                        continue
                    final_state = str(row.get("state", ""))
                    if final_state in {"paused_by_live", "cancelled"}:
                        break
                    time.sleep(0.05)

                self.assertIn(final_state, {"paused_by_live", "cancelled"})

            server.shutdown()


if __name__ == "__main__":
    unittest.main()
