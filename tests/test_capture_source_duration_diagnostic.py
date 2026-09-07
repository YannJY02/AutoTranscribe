"""A valid composition intersection must not hide lost recording time."""

import importlib.util
from pathlib import Path


_SPEC = importlib.util.spec_from_file_location(
    "capture_duration_diagnostic",
    Path(__file__).resolve().parents[1] / "scripts/diagnose_issue24_media_timeline.py",
)
diagnostic = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(diagnostic)


def _inspect(tmp_path, monkeypatch, *, video_duration, audio_duration, pauses=(),
             video_start=0.0, audio_start=0.0, final_duration=None):
    video = tmp_path / "video.mp4"
    audio = tmp_path / "audio.wav"
    video.touch()
    audio.touch()

    def probe(path, _ffprobe):
        kind, duration = (
            ("video", video_duration) if path == video else ("audio", audio_duration)
        )
        return {
            "streams": [{"codec_type": kind, "duration": str(duration)}],
            "format": {"duration": str(duration)},
        }

    monkeypatch.setattr(diagnostic, "ffprobe_media", probe)
    return diagnostic.inspect_capture_sources(
        {
            "videoPath": str(video),
            "audioPath": str(audio),
            "compositionTimeline": {
                "videoStartSec": video_start,
                "audioStartSec": audio_start,
                "videoPauseIntervals": list(pauses),
            },
        },
        "ffprobe",
        audio_duration if final_duration is None else final_duration,
        2.0,
        2.0,
    )


def test_matching_intersection_cannot_pass_a_truncated_recording(tmp_path, monkeypatch):
    report, _, failures = _inspect(
        tmp_path, monkeypatch, video_duration=60.658333, audio_duration=26.0
    )

    assert report["composition_window_final_delta_sec"] == 0
    assert any("source audio/video duration delta" in failure for failure in failures)
    assert any("source video duration differs from final media" in failure for failure in failures)


def test_recorded_pause_explains_source_video_length(tmp_path, monkeypatch):
    report, _, failures = _inspect(
        tmp_path,
        monkeypatch,
        video_duration=60.0,
        audio_duration=26.0,
        pauses=({"startSec": 10.0, "endSec": 44.0},),
    )

    assert failures == []
    assert report["source_duration_delta_explained_by_pause"] is True
    assert report["video_source_final_delta_explained_by_pause"] is True


def test_matching_complete_sources_pass(tmp_path, monkeypatch):
    _, warnings, failures = _inspect(
        tmp_path, monkeypatch, video_duration=60.0, audio_duration=60.0
    )

    assert warnings == []
    assert failures == []


def test_delayed_video_start_with_matching_source_ends_passes(tmp_path, monkeypatch):
    _, _, failures = _inspect(
        tmp_path, monkeypatch, video_duration=60.0, audio_duration=63.0,
        video_start=3.0, final_duration=60.0,
    )
    assert failures == []


def test_delayed_audio_start_can_explain_trimmed_video_prefix(tmp_path, monkeypatch):
    _, _, failures = _inspect(
        tmp_path, monkeypatch, video_duration=63.0, audio_duration=60.0,
        audio_start=3.0,
    )
    assert failures == []


def test_start_offset_cannot_explain_missing_audio_tail(tmp_path, monkeypatch):
    _, _, failures = _inspect(
        tmp_path, monkeypatch, video_duration=63.0, audio_duration=26.0,
        audio_start=3.0,
    )
    assert any("source audio/video duration delta" in failure for failure in failures)
    assert any("source video duration differs from final media" in failure for failure in failures)
