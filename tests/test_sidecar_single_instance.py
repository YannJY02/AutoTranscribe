import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

from insightkit.data.store import InsightStore
from insightkit.ipc.server import InsightRPCServer


class TestSidecarSingleInstance(unittest.TestCase):
    def test_sidecar_version_exposes_capabilities(self):
        with tempfile.TemporaryDirectory() as tmp:
            db_path = Path(tmp) / "insightkit.db"
            server = InsightRPCServer(store=InsightStore(db_path=db_path))
            version = server._sidecar_version({})
            self.assertIn("version", version)
            self.assertIn("build", version)
            self.assertEqual(version.get("idle_shutdown_guard"), "accepted-v1")
            self.assertIn("capabilities", version)
            self.assertIn("sidecar.shutdown", version["capabilities"])
            self.assertIn("asr.transcribe_media", version["capabilities"])
            self.assertIn("transcript.replace", version["capabilities"])
            status = server._sidecar_status({})
            self.assertIn("last_error_code", status)
            self.assertIn("last_latency_ms", status)
            server.shutdown()

    def test_sidecar_shutdown_returns_immediately(self):
        with tempfile.TemporaryDirectory() as tmp:
            db_path = Path(tmp) / "insightkit.db"
            server = InsightRPCServer(store=InsightStore(db_path=db_path))
            with mock.patch.object(server, "shutdown") as shutdown:
                result = server._sidecar_shutdown({})
                self.assertTrue(result.get("ok"))
                self.assertTrue(result.get("shutting_down"))
                for _ in range(20):
                    if shutdown.called:
                        break
                    time.sleep(0.02)
                self.assertTrue(shutdown.called)

    def test_sidecar_idle_shutdown_refuses_active_transcription_work(self):
        with tempfile.TemporaryDirectory() as tmp:
            db_path = Path(tmp) / "insightkit.db"
            server = InsightRPCServer(store=InsightStore(db_path=db_path))
            with mock.patch.object(server._job_queue, "begin_idle_shutdown", return_value=False):
                with self.assertRaisesRegex(RuntimeError, "sidecar_busy"):
                    server._sidecar_shutdown({"require_idle": True})
            server.shutdown()

    def test_sidecar_idle_shutdown_refuses_live_session(self):
        with tempfile.TemporaryDirectory() as tmp:
            server = InsightRPCServer(store=InsightStore(db_path=Path(tmp) / "insightkit.db"))
            server._session_start({"meeting_id": "live-1"})

            with self.assertRaisesRegex(RuntimeError, "sidecar_busy"):
                server._sidecar_shutdown({"require_idle": True})
            server.shutdown()

    def test_sidecar_idle_shutdown_refuses_stop_to_record_save_gap(self):
        with tempfile.TemporaryDirectory() as tmp:
            server = InsightRPCServer(store=InsightStore(db_path=Path(tmp) / "insightkit.db"))
            server._session_start({"meeting_id": "live-finalizing"})
            token = "client-lease-1"
            server._session_stop({
                "meeting_id": "live-finalizing",
                "await_record_save": True,
                "finalization_lease_token": token,
            })

            with self.assertRaisesRegex(RuntimeError, "sidecar_busy"):
                server._sidecar_shutdown({"require_idle": True})

            with mock.patch(
                "insightkit.records.record_writer.RecordWriter.write_record",
                return_value=Path(tmp) / "record",
            ):
                server._records_save({
                    "meeting_id": "live-finalizing",
                    "segments": [],
                    "finalization_lease_token": token,
                })
            with mock.patch.object(server, "shutdown") as shutdown:
                result = server._sidecar_shutdown({"require_idle": True})
                for _ in range(20):
                    if shutdown.called:
                        break
                    time.sleep(0.02)
            self.assertEqual(result.get("idle_guard"), "accepted-v1")
            server.shutdown()

    def test_standalone_stop_without_save_does_not_block_idle_shutdown(self):
        with tempfile.TemporaryDirectory() as tmp:
            server = InsightRPCServer(store=InsightStore(db_path=Path(tmp) / "insightkit.db"))
            server._session_start({"meeting_id": "external-stop"})
            server._session_stop({"meeting_id": "external-stop"})

            with mock.patch.object(server, "shutdown") as shutdown:
                result = server._sidecar_shutdown({"require_idle": True})
                for _ in range(20):
                    if shutdown.called:
                        break
                    time.sleep(0.02)
            self.assertEqual(result.get("idle_guard"), "accepted-v1")
            server.shutdown()

    def test_failed_record_save_lease_can_be_aborted(self):
        with tempfile.TemporaryDirectory() as tmp:
            server = InsightRPCServer(store=InsightStore(db_path=Path(tmp) / "insightkit.db"))
            server._session_start({"meeting_id": "failed-save"})
            token = "client-lease-2"
            server._session_stop({
                "meeting_id": "failed-save",
                "await_record_save": True,
                "finalization_lease_token": token,
            })
            with mock.patch(
                "insightkit.records.record_writer.RecordWriter.write_record",
                side_effect=OSError("disk full"),
            ):
                with self.assertRaisesRegex(OSError, "disk full"):
                    server._records_save({
                        "meeting_id": "failed-save",
                        "segments": [],
                        "finalization_lease_token": token,
                    })
            with self.assertRaisesRegex(RuntimeError, "sidecar_busy"):
                server._sidecar_shutdown({"require_idle": True})

            server._session_finalization_abort({
                "meeting_id": "failed-save",
                "finalization_lease_token": token,
            })
            with mock.patch.object(server, "shutdown") as shutdown:
                result = server._sidecar_shutdown({"require_idle": True})
                for _ in range(20):
                    if shutdown.called:
                        break
                    time.sleep(0.02)
            self.assertEqual(result.get("idle_guard"), "accepted-v1")
            server.shutdown()

    def test_finalization_lease_is_idempotent_and_generation_bound(self):
        with tempfile.TemporaryDirectory() as tmp:
            server = InsightRPCServer(store=InsightStore(db_path=Path(tmp) / "insightkit.db"))
            server._session_start({"meeting_id": "generation-bound"})
            params = {
                "meeting_id": "generation-bound",
                "await_record_save": True,
                "finalization_lease_token": "generation-token",
            }
            server._session_stop(params)
            server._session_stop(params)

            with self.assertRaisesRegex(RuntimeError, "session_finalizing"):
                server._session_start({"meeting_id": "generation-bound"})
            with self.assertRaisesRegex(RuntimeError, "invalid_finalization_lease"):
                server._session_finalization_abort({
                    "meeting_id": "generation-bound",
                    "finalization_lease_token": "wrong-token",
                })
            with self.assertRaisesRegex(RuntimeError, "invalid_finalization_lease"):
                server._session_stop({
                    "meeting_id": "generation-bound",
                    "await_record_save": True,
                    "finalization_lease_token": "different-token",
                })
            server._session_finalization_abort({
                "meeting_id": "generation-bound",
                "finalization_lease_token": "generation-token",
            })
            server._session_finalization_abort({
                "meeting_id": "generation-bound",
                "finalization_lease_token": "generation-token",
            })
            server.shutdown()

    def test_missing_lease_token_does_not_stop_running_session(self):
        with tempfile.TemporaryDirectory() as tmp:
            server = InsightRPCServer(store=InsightStore(db_path=Path(tmp) / "insightkit.db"))
            server._session_start({"meeting_id": "missing-token"})

            with self.assertRaisesRegex(ValueError, "finalization_lease_token"):
                server._session_stop({
                    "meeting_id": "missing-token",
                    "await_record_save": True,
                })
            self.assertEqual(server._session_handler.active_session_count(), 1)
            server.shutdown()

    def test_record_save_with_token_rejects_running_session(self):
        with tempfile.TemporaryDirectory() as tmp:
            server = InsightRPCServer(store=InsightStore(db_path=Path(tmp) / "insightkit.db"))
            server._session_start({"meeting_id": "stop-not-delivered"})

            with self.assertRaisesRegex(RuntimeError, "finalization_not_stopped"):
                server._records_save({
                    "meeting_id": "stop-not-delivered",
                    "segments": [],
                    "finalization_lease_token": "client-token",
                })
            self.assertEqual(server._session_handler.active_session_count(), 1)
            server.shutdown()

    def test_record_save_retry_is_idempotent_after_lease_release(self):
        with tempfile.TemporaryDirectory() as tmp:
            server = InsightRPCServer(store=InsightStore(db_path=Path(tmp) / "insightkit.db"))
            token = "response-loss-token"
            server._session_start({"meeting_id": "response-loss"})
            server._session_stop({
                "meeting_id": "response-loss",
                "await_record_save": True,
                "finalization_lease_token": token,
            })
            params = {
                "meeting_id": "response-loss",
                "segments": [],
                "finalization_lease_token": token,
            }
            with mock.patch(
                "insightkit.records.record_writer.RecordWriter.write_record",
                return_value=Path(tmp) / "record",
            ) as write_record:
                server._records_save(params)
                server._records_save(params)
            self.assertEqual(write_record.call_count, 2)
            server._session_finalization_abort({
                "meeting_id": "response-loss",
                "finalization_lease_token": token,
            })
            server.shutdown()

    def test_sidecar_idle_shutdown_blocks_new_mutations(self):
        with tempfile.TemporaryDirectory() as tmp:
            server = InsightRPCServer(store=InsightStore(db_path=Path(tmp) / "insightkit.db"))
            with mock.patch.object(server, "shutdown") as shutdown:
                result = server._sidecar_shutdown({"require_idle": True})
                response = server._dispatch({"id": 1, "method": "session.start", "params": {}})

                self.assertEqual(result.get("idle_guard"), "accepted-v1")
                self.assertIn("sidecar_shutting_down", response["error"]["message"])
                for _ in range(20):
                    if shutdown.called:
                        break
                    time.sleep(0.02)
            server.shutdown()

    def test_sidecar_idle_shutdown_refuses_in_flight_mutation(self):
        with tempfile.TemporaryDirectory() as tmp:
            server = InsightRPCServer(store=InsightStore(db_path=Path(tmp) / "insightkit.db"))
            started = threading.Event()
            release = threading.Event()

            def slow_start(params):
                started.set()
                release.wait(timeout=1)
                return {"meeting_id": "m-1"}

            with mock.patch.object(server, "_session_start", side_effect=slow_start):
                thread = threading.Thread(
                    target=server._dispatch,
                    args=({"id": 1, "method": "session.start", "params": {}},),
                )
                thread.start()
                self.assertTrue(started.wait(timeout=1))
                with self.assertRaisesRegex(RuntimeError, "sidecar_busy"):
                    server._sidecar_shutdown({"require_idle": True})
                release.set()
                thread.join(timeout=1)
            server.shutdown()


if __name__ == "__main__":
    unittest.main()
