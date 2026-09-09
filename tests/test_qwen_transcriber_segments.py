from types import SimpleNamespace

from scripts.transcriber import _qwen_segments_from_result


def test_live_qwen_keeps_aligned_words_without_running_diarization(monkeypatch, tmp_path):
    from scripts import transcriber

    class Session:
        def transcribe(self, **kwargs):
            assert kwargs["diarize"] is False
            assert kwargs["return_timestamps"] is True
            return SimpleNamespace(language="en", segments=[
                dict(start=0.0, end=0.4, text="hello"), dict(start=0.5, end=1.0, text="there"),
            ])

    monkeypatch.setattr(transcriber, "_engine", lambda: transcriber.QWEN_MLX_ENGINE)
    monkeypatch.setattr(transcriber, "_speech_exists", lambda _: True)
    monkeypatch.setattr(transcriber, "_load_qwen_mlx_session", Session)
    monkeypatch.setattr(transcriber, "_resolve_qwen_forced_aligner_source", lambda: None)
    monkeypatch.setattr(transcriber, "_attach_diarization_labels", lambda *args: (_ for _ in ()).throw(AssertionError("foreground diarization")))
    audio = tmp_path / "test.wav"
    audio.touch()
    segments = transcriber.transcribe_audio_chunk(audio, 2000, attach_diarization=False, preserve_words=True)
    assert segments[0]["text"] == "hello there"
    assert segments[0]["_words"] == [dict(start_ms=2000, end_ms=2400, text="hello"), dict(start_ms=2500, end_ms=3000, text="there")]


def test_qwen_word_timestamps_take_priority_over_coarse_chunks():
    result = SimpleNamespace(
        speaker_segments=None,
        chunks=[{"start": 0.0, "end": 30.0, "text": "coarse full clip"}],
        segments=[
            {"start": 0.0, "end": 1.0, "text": "hello"},
            {"start": 1.2, "end": 2.0, "text": "there"},
            {"start": 10.0, "end": 11.0, "text": "again"},
        ],
        text="hello there again",
    )

    segments = _qwen_segments_from_result(result)

    assert len(segments) == 2
    assert segments[0]["start"] == 0
    assert segments[0]["end"] == 2000
    assert segments[0]["text"] == "hello there"
    assert segments[1]["start"] == 10000
    assert segments[1]["text"] == "again"


def test_qwen_chinese_speaker_segments_drop_character_spacing():
    result = SimpleNamespace(
        speaker_segments=[
            {
                "start": 0.0,
                "end": 2.0,
                "speaker": "SPEAKER_00",
                "text": "第 一 位 说 话 人 mixed speech",
            }
        ],
        chunks=[],
        segments=[],
        text="",
    )

    segments = _qwen_segments_from_result(result)

    assert segments == [
        {
            "start": 0,
            "end": 2000,
            "text": "第一位说话人 mixed speech",
            "speaker": "SPEAKER_00",
            "confidence": 0.0,
        }
    ]
