import unittest
import threading

from scripts.asr_runtime_bootstrap import runtime_status
from scripts import transcriber
from scripts.transcriber import runtime_backend_status, runtime_warm_status


class TestASRRuntimeStatus(unittest.TestCase):
    def setUp(self):
        transcriber._reset_runtime_state_for_tests()

    def test_status_shape(self):
        status = runtime_status()
        self.assertIn("python", status)
        self.assertIn("engine", status)
        self.assertIn("model", status)
        self.assertIn("vad", status)
        self.assertIn("speaker_diarization", status)
        self.assertIn("dependencies", status)
        self.assertIn("ready", status)
        self.assertIn("backend", status)
        self.assertIn("warm", status)
        self.assertIn("profile", status)

        self.assertTrue(isinstance(status["ready"], bool))
        self.assertTrue(isinstance(status["python"], dict))
        self.assertTrue(isinstance(status["model"], dict))
        self.assertTrue(isinstance(status["backend"], dict))
        self.assertTrue(isinstance(status["warm"], dict))

        self.assertIn("device", status["backend"])
        self.assertIn("compute_type", status["backend"])
        self.assertIn("resolved", status["backend"])
        self.assertIn("supported_compute_types", status["backend"])
        self.assertIn("configured_device", status["backend"])
        self.assertIn("configured_compute_type", status["backend"])

        self.assertIn("ready", status["warm"])
        self.assertIn("state", status["warm"])
        self.assertIn("in_progress", status["warm"])
        self.assertIn("attempt", status["warm"])
        self.assertIn("last_warm_ms", status["warm"])
        self.assertIn("last_error", status["warm"])
        self.assertEqual(status["profile"]["schema_version"], 1)
        self.assertIn("live_asr", status["profile"])
        self.assertIn("final_media_asr", status["profile"])
        self.assertIn("engine_profiles", status["profile"])
        self.assertIn("apple-speech", status["profile"]["engine_profiles"])

    def test_runtime_snapshot_defaults_include_background_warmup_fields(self):
        backend = runtime_backend_status()
        warm = runtime_warm_status()

        self.assertIn("configured_device", backend)
        self.assertIn("configured_compute_type", backend)
        self.assertIn("resolved", backend)
        self.assertIn("state", warm)
        self.assertIn("in_progress", warm)
        self.assertIn("attempt", warm)
        self.assertIn("last_error", warm)
        self.assertEqual(warm["state"], "idle")
        self.assertFalse(warm["in_progress"])

    def test_runtime_snapshot_does_not_block_on_model_registry_lock(self):
        result: dict[str, object] = {}
        finished = threading.Event()

        transcriber._model_registry_lock.acquire()
        try:
            worker = threading.Thread(
                target=lambda: result.update({"warm": runtime_warm_status()}) or finished.set(),
                daemon=True,
            )
            worker.start()
            self.assertTrue(
                finished.wait(0.2),
                "runtime_warm_status should not block on the model registry lock",
            )
        finally:
            transcriber._model_registry_lock.release()

        self.assertIn("warm", result)
        self.assertEqual(result["warm"]["state"], "idle")


if __name__ == "__main__":
    unittest.main()
