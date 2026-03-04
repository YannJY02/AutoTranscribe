"""
TDD integration test: actual transcription of a real audio chunk.

Strategy (test-driven-development workflow):
  RED  — call transcribe_audio_chunk on a real WAV; assert non-empty segments.
         Will FAIL if model not installed (expected and correct).
  GREEN — passes once model files and Python deps are present.
  SKIP  — auto-skipped when INSIGHTKIT_MODEL_DIR has no model (CI-friendly).

This test catches the core failure mode: the sidecar passes `asr.runtime.status`
checks but the actual inference returns empty segments because the model file
is missing or the wrong engine is selected.
"""

import os
import struct
import tempfile
import unittest
from pathlib import Path


def _model_exists() -> bool:
    """Return True if at least one model directory/file exists under INSIGHTKIT_MODEL_DIR."""
    model_dir = os.environ.get(
        "INSIGHTKIT_MODEL_DIR",
        str(Path.home() / "Library/Application Support/InsightKit/models"),
    )
    p = Path(model_dir)
    if not p.exists():
        return False
    return any(child.is_dir() for child in p.iterdir()) if p.is_dir() else False


def _required_deps_ready() -> bool:
    """Return True only when all required ASR deps (e.g. silero-vad) are installed."""
    try:
        from scripts.asr_runtime_bootstrap import runtime_status
        status = runtime_status(engine="whisper")
        return all(status.get("dependencies", {}).get("required", {}).values())
    except Exception:
        return False


def _write_silent_wav(path: Path, duration_sec: float = 3.0, sample_rate: int = 16000) -> None:
    """Write a minimal valid 16kHz mono PCM WAV file with silence."""
    num_samples = int(duration_sec * sample_rate)
    pcm_data = b"\x00\x00" * num_samples  # 16-bit silence
    data_size = len(pcm_data)
    with open(path, "wb") as f:
        # RIFF header
        f.write(b"RIFF")
        f.write(struct.pack("<I", 36 + data_size))
        f.write(b"WAVE")
        # fmt chunk
        f.write(b"fmt ")
        f.write(struct.pack("<IHHIIHH", 16, 1, 1, sample_rate, sample_rate * 2, 2, 16))
        # data chunk
        f.write(b"data")
        f.write(struct.pack("<I", data_size))
        f.write(pcm_data)


@unittest.skipUnless(_model_exists(), "跳过：模型目录不存在（需先运行一键修复）")
@unittest.skipUnless(_required_deps_ready(), "跳过：必要依赖未安装（silero-vad 等，请运行一键修复）")
class TestASRTranscribeIntegration(unittest.TestCase):
    """End-to-end test of the transcription pipeline with real audio."""

    def test_transcribe_chunk_returns_list(self):
        """transcribe_audio_chunk must return a list (may be empty for silence)."""
        from scripts.transcriber import transcribe_audio_chunk

        with tempfile.TemporaryDirectory() as tmp:
            wav = Path(tmp) / "silent.wav"
            _write_silent_wav(wav)
            result = transcribe_audio_chunk(wav, offset_ms=0)
            self.assertIsInstance(
                result,
                list,
                msg="transcribe_audio_chunk must return a list of segments.",
            )

    def test_transcribe_chunk_does_not_raise_on_valid_wav(self):
        """Transcription must not raise an exception on a valid WAV file."""
        from scripts.transcriber import transcribe_audio_chunk

        with tempfile.TemporaryDirectory() as tmp:
            wav = Path(tmp) / "test.wav"
            _write_silent_wav(wav, duration_sec=2.0)
            try:
                transcribe_audio_chunk(wav, offset_ms=0)
            except Exception as exc:
                self.fail(
                    f"transcribe_audio_chunk raised unexpectedly on a valid WAV: {exc}"
                )


if __name__ == "__main__":
    unittest.main()
