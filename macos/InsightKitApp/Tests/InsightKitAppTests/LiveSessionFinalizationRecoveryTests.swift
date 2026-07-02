import XCTest
@testable import InsightKitApp

final class LiveSessionFinalizationRecoveryTests: XCTestCase {
    private var recordDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        recordDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("InsightKitFinalizationRecoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: recordDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let recordDir {
            try? FileManager.default.removeItem(at: recordDir)
        }
        try super.tearDownWithError()
    }

    func testFinalizerSavesMediaTimedTranscriptAndReplacesRuntimeTranscript() throws {
        let mediaURL = try seedMedia()
        let finalSegment = TranscriptSegment(
            startMs: 2_000,
            endMs: 4_000,
            speaker: "SPEAKER_00",
            source: "media",
            text: "final transcript"
        )
        let transcriber = FinalMediaTranscribingStub(results: [.success([finalSegment])])
        let replacement = RuntimeTranscriptReplacementActionStub()
        let save = RecordSaveActionStub(recordPath: recordDir.path)
        let finalizer = LiveSessionFinalizer(
            finalMediaTranscriber: transcriber,
            runtimeTranscriptReplacementAction: replacement,
            recordSaveAction: save,
            retryDelays: []
        )

        let outcome = try finalizer.finalize(LiveSessionFinalizationSnapshot(
            meetingID: "live-finalizer-success",
            capturedSegments: [
                TranscriptSegment(startMs: 0, endMs: 1_000, speaker: "live", source: "mic", text: "stale live")
            ],
            insightPackage: nil,
            recordingURL: mediaURL,
            durationSec: 12,
            notes: [TimestampedNote(text: "saved note", timestamp: 3)],
            analysisMeta: ["provider": "mock"],
            cachedFinalTranscript: nil
        ))

        XCTAssertEqual(outcome.transcriptState, .mediaTimed)
        XCTAssertFalse(outcome.recoveryAvailable)
        XCTAssertEqual(transcriber.calls.map(\.mediaPath), [mediaURL.path])
        XCTAssertEqual(replacement.requests.first?.segments.map(\.text), ["final transcript"])
        XCTAssertEqual(save.requests.first?.segments.first?["text"] as? String, "final transcript")
        XCTAssertTrue(save.requests.first?.notesMD.contains("00:03 saved note") == true)
    }

    func testFinalizerSavesRecoverablePartialRecordWhenFinalTranscriptionFails() throws {
        let mediaURL = try seedMedia()
        let transcriber = FinalMediaTranscribingStub(results: [
            .failure(TestFailure.planned),
        ])
        let replacement = RuntimeTranscriptReplacementActionStub()
        let save = RecordSaveActionStub(recordPath: recordDir.path)
        let finalizer = LiveSessionFinalizer(
            finalMediaTranscriber: transcriber,
            runtimeTranscriptReplacementAction: replacement,
            recordSaveAction: save,
            retryDelays: []
        )

        let outcome = try finalizer.finalize(LiveSessionFinalizationSnapshot(
            meetingID: "live-finalizer-partial",
            capturedSegments: [
                TranscriptSegment(startMs: 0, endMs: 1_000, speaker: "live", source: "mic", text: "do not save stale live")
            ],
            insightPackage: nil,
            recordingURL: mediaURL,
            durationSec: 12,
            notes: [TimestampedNote(text: "partial note", timestamp: 5)],
            analysisMeta: nil,
            cachedFinalTranscript: nil
        ))

        XCTAssertEqual(outcome.transcriptState, .missingRecoverable)
        XCTAssertTrue(outcome.recoveryAvailable)
        XCTAssertTrue(outcome.transcriptSegments.isEmpty)
        XCTAssertEqual(replacement.requests.first?.segments.count, 0)
        XCTAssertEqual(save.requests.first?.segments.count, 0)
        XCTAssertTrue(save.requests.first?.notesMD.contains("00:05 partial note") == true)
    }

    func testTranscriptRecoveryWritesRecoveredTranscriptAndPreservesNotesAndMinutes() throws {
        try seedMetadata()
        let mediaURL = try seedMedia()
        try "00:02 owner note".write(to: recordDir.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        try seedInsightPackage()
        let recovered = TranscriptSegment(
            startMs: 2_000,
            endMs: 3_500,
            speaker: "SPEAKER_01",
            source: "media-recovery",
            text: "recovered official transcript"
        )
        let service = TranscriptRecoveryService(action: TranscriptRecoveryActionStub(result: .success([recovered])))

        let result = try service.recoverTranscript(recordPath: recordDir, duration: 20)

        XCTAssertEqual(result.mediaURL, mediaURL)
        XCTAssertEqual(result.segments.map(\.text), ["recovered official transcript"])
        XCTAssertTrue(result.smartMinutesMayNeedRegeneration)
        XCTAssertEqual(result.health.transcript.state, .available)
        let transcriptJSON = try String(contentsOf: recordDir.appendingPathComponent("transcript.json"), encoding: .utf8)
        XCTAssertTrue(transcriptJSON.contains("recovered official transcript"))
        let notes = try String(contentsOf: recordDir.appendingPathComponent("notes.md"), encoding: .utf8)
        XCTAssertTrue(notes.contains("owner note"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordDir.appendingPathComponent("insight_package.json").path))
    }

    func testTranscriptRecoveryFailurePreservesExistingOfficialFiles() throws {
        try seedMetadata()
        try seedMedia()
        let transcriptURL = recordDir.appendingPathComponent("transcript.json")
        try "{damaged".write(to: transcriptURL, atomically: true, encoding: .utf8)
        try "00:02 keep note".write(to: recordDir.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        let originalTranscript = try String(contentsOf: transcriptURL, encoding: .utf8)
        let service = TranscriptRecoveryService(action: TranscriptRecoveryActionStub(result: .technicalFailure("planned")))

        XCTAssertThrowsError(try service.recoverTranscript(recordPath: recordDir, duration: 20))

        XCTAssertEqual(try String(contentsOf: transcriptURL, encoding: .utf8), originalTranscript)
        XCTAssertTrue(try String(contentsOf: recordDir.appendingPathComponent("notes.md"), encoding: .utf8).contains("keep note"))
    }

    func testLiveAndRecordReviewExposeTranscriptRecoveryForRecoverableRecord() throws {
        try seedMetadata()
        try seedMedia()
        let service = TranscriptRecoveryService(action: TranscriptRecoveryActionStub(result: .success([
            TranscriptSegment(startMs: 0, endMs: 1_000, speaker: "SPEAKER_00", source: "media-recovery", text: "recovered")
        ])))
        let viewModel = LiveSessionViewModel(
            rpcClient: RPCClientMock(),
            sidecarManager: SidecarManager(),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: ChunkAssembler(),
            asrService: LiveASRService(),
            transcriptRecoveryService: service
        )
        viewModel.lastExportPath = recordDir.path
        viewModel.recordingDuration = 20
        let review = RecordReviewDataSource(
            metadata: try makeMetadata(),
            rootDirectory: recordDir.deletingLastPathComponent(),
            recordPath: recordDir,
            transcriptRecoveryService: service
        )

        XCTAssertTrue(viewModel.canRecoverTranscript)
        XCTAssertTrue(review.canRecoverTranscript)
    }

    func testReviewMediaPreparerComposesVideoAudioAndWritesTimelineSidecar() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("InsightKitReviewMediaPreparerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let videoURL = tmp.appendingPathComponent("recording.mp4")
        let audioURL = tmp.appendingPathComponent("recording.wav")
        try Data("video".utf8).write(to: videoURL)
        try Data("audio".utf8).write(to: audioURL)
        let meetingID = "review-media-preparer-\(UUID().uuidString)"
        let outputRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("InsightKit")
            .appendingPathComponent(meetingID)
        defer { try? FileManager.default.removeItem(at: tmp) }
        defer { try? FileManager.default.removeItem(at: outputRoot) }

        let audioPreparer = LiveReviewAudioPreparingStub(audioURL: audioURL)
        let inspector = MediaAssetInspectorStub(hasAudioTrack: false, durationSec: 2.0)
        let composer = ReviewMediaComposerSuccessStub()
        let preparer = LiveSessionReviewMediaPreparer(
            audioPreparer: audioPreparer,
            mediaAssetInspector: inspector,
            reviewMediaComposer: composer
        )
        var timeline = LiveMediaCaptureTimeline()
        timeline.markVideoStart(at: 20)
        timeline.markAudioStartIfNeeded(at: 21.5)

        let outcome = preparer.prepare(LiveSessionReviewMediaPreparationSnapshot(
            meetingID: meetingID,
            capturedVideoURL: videoURL,
            expectedVisualMedia: true,
            captureTimeline: timeline
        ))

        let call = try XCTUnwrap(composer.calls.first)
        XCTAssertEqual(audioPreparer.flushMinDurations, [0.1])
        XCTAssertEqual(audioPreparer.audibilityThresholds, [0.001])
        XCTAssertEqual(inspector.checkedURLs, [videoURL])
        XCTAssertEqual(call.videoURL, videoURL)
        XCTAssertEqual(call.audioURL, audioURL)
        XCTAssertEqual(call.timeline.audioStartSec, 1.5, accuracy: 0.001)
        XCTAssertEqual(outcome.recordingURL, call.outputURL)
        XCTAssertEqual(outcome.mediaURL, call.outputURL)
        XCTAssertEqual(outcome.reviewSourceMediaURL, call.outputURL)
        XCTAssertNil(outcome.recordingStatusMessage)
        XCTAssertNil(outcome.reviewSourceStatusMessage)

        let sidecarURL = LiveSessionReviewMediaPreparer.captureTimelineSidecarURL(meetingID: meetingID)
        let sidecar = try JSONDecoder().decode(
            LiveMediaCaptureTimelineSidecar.self,
            from: Data(contentsOf: sidecarURL)
        )
        XCTAssertEqual(sidecar.videoPath, videoURL.path)
        XCTAssertEqual(sidecar.audioPath, audioURL.path)
        XCTAssertEqual(sidecar.outputPath, call.outputURL.path)
        XCTAssertEqual(sidecar.compositionTimeline.audioStartSec, 1.5, accuracy: 0.001)
    }

    private func seedMetadata() throws {
        let metadata = try makeMetadata()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: recordDir.appendingPathComponent("metadata.json"), options: .atomic)
    }

    private func makeMetadata() throws -> RecordMetadata {
        RecordMetadata(
            id: recordDir.lastPathComponent,
            createdAt: Date(timeIntervalSince1970: 1_779_520_000),
            duration: 20,
            mediaType: .audio,
            source: .live,
            userTags: [],
            autoTags: [],
            summaryPreview: "Recovery fixture"
        )
    }

    @discardableResult
    private func seedMedia() throws -> URL {
        let url = recordDir.appendingPathComponent("recording.wav")
        try Data("RIFF----WAVE".utf8).write(to: url)
        return url
    }

    private func seedInsightPackage() throws {
        try """
        {
          "session_overview":{"title":"Recovery","overview":"Existing minutes","topics":[]},
          "highlight_insights":[],
          "speaker_perspectives":[],
          "decision_ledger":[],
          "action_tracks":[],
          "timeline_beats":[],
          "provenance_links":[]
        }
        """.write(to: recordDir.appendingPathComponent("insight_package.json"), atomically: true, encoding: .utf8)
    }
}

private final class FinalMediaTranscribingStub: FinalMediaTranscribing {
    private var results: [Result<[TranscriptSegment], Error>]
    private(set) var calls: [(mediaPath: String, source: String)] = []

    init(results: [Result<[TranscriptSegment], Error>]) {
        self.results = results
    }

    func transcribeFinalMedia(mediaPath: String, source: String) throws -> [TranscriptSegment] {
        calls.append((mediaPath, source))
        guard !results.isEmpty else { return [] }
        return try results.removeFirst().get()
    }
}

private final class RuntimeTranscriptReplacementActionStub: RuntimeTranscriptReplacementActioning {
    private(set) var requests: [RuntimeTranscriptReplacementActionRequest] = []

    func replaceRuntimeTranscript(
        _ request: RuntimeTranscriptReplacementActionRequest
    ) -> RuntimeActionOutcome<RuntimeTranscriptReplacementActionResult> {
        requests.append(request)
        return .success(RuntimeTranscriptReplacementActionResult(replacedCount: request.segments.count))
    }
}

private final class RecordSaveActionStub: RecordSaveActioning {
    private let recordPath: String
    private(set) var requests: [RecordSaveActionRequest] = []

    init(recordPath: String) {
        self.recordPath = recordPath
    }

    func saveRecord(_ request: RecordSaveActionRequest) -> RuntimeActionOutcome<RecordSaveActionResult> {
        requests.append(request)
        return .success(RecordSaveActionResult(recordPath: recordPath))
    }
}

private final class TranscriptRecoveryActionStub: TranscriptRecoveryActioning {
    private let result: RuntimeActionOutcome<[TranscriptSegment]>

    init(result: RuntimeActionOutcome<[TranscriptSegment]>) {
        self.result = result
    }

    func recoverTranscript(_ request: TranscriptRecoveryActionRequest) -> RuntimeActionOutcome<[TranscriptSegment]> {
        result
    }
}

private final class LiveReviewAudioPreparingStub: LiveReviewAudioPreparing {
    private let audioURL: URL?
    private let audible: Bool
    private(set) var flushMinDurations: [Double] = []
    private(set) var audibilityThresholds: [Float] = []
    private(set) var writeOutputURLs: [URL] = []

    init(audioURL: URL?, audible: Bool = true) {
        self.audioURL = audioURL
        self.audible = audible
    }

    func flush(minDurationSec: Double) throws -> [AudioChunk] {
        flushMinDurations.append(minDurationSec)
        return []
    }

    func hasAudibleContent(minimumRMS: Float) -> Bool {
        audibilityThresholds.append(minimumRMS)
        return audible
    }

    func writeCombinedWAV(to outputURL: URL) -> URL? {
        writeOutputURLs.append(outputURL)
        return audioURL
    }
}

private final class MediaAssetInspectorStub: MediaAssetInspecting {
    private let hasAudioTrackResult: Bool
    private let durationResult: Double?
    private(set) var checkedURLs: [URL] = []

    init(hasAudioTrack: Bool, durationSec: Double? = nil) {
        self.hasAudioTrackResult = hasAudioTrack
        self.durationResult = durationSec
    }

    func hasAudioTrack(url: URL) -> Bool {
        checkedURLs.append(url)
        return hasAudioTrackResult
    }

    func durationSec(url: URL) -> Double? {
        durationResult
    }
}

private final class ReviewMediaComposerSuccessStub: ReviewMediaComposing {
    private(set) var calls: [(
        videoURL: URL,
        audioURL: URL,
        outputURL: URL,
        timeline: ReviewMediaCompositionTimeline
    )] = []

    func composeVideoWithAudio(
        videoURL: URL,
        audioURL: URL,
        outputURL: URL,
        timeline: ReviewMediaCompositionTimeline
    ) throws -> URL {
        calls.append((videoURL: videoURL, audioURL: audioURL, outputURL: outputURL, timeline: timeline))
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("composed".utf8).write(to: outputURL)
        return outputURL
    }
}

private enum TestFailure: Error {
    case planned
}
