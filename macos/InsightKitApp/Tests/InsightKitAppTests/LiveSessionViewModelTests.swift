import Combine
import XCTest
@testable import InsightKitApp

final class LiveSessionViewModelTests: XCTestCase {
    func testDefaultInputModeIsMicrophone() {
        let viewModel = LiveSessionViewModel(
            rpcClient: RPCClientMock(),
            sidecarManager: SidecarManager(),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: ChunkAssembler(),
            asrService: LiveASRService()
        )

        XCTAssertEqual(viewModel.inputMode, .microphone)
    }

    func testResetForNewSessionRestoresMicrophoneInputModeWithoutClearingSystemSource() {
        let viewModel = LiveSessionViewModel(
            rpcClient: RPCClientMock(),
            sidecarManager: SidecarManager(),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: ChunkAssembler(),
            asrService: LiveASRService()
        )
        viewModel.inputMode = .mixed
        viewModel.selectSystemSource("display-1")

        viewModel.resetForNewSession()

        XCTAssertEqual(viewModel.inputMode, .microphone)
        XCTAssertEqual(viewModel.selectedSystemSourceID, "display-1")
    }

    func testMixedInputStillRequiresSystemSourceAndDoesNotOverwriteSelection() {
        let viewModel = LiveSessionViewModel(
            rpcClient: RPCClientMock(),
            sidecarManager: SidecarManager(),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: ChunkAssembler(),
            asrService: LiveASRService()
        )
        viewModel.inputMode = .mixed
        viewModel.selectSystemSource(nil)

        viewModel.startLiveSession()

        XCTAssertEqual(viewModel.inputMode, .mixed)
        XCTAssertTrue(viewModel.isSystemAudioPickerPresented)
        XCTAssertEqual(viewModel.errorMessage, "请先选择系统音频源。")
    }

    func testMicrophoneModeDoesNotRequireSystemSourceSelection() {
        XCTAssertFalse(AudioInputMode.microphone.requiresSystemAudioSource)
        XCTAssertTrue(AudioInputMode.systemAudio.requiresSystemAudioSource)
        XCTAssertTrue(AudioInputMode.mixed.requiresSystemAudioSource)
    }

    func testRefreshThrottleBySegmentCountAndInterval() {
        var coordinator = LiveInsightCoordinator(minRefreshInterval: 15, minSegmentsBeforeRefresh: 2)

        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(coordinator.registerIngested(1, now: t0))

        coordinator.markRefreshed(at: t0)

        let t1 = t0.addingTimeInterval(3)
        XCTAssertFalse(coordinator.registerIngested(1, now: t1))

        let t2 = t0.addingTimeInterval(5)
        XCTAssertTrue(coordinator.registerIngested(1, now: t2))

        coordinator.markRefreshed(at: t2)

        let t3 = t2.addingTimeInterval(16)
        XCTAssertTrue(coordinator.registerIngested(1, now: t3))
    }

    func testCaptureStateLabelsIncludeRuntimePreparationStages() {
        XCTAssertEqual(CaptureState.preparingRuntime.label, "准备运行时")
        XCTAssertEqual(CaptureState.warmingModel.label, "预热模型")
        XCTAssertEqual(CaptureState.capturing.label, "可转写")
    }

    func testWarmupBacklogPrefersDroppingBufferedSilence() {
        let policy = WarmupBacklogPolicy(maxChunks: 2, maxBufferedAudioMs: 8_000)
        let speech = AudioChunk(index: 0, url: URL(fileURLWithPath: "/tmp/speech.wav"), startMs: 0, endMs: 2_000, rms: 0.2)
        let silence = AudioChunk(index: 1, url: URL(fileURLWithPath: "/tmp/silence.wav"), startMs: 2_000, endMs: 8_000, rms: 0.0)
        let incoming = AudioChunk(index: 2, url: URL(fileURLWithPath: "/tmp/incoming.wav"), startMs: 8_000, endMs: 14_000, rms: 0.3)

        let update = policy.enqueue(incoming, into: [speech, silence])

        XCTAssertFalse(update.droppedIncoming)
        XCTAssertEqual(update.droppedExisting.map(\.index), [silence.index])
        XCTAssertEqual(update.queue.map(\.index), [speech.index, incoming.index])
        XCTAssertEqual(update.bufferedAudioMs, 8_000)
    }

    func testWarmupBacklogDropsIncomingSilentChunkWhenBufferedAudioIsAlreadyFull() {
        let policy = WarmupBacklogPolicy(maxChunks: 2, maxBufferedAudioMs: 8_000)
        let speechA = AudioChunk(index: 0, url: URL(fileURLWithPath: "/tmp/a.wav"), startMs: 0, endMs: 2_000, rms: 0.2)
        let speechB = AudioChunk(index: 1, url: URL(fileURLWithPath: "/tmp/b.wav"), startMs: 2_000, endMs: 8_000, rms: 0.2)
        let incomingSilence = AudioChunk(index: 2, url: URL(fileURLWithPath: "/tmp/c.wav"), startMs: 8_000, endMs: 14_000, rms: 0.0)

        let update = policy.enqueue(incomingSilence, into: [speechA, speechB])

        XCTAssertTrue(update.droppedIncoming)
        XCTAssertTrue(update.droppedExisting.isEmpty)
        XCTAssertEqual(update.queue.map(\.index), [speechA.index, speechB.index])
    }

    func testWarmupRetryPolicyRetriesOnceThenFails() {
        let policy = WarmupRetryPolicy(maxAutomaticRetries: 1, retryDelaySec: 2)

        XCTAssertEqual(policy.action(forFailureCount: 1), .retry(afterSeconds: 2))
        XCTAssertEqual(policy.action(forFailureCount: 2), .failSession)
    }

    func testCaptureStateMappingMatchesWarmReadyAndTranscriptAvailability() {
        XCTAssertEqual(LiveCaptureStateMapper.captureState(warmReady: false, hasTranscript: false), .warmingModel)
        XCTAssertEqual(LiveCaptureStateMapper.captureState(warmReady: true, hasTranscript: false), .capturing)
        XCTAssertEqual(LiveCaptureStateMapper.captureState(warmReady: true, hasTranscript: true), .transcribing)
    }

    func testLiveExportPrefersPersistedNativePDFOverRPC() throws {
        let root = RecordExportTestFixture.makeRoot(prefix: "InsightKitLiveExport")
        let recordID = "live-native-export"
        try RecordExportTestFixture.seedRecord(root: root, recordID: recordID, source: .live)
        defer { try? FileManager.default.removeItem(at: root) }

        let recordsService = RecordsIndexService()
        recordsService.rootDirectory = root
        let rpcClient = RPCClientMock()
        let viewModel = LiveSessionViewModel(
            rpcClient: rpcClient,
            sidecarManager: SidecarManager(),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: ChunkAssembler(),
            asrService: LiveASRService()
        )
        viewModel.recordsService = recordsService
        viewModel.stateQueue.sync {
            viewModel._sessionState.lastMeetingID = recordID
        }
        XCTAssertTrue(viewModel.hasPersistedRecordForExport)

        var cancellables = Set<AnyCancellable>()
        let exp = expectation(description: "native live export")
        exp.assertForOverFulfill = false
        viewModel.$lastExportPath
            .dropFirst()
            .sink { path in
                if !path.isEmpty {
                    exp.fulfill()
                }
            }
            .store(in: &cancellables)
        viewModel.exportDocument(format: "pdf")

        wait(for: [exp], timeout: 5.0)

        XCTAssertTrue(rpcClient.documentExportCalls.isEmpty)
        XCTAssertEqual(URL(fileURLWithPath: viewModel.lastExportPath).pathExtension, "pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: viewModel.lastExportPath))
        let data = try Data(contentsOf: URL(fileURLWithPath: viewModel.lastExportPath))
        XCTAssertEqual(String(data: data.prefix(5), encoding: .utf8), "%PDF-")
    }

    func testPrepareTemporaryRecordingCombinesLiveChunksForPlaybackAndSave() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InsightKitLiveRecording_\(UUID().uuidString)", isDirectory: true)
        let assembler = ChunkAssembler(chunkDurationSec: 2, sampleRate: 16_000, chunkDir: tmp)
        let viewModel = LiveSessionViewModel(
            rpcClient: RPCClientMock(),
            sidecarManager: SidecarManager(),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: assembler,
            asrService: LiveASRService()
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try assembler.append(samples: Array(repeating: Float(0.15), count: 40_000))
        _ = try assembler.flush(minDurationSec: 0.1)

        let recordingURL = try XCTUnwrap(viewModel.prepareTemporaryRecordingForSave(meetingID: "live-recording-test"))

        XCTAssertEqual(recordingURL.lastPathComponent, "recording.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordingURL.path))
        XCTAssertEqual(viewModel.temporaryRecordingURL, recordingURL)
        XCTAssertEqual(viewModel.mediaURL, recordingURL)
        let data = try Data(contentsOf: recordingURL)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data.subdata(in: 8..<12), encoding: .ascii), "WAVE")
    }

    func testPrepareTemporaryRecordingFlushesShortPendingAudioForPlaybackAndSave() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InsightKitShortLiveRecording_\(UUID().uuidString)", isDirectory: true)
        let assembler = ChunkAssembler(chunkDurationSec: 2, sampleRate: 16_000, chunkDir: tmp)
        let viewModel = LiveSessionViewModel(
            rpcClient: RPCClientMock(),
            sidecarManager: SidecarManager(),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: assembler,
            asrService: LiveASRService()
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        let chunks = try assembler.append(samples: Array(repeating: Float(0.15), count: 8_000))
        XCTAssertTrue(chunks.isEmpty)

        let recordingURL = try XCTUnwrap(viewModel.prepareTemporaryRecordingForSave(meetingID: "short-live-recording-test"))

        XCTAssertEqual(viewModel.temporaryRecordingURL, recordingURL)
        XCTAssertEqual(viewModel.mediaURL, recordingURL)
        let data = try Data(contentsOf: recordingURL)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data.subdata(in: 8..<12), encoding: .ascii), "WAVE")
        XCTAssertEqual(data.count, 44 + (8_000 * 2))
    }

    func testPrepareTemporaryRecordingShowsVisibleStatusWhenNoAudioCaptured() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InsightKitEmptyLiveRecording_\(UUID().uuidString)", isDirectory: true)
        let assembler = ChunkAssembler(chunkDurationSec: 2, sampleRate: 16_000, chunkDir: tmp)
        let viewModel = LiveSessionViewModel(
            rpcClient: RPCClientMock(),
            sidecarManager: SidecarManager(),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: assembler,
            asrService: LiveASRService()
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        XCTAssertNil(viewModel.prepareTemporaryRecordingForSave(meetingID: "empty-live-recording-test"))

        XCTAssertNil(viewModel.temporaryRecordingURL)
        XCTAssertNil(viewModel.mediaURL)
        XCTAssertTrue(viewModel.recordingStatusMessage?.contains("录音太短") == true)
        XCTAssertTrue(viewModel.recordingStatusMessage?.contains("未捕获到可保存音频") == true)

        _ = try assembler.append(samples: Array(repeating: Float(0.15), count: 8_000))
        let recordingURL = try XCTUnwrap(viewModel.prepareTemporaryRecordingForSave(meetingID: "empty-live-recording-test"))

        XCTAssertEqual(viewModel.temporaryRecordingURL, recordingURL)
        XCTAssertEqual(viewModel.mediaURL, recordingURL)
        XCTAssertNil(viewModel.recordingStatusMessage)
    }

    func testSaveToRecordsUsesPreparedLiveRecordingAsMediaSource() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InsightKitLiveSave_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let recordingURL = tmp.appendingPathComponent("recording.wav")
        try Data("RIFF----WAVE".utf8).write(to: recordingURL)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let rpcClient = RPCClientMock()
        let viewModel = LiveSessionViewModel(
            rpcClient: rpcClient,
            sidecarManager: SidecarManager(),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: ChunkAssembler(),
            asrService: LiveASRService()
        )
        viewModel.temporaryRecordingURL = recordingURL
        viewModel.recordingDuration = 12.5
        viewModel.notes = [TimestampedNote(text: "live note", timestamp: 3)]

        var cancellables = Set<AnyCancellable>()
        let exp = expectation(description: "live records.save")
        exp.assertForOverFulfill = false
        viewModel.$lastExportPath
            .dropFirst()
            .sink { path in
                if !path.isEmpty {
                    exp.fulfill()
                }
            }
            .store(in: &cancellables)

        viewModel.saveToRecords(meetingID: "live-save-test")

        wait(for: [exp], timeout: 5.0)
        let call = try XCTUnwrap(rpcClient.recordsSaveCalls.first)
        XCTAssertEqual(call.meetingID, "live-save-test")
        XCTAssertEqual(call.sourcePath, recordingURL.path)
        XCTAssertEqual(call.mediaType, "audio")
        XCTAssertEqual(call.recordSource, "live")
        XCTAssertEqual(call.durationSec, 12.5)
        XCTAssertTrue(call.notesMD.contains("00:03 live note"))
    }

    func testSaveToRecordsPersistsGeneratedLiveInsightPackageForRecovery() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InsightKitLiveFinalSave_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let recordingURL = tmp.appendingPathComponent("recording.wav")
        try Data("RIFF----WAVE".utf8).write(to: recordingURL)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let rpcClient = RPCClientMock()
        let viewModel = LiveSessionViewModel(
            rpcClient: rpcClient,
            sidecarManager: SidecarManager(),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: ChunkAssembler(),
            asrService: LiveASRService()
        )
        viewModel.temporaryRecordingURL = recordingURL
        viewModel.recordingDuration = 90
        viewModel.notes = [TimestampedNote(text: "note survives final minutes", timestamp: 86)]
        viewModel.metrics.provider = "deepseek:deepseek-v4-flash"
        let package = InsightPackageV1(
            sessionOverview: .init(title: "直播洞察", overview: "未提供会议转写数据", topics: ["实时录制", "本地降级"]),
            highlightInsights: [],
            speakerPerspectives: [],
            decisionLedger: [],
            actionTracks: [],
            timelineBeats: [],
            provenanceLinks: []
        )

        var cancellables = Set<AnyCancellable>()
        let exp = expectation(description: "live final records.save")
        exp.assertForOverFulfill = false
        viewModel.$lastExportPath
            .dropFirst()
            .sink { path in
                if !path.isEmpty {
                    exp.fulfill()
                }
            }
            .store(in: &cancellables)

        viewModel.saveToRecords(meetingID: "live-final-save-test", insightPackageOverride: package)

        wait(for: [exp], timeout: 5.0)
        let call = try XCTUnwrap(rpcClient.recordsSaveCalls.first)
        let insightPackage = try XCTUnwrap(call.insightPackage)
        let overview = try XCTUnwrap(insightPackage["session_overview"] as? [String: Any])
        XCTAssertEqual(overview["overview"] as? String, "未提供会议转写数据")
        XCTAssertEqual(overview["topics"] as? [String], ["实时录制", "本地降级"])
        XCTAssertEqual(call.sourcePath, recordingURL.path)
        XCTAssertEqual(call.durationSec, 90)
        XCTAssertEqual(call.analysisMeta?["provider"] as? String, "deepseek")
        XCTAssertEqual(call.analysisMeta?["model"] as? String, "deepseek-v4-flash")
        XCTAssertEqual(call.analysisMeta?["analysis_state"] as? String, AnalysisRuntimeState.ready.rawValue)
        XCTAssertTrue(call.notesMD.contains("01:26 note survives final minutes"))
    }
}
