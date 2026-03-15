import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from insightkit.data.store import InsightStore
from insightkit.ipc.server import InsightRPCServer
from scripts import transcriber


def wait_for_state(expected: str, timeout: float = 2.0) -> dict:
    deadline = time.time() + timeout
    while time.time() < deadline:
        status = transcriber.runtime_warm_status()
        if status.get("state") == expected:
            return status
        time.sleep(0.02)
    raise AssertionError(f"warm state never reached {expected}: {transcriber.runtime_warm_status()}")


class TestASRPrewarmRPC(unittest.TestCase):
    def setUp(self):
        transcriber._reset_runtime_state_for_tests()  # noqa: SLF001

    def tearDown(self):
        transcriber._reset_runtime_state_for_tests()  # noqa: SLF001

    def test_asr_prewarm_returns_structured_payload(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = Path(tmp) / "insightkit.db"
            server = InsightRPCServer(socket_path=Path(tmp) / "sock", store=InsightStore(db))
            gate = threading.Event()

            def slow_warmup(_engine: str) -> None:
                gate.wait(timeout=1.0)

            with (
                patch("scripts.transcriber._load_whisper_model", return_value=object()),
                patch("scripts.transcriber._warmup_once", side_effect=slow_warmup),
            ):
                started = time.perf_counter()
                result = server._asr_prewarm({"engine": "whisper", "model": "large-v3", "timeout_sec": 20})  # noqa: SLF001
                elapsed = time.perf_counter() - started

                self.assertLess(elapsed, 0.3)
                self.assertTrue(result.get("ok"))
                self.assertIn(result.get("state"), {"loading", "warming"})
                self.assertTrue(result.get("started"))
                self.assertTrue(result.get("in_progress"))
                self.assertEqual(result.get("attempt"), 1)
                self.assertEqual(result.get("watchdog_sec"), 20)
                self.assertEqual(result.get("warm_ms"), 0)
                self.assertIn("warm", result)
                self.assertIn(result["warm"].get("state"), {"loading", "warming"})
                self.assertTrue(result["warm"].get("in_progress"))

                gate.set()
                final = wait_for_state("ready")
                self.assertTrue(final.get("ready"))
                self.assertGreaterEqual(final.get("last_warm_ms", 0), 0)

            self.assertIn("backend", result)
            self.assertIn("configured_device", result["backend"])
            server.shutdown()

    def test_asr_prewarm_is_singleflight(self):
        gate = threading.Event()

        def slow_warmup(_engine: str) -> None:
            gate.wait(timeout=1.0)

        with (
            patch("scripts.transcriber._load_whisper_model", return_value=object()),
            patch("scripts.transcriber._warmup_once", side_effect=slow_warmup),
        ):
            first = transcriber.prewarm_asr(engine="whisper", model="large-v3", timeout_sec=20)
            second = transcriber.prewarm_asr(engine="whisper", model="large-v3", timeout_sec=20)

            self.assertTrue(first["started"])
            self.assertFalse(second["started"])
            self.assertTrue(first["in_progress"])
            self.assertTrue(second["in_progress"])
            self.assertEqual(first["attempt"], 1)
            self.assertEqual(second["attempt"], 1)

            gate.set()
            wait_for_state("ready")

    def test_failed_background_prewarm_can_retry(self):
        calls = {"count": 0}

        def flaky_warmup(_engine: str) -> None:
            calls["count"] += 1
            if calls["count"] == 1:
                raise RuntimeError("warm boom")

        with (
            patch("scripts.transcriber._load_whisper_model", return_value=object()),
            patch("scripts.transcriber._warmup_once", side_effect=flaky_warmup),
        ):
            first = transcriber.prewarm_asr(engine="whisper", model="large-v3", timeout_sec=20)
            self.assertTrue(first["ok"])
            failed = wait_for_state("failed")
            self.assertEqual(failed.get("attempt"), 1)
            self.assertIn("warm boom", failed.get("last_error", ""))

            second = transcriber.prewarm_asr(engine="whisper", model="large-v3", timeout_sec=20)
            self.assertTrue(second["started"])
            self.assertEqual(second["attempt"], 2)
            ready = wait_for_state("ready")
            self.assertTrue(ready.get("ready"))
            self.assertEqual(ready.get("attempt"), 2)

    def test_runtime_status_snapshot_is_not_blocked_by_model_registry_lock(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = Path(tmp) / "insightkit.db"
            server = InsightRPCServer(socket_path=Path(tmp) / "sock", store=InsightStore(db))
            lock = transcriber._model_registry_lock  # noqa: SLF001

            lock.acquire()
            try:
                started = time.perf_counter()
                result = server._asr_runtime_status({"engine": "whisper"})  # noqa: SLF001
                elapsed = time.perf_counter() - started
            finally:
                lock.release()

            self.assertLess(elapsed, 0.2)
            self.assertIn("warm", result)
            self.assertEqual(result["warm"].get("state"), "idle")
            self.assertIn("backend", result)
            server.shutdown()


if __name__ == "__main__":
    unittest.main()
