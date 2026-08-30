import tempfile
import time
import unittest
import json
from pathlib import Path
from unittest import mock

from insightkit.data.store import InsightStore
from insightkit.ipc.server import InsightRPCServer


class TestTranscriptionImportRPC(unittest.TestCase):
    def test_offline_local_import_creates_canonical_record_without_cloud_key(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            records_root = tmp_path / "Records"
            media = tmp_path / "synthetic.wav"
            media.write_bytes(b"privacy-safe synthetic fixture")
            fake_asr = {
                "segments": [
                    {"start": 0, "end": 1800, "speaker": "Speaker 1", "text": "We decided to run locally."},
                    {"start": 1800, "end": 3600, "speaker": "Speaker 2", "text": "Speaker 2 owns review by Friday."},
                ]
            }

            with mock.patch.dict("os.environ", {
                "INSIGHTKIT_RECORDS_ROOT": str(records_root),
                "OPENAI_API_KEY": "",
                "DEEPSEEK_API_KEY": "",
            }, clear=False):
                server = InsightRPCServer(
                    socket_path=tmp_path / "sock",
                    store=InsightStore(tmp_path / "insightkit.db"),
                )
                try:
                    with mock.patch("scripts.transcription_runner.transcribe", return_value=fake_asr), \
                            mock.patch("urllib.request.urlopen", side_effect=AssertionError("network disabled")), \
                            mock.patch("socket.create_connection", side_effect=AssertionError("network disabled")):
                        imported = server._transcription_import_file({
                            "file_path": str(media),
                            "meeting_id": "offline-import-e2e",
                            "provider_vendor": "local",
                            "provider_model": "extractive-v1",
                            "strict_mode": False,
                        })
                        deadline = time.time() + 3
                        row = None
                        while time.time() < deadline:
                            row = next(
                                (item for item in server._transcription_status({})["jobs"] if item["id"] == imported["job_id"]),
                                None,
                            )
                            if row and row["state"] in {"completed", "failed"}:
                                break
                            time.sleep(0.05)

                    self.assertEqual(row["state"], "completed", row.get("error"))
                    record_path = Path(server._transcription_status({})["last_completed"]["record_path"])
                    metadata = json.loads((record_path / "metadata.json").read_text())
                    package = json.loads((record_path / "insight_package.json").read_text())
                    self.assertEqual(metadata["analysis"]["provider"], "local")
                    self.assertEqual(
                        package["provenance_links"][-1]["url"],
                        "InsightKit SQLite segments: meeting_id=offline-import-e2e",
                    )
                    self.assertTrue((record_path / "minutes.json").exists())
                finally:
                    server.shutdown()

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

            with mock.patch("insightkit.ipc.job_queue.run_transcription_job", side_effect=fake_runner):
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
