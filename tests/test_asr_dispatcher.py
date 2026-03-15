import unittest
from unittest import mock

from insightkit.ipc.asr_dispatcher import ASRDispatcher


class TestASRDispatcher(unittest.TestCase):
    @mock.patch("insightkit.ipc.asr_dispatcher.runtime_status", return_value={"ready": True, "engine": "funasr"})
    @mock.patch("insightkit.ipc.asr_dispatcher.runtime_backend_status", return_value={"device": "cpu", "compute_type": "int8", "resolved": True, "supported_compute_types": [], "configured_device": "cpu", "configured_compute_type": "int8"})
    @mock.patch("insightkit.ipc.asr_dispatcher.runtime_warm_status", return_value={"ready": True, "state": "warm", "in_progress": False, "attempt": 1, "last_warm_ms": 100, "last_error": ""})
    def test_runtime_status(self, mock_warm, mock_backend, mock_status):
        dispatcher = ASRDispatcher()
        result = dispatcher.asr_runtime_status({})
        self.assertTrue(result["ready"])
        self.assertIn("backend", result)
        self.assertIn("warm", result)

    @mock.patch("insightkit.ipc.asr_dispatcher.bootstrap_runtime", return_value={"ok": True})
    def test_runtime_bootstrap(self, mock_bootstrap):
        dispatcher = ASRDispatcher()
        result = dispatcher.asr_runtime_bootstrap({"model": "base"})
        self.assertTrue(result["ok"])

    @mock.patch("insightkit.ipc.asr_dispatcher.prewarm_asr", return_value={"ok": True, "backend": {"device": "cpu"}, "warm": {"ready": True}})
    def test_prewarm(self, mock_prewarm):
        dispatcher = ASRDispatcher()
        result = dispatcher.asr_prewarm({"model": "base", "timeout_sec": 10})
        self.assertTrue(result["ok"])

    @mock.patch("insightkit.ipc.asr_dispatcher.transcribe_audio_chunk", return_value=[{"start_ms": 0, "end_ms": 1000, "text": "hello"}])
    def test_transcribe_chunk(self, mock_transcribe):
        dispatcher = ASRDispatcher()
        result = dispatcher.asr_transcribe_chunk({"wav_path": "/tmp/test.wav", "offset_ms": 0, "source": "mic"})
        self.assertEqual(len(result["segments"]), 1)
        self.assertEqual(result["segments"][0]["source"], "mic")

    def test_transcribe_chunk_requires_wav_path(self):
        dispatcher = ASRDispatcher()
        with self.assertRaises(ValueError):
            dispatcher.asr_transcribe_chunk({"wav_path": ""})


if __name__ == "__main__":
    unittest.main()
