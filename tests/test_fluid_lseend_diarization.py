from types import SimpleNamespace

from scripts import transcriber


def test_parse_fluid_lseend_spans_normalizes_speaker_labels():
    payload = {
        "segments": [
            {"speaker": "Speaker 1", "startTimeSeconds": 1.2, "endTimeSeconds": 2.4},
            {"speakerIndex": 0, "startTimeSeconds": 0.0, "endTimeSeconds": 1.0},
            {"speaker": "bad", "startTimeSeconds": 3.0, "endTimeSeconds": 2.0},
        ]
    }

    assert transcriber._parse_fluid_lseend_spans(payload) == [
        (0, 1000, "SPEAKER_00"),
        (1200, 2400, "SPEAKER_01"),
    ]


def test_apply_speaker_spans_only_fills_missing_labels():
    segments = [
        {"start": 0, "end": 900, "text": "a", "speaker": ""},
        {"start": 1200, "end": 2000, "text": "b", "speaker": "kept"},
    ]
    spans = [(0, 1000, "SPEAKER_00"), (1100, 2100, "SPEAKER_01")]

    updated = transcriber._apply_speaker_spans(segments, spans)

    assert updated[0]["speaker"] == "SPEAKER_00"
    assert updated[1]["speaker"] == "kept"
    assert segments[0]["speaker"] == ""


def test_default_diarize_uses_fluid_lseend_not_pyannote(monkeypatch, tmp_path):
    monkeypatch.setattr(transcriber, "DIARIZATION_ENABLED", True)
    monkeypatch.setattr(transcriber, "DIARIZATION_ENGINE", "fluid-lseend")
    monkeypatch.setattr(transcriber, "_diarize_fluid_lseend", lambda _: [(0, 1000, "SPEAKER_00")])

    def fail_pyannote():
        raise AssertionError("pyannote should not be loaded for the default fluid-lseend path")

    monkeypatch.setattr(transcriber, "_load_diarization_pipeline", fail_pyannote)

    assert transcriber._diarize(tmp_path / "audio.wav") == [(0, 1000, "SPEAKER_00")]


def test_qwen_uses_external_fluid_labels_without_builtin_pyannote(monkeypatch, tmp_path):
    calls = {}

    class FakeSession:
        def transcribe(self, **kwargs):
            calls.update(kwargs)
            return SimpleNamespace(
                language="en",
                speaker_segments=[],
                chunks=[],
                segments=[
                    {"start": 0.0, "end": 1.0, "text": "hello"},
                    {"start": 1.2, "end": 2.0, "text": "there"},
                ],
                text="hello there",
            )

    audio = tmp_path / "chunk.wav"
    audio.write_bytes(b"not actually decoded")
    monkeypatch.setattr(transcriber, "DIARIZATION_ENABLED", True)
    monkeypatch.setattr(transcriber, "DIARIZATION_ENGINE", "fluid-lseend")
    monkeypatch.setattr(transcriber, "QWEN_MLX_RETURN_TIMESTAMPS", True)
    monkeypatch.setattr(transcriber, "_speech_exists", lambda _: True)
    monkeypatch.setattr(transcriber, "_load_qwen_mlx_session", lambda: FakeSession())
    monkeypatch.setattr(transcriber, "_resolve_qwen_forced_aligner_source", lambda: None)
    monkeypatch.setattr(transcriber, "_diarize", lambda _: [(0, 2500, "SPEAKER_00")])

    lang, segments = transcriber._transcribe_qwen_mlx(audio)

    assert lang == "en"
    assert calls["diarize"] is False
    assert all(seg["speaker"] == "SPEAKER_00" for seg in segments)
