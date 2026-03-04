import subprocess
import tempfile
import unittest
from pathlib import Path


class TestLiveChunkRealMode(unittest.TestCase):
    def test_mock_flag_removed(self):
        with tempfile.TemporaryDirectory() as tmp:
            wav = Path(tmp) / "chunk.wav"
            wav.write_bytes(b"RIFF----WAVE")
            proc = subprocess.run(
                ["python3", "scripts/live_chunk_asr.py", "--wav", str(wav), "--mock"],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("unrecognized arguments: --mock", proc.stderr)


if __name__ == "__main__":
    unittest.main()
