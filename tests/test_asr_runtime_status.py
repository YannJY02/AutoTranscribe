import unittest

from scripts.asr_runtime_bootstrap import runtime_status


class TestASRRuntimeStatus(unittest.TestCase):
    def test_status_shape(self):
        status = runtime_status()
        self.assertIn("python", status)
        self.assertIn("engine", status)
        self.assertIn("model", status)
        self.assertIn("vad", status)
        self.assertIn("speaker_diarization", status)
        self.assertIn("dependencies", status)
        self.assertIn("ready", status)

        self.assertTrue(isinstance(status["ready"], bool))
        self.assertTrue(isinstance(status["python"], dict))
        self.assertTrue(isinstance(status["model"], dict))


if __name__ == "__main__":
    unittest.main()
