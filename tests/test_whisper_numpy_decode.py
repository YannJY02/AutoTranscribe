from __future__ import annotations

import wave
from pathlib import Path

import numpy as np

from scripts import transcriber


def _write_test_wav(path: Path) -> None:
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(16_000)
        wf.writeframes(b"\x00\x00" * 160)


def test_load_wav_mono_float32_returns_samples(tmp_path):
    wav = tmp_path / "sample.wav"
    _write_test_wav(wav)

    samples = transcriber._load_wav_mono_float32(wav)  # noqa: SLF001

    assert isinstance(samples, np.ndarray)
    assert samples.dtype == np.float32
    assert samples.shape == (160,)


def test_transcribe_whisper_passes_numpy_audio_to_model(monkeypatch, tmp_path):
    wav = tmp_path / "sample.wav"
    _write_test_wav(wav)
    captured = {}

    class Segment:
        text = "hello"
        start = 0.0
        end = 1.0
        avg_logprob = 0.0

    class Info:
        language = "en"

    class Model:
        def transcribe(self, audio, **_kwargs):
            captured["audio"] = audio
            return iter([Segment()]), Info()

    monkeypatch.setattr(transcriber, "_speech_exists", lambda _path: True)
    monkeypatch.setattr(transcriber, "_load_whisper_model", lambda: Model())
    monkeypatch.setattr(transcriber, "_diarize", lambda _path: [(0, 1000, "SPEAKER_00")])

    language, segments = transcriber._transcribe_whisper(wav)  # noqa: SLF001

    assert language == "en"
    assert isinstance(captured["audio"], np.ndarray)
    assert segments[0]["speaker"] == "SPEAKER_00"
