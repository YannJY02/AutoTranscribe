import unittest

from scripts.asr_runtime_bootstrap import runtime_status


class TestASREngineSwitchStatus(unittest.TestCase):
    def test_status_supports_configured_engines(self):
        whisper = runtime_status(engine="whisper")
        funasr = runtime_status(engine="funasr")
        qwen = runtime_status(engine="qwen-mlx")

        self.assertEqual(whisper["engine"], "whisper")
        self.assertEqual(funasr["engine"], "funasr")
        self.assertEqual(qwen["engine"], "qwen-mlx")
        self.assertIn("ready_by_engine", whisper)
        self.assertIn("whisper", whisper["ready_by_engine"])
        self.assertIn("funasr", whisper["ready_by_engine"])
        self.assertIn("qwen-mlx", whisper["ready_by_engine"])
        self.assertIn("engine_options", whisper)
        self.assertIn("whisper", whisper["engine_options"])
        self.assertIn("funasr", whisper["engine_options"])
        self.assertIn("qwen-mlx", whisper["engine_options"])
        self.assertIn("timestamps", qwen)


if __name__ == "__main__":
    unittest.main()
