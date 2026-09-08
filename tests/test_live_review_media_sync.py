from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REVIEW_MEDIA_COMPOSER = (
    ROOT
    / "macos/InsightKitApp/Sources/InsightKitApp/Services/ReviewMediaComposer.swift"
)
ISSUE24_DIAGNOSTIC = ROOT / "scripts/diagnose_issue24_media_timeline.py"


def test_review_media_composer_uses_offset_aware_timeline_intersection():
    source = REVIEW_MEDIA_COMPOSER.read_text(encoding="utf-8")
    assert "ReviewMediaCompositionTimeline" in source
    assert "videoPauseIntervals" in source
    assert "activeVideoSourceRanges" in source
    assert "videoSegments(" in source
    assert "insertTimeRange(segment.sourceRange" in source
    assert "CMTimeRange(start: sourceWindow.audioStart, duration: sourceWindow.duration)" in source
    assert "CMTimeRange(start: .zero, duration: timelineDuration)" not in source
    assert "insertEmptyTimeRange" not in source


def test_issue24_diagnostic_checks_capture_source_timeline_not_only_final_media():
    source = ISSUE24_DIAGNOSTIC.read_text(encoding="utf-8")
    assert "--max-source-stream-delta-sec" in source
    assert "videoPath" in source
    assert "audioPath" in source
    assert "pauseIntervals" in source
    assert "pause_interval_count" in source
    assert "pause_adjusted_video_duration_sec" in source
    assert "capture source audio/video duration delta" in source
    assert "final duration equality cannot prove visible AV sync" in source
