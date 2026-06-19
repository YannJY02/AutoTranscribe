from types import SimpleNamespace

from scripts.transcriber import _qwen_segments_from_result


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
