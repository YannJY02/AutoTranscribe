import Foundation

protocol LiveReviewAudioPreparing {
    @discardableResult
    func flush(minDurationSec: Double) throws -> [AudioChunk]
    func hasAudibleContent(minimumRMS: Float) -> Bool
    func writeCombinedWAV(to outputURL: URL) -> URL?
}

extension ChunkAssembler: LiveReviewAudioPreparing {}

struct LiveSessionReviewMediaPreparationSnapshot {
    let meetingID: String
    let capturedVideoURL: URL?
    let expectedVisualMedia: Bool
    let captureTimeline: LiveMediaCaptureTimeline
}

struct LiveSessionReviewMediaPreparationOutcome: Equatable {
    let recordingURL: URL?
    let mediaURL: URL?
    let reviewSourceMediaURL: URL?
    let recordingStatusMessage: String?
    let reviewSourceStatusMessage: String?
}

final class LiveSessionReviewMediaPreparer {
    private let audioPreparer: LiveReviewAudioPreparing
    private let mediaAssetInspector: MediaAssetInspecting
    private let reviewMediaComposer: ReviewMediaComposing

    init(
        audioPreparer: LiveReviewAudioPreparing,
        mediaAssetInspector: MediaAssetInspecting,
        reviewMediaComposer: ReviewMediaComposing
    ) {
        self.audioPreparer = audioPreparer
        self.mediaAssetInspector = mediaAssetInspector
        self.reviewMediaComposer = reviewMediaComposer
    }

    func prepare(_ snapshot: LiveSessionReviewMediaPreparationSnapshot) -> LiveSessionReviewMediaPreparationOutcome {
        if let videoURL = usableVideoRecordingURL(snapshot.capturedVideoURL) {
            return prepareVideoReviewMedia(videoURL: videoURL, snapshot: snapshot)
        }

        guard let recordingURL = prepareAudibleReviewSource(meetingID: snapshot.meetingID) else {
            return LiveSessionReviewMediaPreparationOutcome(
                recordingURL: nil,
                mediaURL: nil,
                reviewSourceMediaURL: nil,
                recordingStatusMessage: "录音太短或未捕获到可保存音频，已保留转写与笔记；请检查输入源后重新录制。",
                reviewSourceStatusMessage: "本次没有可播放音频。请检查麦克风或系统音频输入。"
            )
        }

        return LiveSessionReviewMediaPreparationOutcome(
            recordingURL: recordingURL,
            mediaURL: recordingURL,
            reviewSourceMediaURL: recordingURL,
            recordingStatusMessage: snapshot.expectedVisualMedia
                ? "未保存到视频画面，回看将使用音频、转写与笔记。请检查摄像头或屏幕录制权限后重试。"
                : nil,
            reviewSourceStatusMessage: nil
        )
    }

    static func captureTimelineSidecarURL(meetingID: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InsightKit")
            .appendingPathComponent(meetingID)
            .appendingPathComponent("capture_timeline.json")
    }

    private func prepareVideoReviewMedia(
        videoURL: URL,
        snapshot: LiveSessionReviewMediaPreparationSnapshot
    ) -> LiveSessionReviewMediaPreparationOutcome {
        if mediaAssetInspector.hasAudioTrack(url: videoURL) {
            return LiveSessionReviewMediaPreparationOutcome(
                recordingURL: videoURL,
                mediaURL: videoURL,
                reviewSourceMediaURL: videoURL,
                recordingStatusMessage: nil,
                reviewSourceStatusMessage: nil
            )
        }

        let reviewAudioURL = prepareAudibleReviewSource(meetingID: snapshot.meetingID)
        let compositionTimeline = snapshot.captureTimeline.compositionTimeline
        let composedVideoURL = reviewAudioURL.flatMap { audioURL -> URL? in
            do {
                let outputURL = composedReviewVideoURL(meetingID: snapshot.meetingID)
                let composedURL = try reviewMediaComposer.composeVideoWithAudio(
                    videoURL: videoURL,
                    audioURL: audioURL,
                    outputURL: outputURL,
                    timeline: compositionTimeline
                )
                writeCaptureTimelineSidecar(
                    meetingID: snapshot.meetingID,
                    captureTimeline: snapshot.captureTimeline,
                    videoURL: videoURL,
                    audioURL: audioURL,
                    outputURL: composedURL,
                    compositionTimeline: compositionTimeline
                )
                return composedURL
            } catch {
                return nil
            }
        }

        let reviewURL = composedVideoURL ?? videoURL
        let recordingStatusMessage: String?
        let reviewSourceStatusMessage: String?
        if reviewAudioURL != nil, composedVideoURL == nil {
            let message = "视频回看已保存，但音频合成失败；本次回看可能没有声音。"
            recordingStatusMessage = message
            reviewSourceStatusMessage = message
        } else if composedVideoURL != nil {
            recordingStatusMessage = nil
            reviewSourceStatusMessage = nil
        } else if snapshot.expectedVisualMedia {
            let message = "视频回看已保存，但本次没有可播放音频。请检查麦克风或系统音频输入。"
            recordingStatusMessage = message
            reviewSourceStatusMessage = message
        } else {
            recordingStatusMessage = nil
            reviewSourceStatusMessage = nil
        }

        return LiveSessionReviewMediaPreparationOutcome(
            recordingURL: reviewURL,
            mediaURL: reviewURL,
            reviewSourceMediaURL: reviewURL,
            recordingStatusMessage: recordingStatusMessage,
            reviewSourceStatusMessage: reviewSourceStatusMessage
        )
    }

    private func prepareAudibleReviewSource(meetingID: String) -> URL? {
        _ = try? audioPreparer.flush(minDurationSec: 0.1)
        guard audioPreparer.hasAudibleContent(minimumRMS: 0.001) else {
            return nil
        }
        return audioPreparer.writeCombinedWAV(to: combinedWAVURL(meetingID: meetingID))
    }

    private func usableVideoRecordingURL(_ url: URL?) -> URL? {
        guard let url else { return nil }
        let ext = url.pathExtension.lowercased()
        guard ["mp4", "mov", "mkv"].contains(ext) else { return nil }
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              (values.fileSize ?? 0) > 0 else {
            return nil
        }
        guard mediaAssetInspector.durationSec(url: url) != nil else {
            return nil
        }
        return url
    }

    private func combinedWAVURL(meetingID: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InsightKit")
            .appendingPathComponent(meetingID)
            .appendingPathComponent("recording.wav")
    }

    private func composedReviewVideoURL(meetingID: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InsightKit")
            .appendingPathComponent(meetingID)
            .appendingPathComponent("recording-with-audio.mp4")
    }

    private func writeCaptureTimelineSidecar(
        meetingID: String,
        captureTimeline: LiveMediaCaptureTimeline,
        videoURL: URL,
        audioURL: URL,
        outputURL: URL,
        compositionTimeline: ReviewMediaCompositionTimeline
    ) {
        let sidecar = LiveMediaCaptureTimelineSidecar(
            videoStartSec: captureTimeline.videoStartSec,
            audioStartSec: captureTimeline.audioStartSec,
            pauseIntervals: captureTimeline.pauseIntervals,
            currentPauseStartSec: captureTimeline.currentPauseStartSec,
            compositionTimeline: compositionTimeline,
            videoPath: videoURL.path,
            audioPath: audioURL.path,
            outputPath: outputURL.path
        )
        do {
            let url = Self.captureTimelineSidecarURL(meetingID: meetingID)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(sidecar)
            try data.write(to: url, options: .atomic)
        } catch {
            // Best-effort diagnostics only.
        }
    }
}

struct LiveMediaCaptureTimelineSidecar: Codable {
    let videoStartSec: TimeInterval?
    let audioStartSec: TimeInterval?
    let pauseIntervals: [LiveMediaCapturePauseInterval]
    let currentPauseStartSec: TimeInterval?
    let compositionTimeline: ReviewMediaCompositionTimeline
    let videoPath: String
    let audioPath: String
    let outputPath: String
}

struct LiveSessionFinalizationSnapshot {
    let meetingID: String
    let capturedSegments: [TranscriptSegment]
    let insightPackage: InsightPackageV1?
    let recordingURL: URL?
    let durationSec: Double
    let notes: [TimestampedNote]
    let analysisMeta: [String: Any]?
    let cachedFinalTranscript: [TranscriptSegment]?
    let presentationStatus: LivePresentationCaptureStatus?
    let finalizationLeaseToken: String?

    init(
        meetingID: String,
        capturedSegments: [TranscriptSegment],
        insightPackage: InsightPackageV1?,
        recordingURL: URL?,
        durationSec: Double,
        notes: [TimestampedNote],
        analysisMeta: [String: Any]?,
        cachedFinalTranscript: [TranscriptSegment]?,
        presentationStatus: LivePresentationCaptureStatus? = nil,
        finalizationLeaseToken: String? = nil
    ) {
        self.meetingID = meetingID
        self.capturedSegments = capturedSegments
        self.insightPackage = insightPackage
        self.recordingURL = recordingURL
        self.durationSec = durationSec
        self.notes = notes
        self.analysisMeta = analysisMeta
        self.cachedFinalTranscript = cachedFinalTranscript
        self.presentationStatus = presentationStatus
        self.finalizationLeaseToken = finalizationLeaseToken
    }
}

enum LiveSessionFinalizationTranscriptState: Equatable {
    case mediaTimed
    case missingRecoverable
    case liveTranscriptOnly
}

struct LiveSessionFinalizationOutcome {
    let recordPath: String
    let transcriptSegments: [TranscriptSegment]
    let transcriptState: LiveSessionFinalizationTranscriptState
    let recoveryAvailable: Bool
    let statusMessage: String?
}

final class LiveSessionFinalizer {
    private let finalMediaTranscriber: FinalMediaTranscribing
    private let runtimeTranscriptReplacementAction: RuntimeTranscriptReplacementActioning
    private let recordSaveAction: RecordSaveActioning
    private let retryDelays: [TimeInterval]

    init(
        finalMediaTranscriber: FinalMediaTranscribing,
        runtimeTranscriptReplacementAction: RuntimeTranscriptReplacementActioning,
        recordSaveAction: RecordSaveActioning,
        retryDelays: [TimeInterval]
    ) {
        self.finalMediaTranscriber = finalMediaTranscriber
        self.runtimeTranscriptReplacementAction = runtimeTranscriptReplacementAction
        self.recordSaveAction = recordSaveAction
        self.retryDelays = retryDelays
    }

    func finalize(_ snapshot: LiveSessionFinalizationSnapshot) throws -> LiveSessionFinalizationOutcome {
        let finalTranscript = finalTranscriptForRecord(snapshot)
        if snapshot.recordingURL != nil {
            replaceRuntimeTranscript(meetingID: snapshot.meetingID, segments: finalTranscript.segments)
        }

        let recordPath = try recordSaveAction.saveRecord(RecordSaveActionRequest(
            meetingID: snapshot.meetingID,
            title: "直播洞察",
            sourcePath: snapshot.recordingURL?.path ?? "",
            segments: Self.recordRows(from: finalTranscript.segments),
            insightPackage: try Self.insightPackageDictionary(snapshot.insightPackage),
            mediaType: Self.mediaType(for: snapshot.recordingURL),
            recordSource: "live",
            durationSec: snapshot.durationSec,
            analysisMeta: snapshot.analysisMeta,
            notesMD: NotesFileIO.serialize(snapshot.notes),
            presentationStatus: snapshot.presentationStatus,
            finalizationLeaseToken: snapshot.finalizationLeaseToken
        )).get().recordPath

        return LiveSessionFinalizationOutcome(
            recordPath: recordPath,
            transcriptSegments: finalTranscript.segments,
            transcriptState: finalTranscript.state,
            recoveryAvailable: finalTranscript.state == .missingRecoverable,
            statusMessage: finalTranscript.statusMessage
        )
    }

    private func finalTranscriptForRecord(
        _ snapshot: LiveSessionFinalizationSnapshot
    ) -> (
        segments: [TranscriptSegment],
        state: LiveSessionFinalizationTranscriptState,
        statusMessage: String?
    ) {
        guard let recordingURL = snapshot.recordingURL else {
            return (snapshot.capturedSegments, .liveTranscriptOnly, nil)
        }
        if let cached = snapshot.cachedFinalTranscript {
            return finalTranscriptResult(from: cached)
        }

        do {
            let segments = try transcribeFinalMediaWithRetry(mediaPath: recordingURL.path)
            return finalTranscriptResult(from: segments)
        } catch {
            return (
                [],
                .missingRecoverable,
                "最终回看资料转写暂未完成；已保留媒体和笔记，可稍后重新生成。"
            )
        }
    }

    private func finalTranscriptResult(
        from segments: [TranscriptSegment]
    ) -> (
        segments: [TranscriptSegment],
        state: LiveSessionFinalizationTranscriptState,
        statusMessage: String?
    ) {
        if segments.isEmpty {
            return (
                [],
                .missingRecoverable,
                "最终回看资料没有产生可保存转写；已保留媒体和笔记，可稍后重新生成。"
            )
        }
        return (segments, .mediaTimed, nil)
    }

    private func transcribeFinalMediaWithRetry(mediaPath: String) throws -> [TranscriptSegment] {
        var lastError: Error?
        for attempt in 0...retryDelays.count {
            do {
                return try finalMediaTranscriber.transcribeFinalMedia(mediaPath: mediaPath, source: "media")
            } catch {
                lastError = error
                guard attempt < retryDelays.count else { break }
                let delay = max(0, retryDelays[attempt])
                if delay > 0 {
                    Thread.sleep(forTimeInterval: delay)
                }
            }
        }
        throw lastError ?? NSError(
            domain: "InsightKit.LiveSessionFinalizer",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "最终媒体转写失败"]
        )
    }

    private func replaceRuntimeTranscript(meetingID: String, segments: [TranscriptSegment]) {
        _ = try? runtimeTranscriptReplacementAction.replaceRuntimeTranscript(
            RuntimeTranscriptReplacementActionRequest(
                meetingID: meetingID,
                segments: segments.map(Self.rpcDelta)
            )
        ).get()
    }

    private static func recordRows(from segments: [TranscriptSegment]) -> [[String: Any]] {
        segments.map { segment in
            [
                "start_ms": segment.startMs,
                "end_ms": segment.endMs,
                "speaker": segment.speaker,
                "source": segment.source,
                "text": segment.text,
            ]
        }
    }

    private static func rpcDelta(from segment: TranscriptSegment) -> RPCSegmentDelta {
        RPCSegmentDelta(
            startMs: segment.startMs,
            endMs: segment.endMs,
            speaker: segment.speaker == "未标注" ? "" : segment.speaker,
            text: segment.text,
            confidence: 0.0,
            source: segment.source
        )
    }

    private static func mediaType(for url: URL?) -> String {
        guard let url else { return "audio" }
        let ext = url.pathExtension.lowercased()
        return ["mp4", "mov", "mkv", "avi", "webm"].contains(ext) ? "video" : "audio"
    }

    private static func insightPackageDictionary(_ package: InsightPackageV1?) throws -> [String: Any]? {
        guard let package else { return nil }
        let data = try JSONEncoder().encode(package)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
