import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


class TestLiveChunkASRScript(unittest.TestCase):
    def test_strict_mode_without_model_path_returns_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            wav = Path(tmp) / "chunk.wav"
            wav.write_bytes(b"RIFF----WAVE")

            proc = subprocess.run(
                [
                    "python3",
                    "scripts/live_chunk_asr.py",
                    "--wav",
                    str(wav),
                    "--offset-ms",
                    "2400",
                ],
                capture_output=True,
                text=True,
                check=False,
                env={
                    **os.environ,
                    "INSIGHTKIT_ASR_MODEL_PATH": str(Path(tmp) / "missing-model"),
                    "INSIGHTKIT_ASR_STRICT_LOCAL_ONLY": "1",
                },
            )
            self.assertNotEqual(proc.returncode, 0)
            payload = json.loads(proc.stdout or "{}")
            self.assertIn("segments", payload)
            self.assertEqual(payload["segments"], [])
            self.assertIn("error", payload)


if __name__ == "__main__":
    unittest.main()
