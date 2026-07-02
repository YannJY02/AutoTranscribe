from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LIVE_SESSION_VIEW_MODEL = (
    ROOT
    / "macos/InsightKitApp/Sources/InsightKitApp/ViewModels/LiveSessionViewModel.swift"
)
REVIEW_MEDIA_COMPOSER = (
    ROOT
    / "macos/InsightKitApp/Sources/InsightKitApp/Services/ReviewMediaComposer.swift"
)
VIDEO_CAPTURE_SERVICE = (
    ROOT
    / "macos/InsightKitApp/Sources/InsightKitApp/Services/VideoCaptureService.swift"
)
ISSUE24_DIAGNOSTIC = ROOT / "scripts/diagnose_issue24_media_timeline.py"


def test_live_visual_review_recording_starts_after_audio_capture_is_ready():
    source = LIVE_SESSION_VIEW_MODEL.read_text(encoding="utf-8")
    start = source.index("func startLiveSession()")
    end = source.index("func stopLiveSession()", start)
    body = source[start:end]

    visual_call = "startVisualRecordingIfNeeded(meetingID: meetingID)"
    assert body.count(visual_call) == 1

    visual_index = body.index(visual_call)
    mic_capture_index = body.index("try await self.micCapture.start()")
    system_capture_index = body.index("try await self.systemAudioCapture.start(sourceID: sourceID)")
    timer_index = body.index("self.startRecordingDurationTimer()")

    assert mic_capture_index < visual_index < timer_index
    assert system_capture_index < visual_index < timer_index


def test_live_visual_review_recording_stops_before_tail_processing():
    source = LIVE_SESSION_VIEW_MODEL.read_text(encoding="utf-8")
    start = source.index("func stopLiveSession(finalState: CaptureState)")
    end = source.index("func buildFinalInsight()", start)
    body = source[start:end]

    finish_call = "self.videoCaptureService.finishRecording()"
    assert body.count(finish_call) == 1

    finish_index = body.index(finish_call)
    pipeline_index = body.index("pipelineQueue.async")
    assert finish_index < pipeline_index
    assert finish_call not in body[pipeline_index:]


def test_review_media_composer_uses_offset_aware_timeline_intersection():
    source = REVIEW_MEDIA_COMPOSER.read_text(encoding="utf-8")
    assert "ReviewMediaCompositionTimeline" in source
    assert "let intersectionStart = CMTimeMaximum(videoTimelineStart, audioTimelineStart)" in source
    assert "let intersectionEnd = CMTimeMinimum(videoTimelineEnd, audioTimelineEnd)" in source
    assert "CMTimeRange(start: sourceWindow.videoStart, duration: sourceWindow.duration)" in source
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
    assert "capture source audio/video duration delta" in source
    assert "final duration equality cannot prove visible AV sync" in source


def test_video_recording_retimes_frames_from_capture_callback_clock():
    source = VIDEO_CAPTURE_SERVICE.read_text(encoding="utf-8")
    start = source.index("fileprivate func handleVideoSampleBuffer")
    end = source.index("private func ensureWriterStarted", start)
    body = source[start:end]

    captured_at_index = body.index("let capturedAt = ProcessInfo.processInfo.systemUptime")
    writer_queue_index = body.index("writerQueue.async")
    assert captured_at_index < writer_queue_index

    assert "VideoRecordingTimeline" in body
    assert "startSession(atSourceTime: .zero)" in body
    assert "CMSampleBufferGetPresentationTimeStamp(sampleBuffer)" in body
    assert "presentationTime(" in body
    assert "videoPixelBufferAdaptor?.append(" in body
    assert "withPresentationTime: presentationTime" in body
