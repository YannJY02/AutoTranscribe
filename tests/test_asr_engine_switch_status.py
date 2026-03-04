import unittest

from scripts.asr_runtime_bootstrap import runtime_status


class TestASREngineSwitchStatus(unittest.TestCase):
    def test_status_supports_both_engines(self):
        whisper = runtime_status(engine="whisper")
        funasr = runtime_status(engine="funasr")

        self.assertEqual(whisper["engine"], "whisper")
        self.assertEqual(funasr["engine"], "funasr")
        self.assertIn("ready_by_engine", whisper)
        self.assertIn("whisper", whisper["ready_by_engine"])
        self.assertIn("funasr", whisper["ready_by_engine"])
        self.assertIn("engine_options", whisper)
        self.assertIn("whisper", whisper["engine_options"])
        self.assertIn("funasr", whisper["engine_options"])


if __name__ == "__main__":
    unittest.main()
