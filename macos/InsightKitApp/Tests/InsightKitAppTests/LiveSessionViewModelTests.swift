import AVFoundation
import Combine
import AppKit
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

    func testVisualPreviewPlanRoutesScreenOnlySelectionToScreenPreview() {
        let plan = LiveVisualPreviewPlan.resolve(cameraEnabled: false, screenEnabled: true)

        XCTAssertEqual(plan.source, .screen)
        XCTAssertTrue(plan.statusMessage?.contains("屏幕") == true)
    }

    func testCameraPreviewLayerUsesAspectFitToAvoidCropping() {
        let coordinator = VideoPreviewView.Coordinator()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
        view.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(sessionWithNoConnection: AVCaptureSession())

        coordinator.attachPreviewLayer(layer, to: view)

        XCTAssertEqual(layer.videoGravity, .resizeAspect)
    }

    func testRunningPreviewLayoutPreservesStandardMediaAspectRatio() {
        let size = LiveVisualPreviewLayout.previewSize(availableWidth: 1_000, maxHeight: 300)

        XCTAssertEqual(size.width, 533.3, accuracy: 0.5)
        XCTAssertEqual(size.height, 300, accuracy: 0.5)
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

    func testLiveWorkspaceProgressExplainsRuntimePreparation() {
        let viewModel = LiveSessionViewModel(
            rpcClient: RPCClientMock(),
            sidecarManager: SidecarManager(),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: ChunkAssembler(),
            asrService: LiveASRService()
        )
        viewModel.sessionPhase = .running
        viewModel.captureState = .preparingRuntime

        let progress = viewModel.liveProgressPresentation

        XCTAssertEqual(progress?.title, "正在准备本地语音运行时")
        XCTAssertEqual(progress?.message, "首次启动或切换模型时可能需要等待，请不要关闭窗口。")
    }

    func testLiveWorkspaceProgressExplainsModelWarmup() {
        let viewModel = LiveSessionViewModel(
            rpcClient: RPCClientMock(),
            sidecarManager: SidecarManager(),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: ChunkAssembler(),
            asrService: LiveASRService()
        )
        viewModel.sessionPhase = .running
        viewModel.captureState = .warmingModel
        viewModel.liveWarmup = LiveWarmupSnapshot(
            state: .warming,
            attempt: 2,
            bufferedChunks: 2,
            bufferedAudioMs: 4_000,
            automaticRetryCount: 0,
            isRetryScheduled: false,
            lastError: ""
        )

        let progress = viewModel.liveProgressPresentation

        XCTAssertEqual(progress?.title, "正在预热本地语音模型")
        XCTAssertEqual(progress?.message, "已暂存 2 段音频，模型就绪后会继续转写。")
    }

    func testLiveWorkspaceProgressExplainsPostRecordingFinalization() {
        let viewModel = LiveSessionViewModel(
            rpcClient: RPCClientMock(),
            sidecarManager: SidecarManager(),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: ChunkAssembler(),
            asrService: LiveASRService()
        )
        viewModel.sessionPhase = .running
        viewModel.isFinalizingLiveSession = true

        let progress = viewModel.liveProgressPresentation

        XCTAssertEqual(progress?.title, "正在整理录制内容")
        XCTAssertEqual(progress?.message, "正在保存回看资料、转写和笔记，完成后会进入智能纪要选择。")
    }

    func testLiveWorkspaceProgressExplainsSmartMinutesGeneration() {
        let viewModel = LiveSessionViewModel(
            rpcClient: RPCClientMock(),
            sidecarManager: SidecarManager(),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: ChunkAssembler(),
            asrService: LiveASRService()
        )
        viewModel.sessionPhase = .postSession
        viewModel.captureState = .refreshing

        let progress = viewModel.liveProgressPresentation

        XCTAssertEqual(progress?.title, "正在生成智能纪要")
        XCTAssertEqual(progress?.message, "正在根据本次转写生成结构化总结，完成后会进入回看。")
    }

    func testCenterStageDataSourceExposesLiveProgressPresentation() {
        let viewModel = LiveSessionViewModel(
            rpcClient: RPCClientMock(),
            sidecarManager: SidecarManager(),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: ChunkAssembler(),
            asrService: LiveASRService()
        )
        viewModel.sessionPhase = .postSession
        viewModel.captureState = .refreshing
        let dataSource: any CenterStageDataSource = viewModel

        XCTAssertEqual(dataSource.liveProgressPresentation?.title, "正在生成智能纪要")
    }

    @MainActor
    func testWaitingForFirstTranscriptUsesRecordingStatusInsteadOfErrorBanner() {
        let viewModel = LiveSessionViewModel(
            rpcClient: RPCClientMock(),
            sidecarManager: SidecarManager(),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: ChunkAssembler(),
            asrService: LiveASRService()
        )
        let startedAt = Date(timeIntervalSinceNow: -25)
        let lastChunkAt = Date(timeIntervalSinceNow: -2)
        viewModel._isRunningLock.lock()
        viewModel._isRunning = true
        viewModel._isRunningLock.unlock()
        viewModel.captureState = .capturing
        viewModel.captureHealth = CaptureHealthSnapshot(
            sessionStartedAt: startedAt,
            lastChunkAt: lastChunkAt,
            lastTranscriptAt: nil,
            inputLevelMic: 0.12,
            inputLevelSystem: 0
        )

        viewModel.evaluateCaptureHealthHint()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.recordingStatusMessage?.contains("等待转写输入") == true)
        XCTAssertEqual(viewModel.captureState, .capturing)
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

    func testCenterStageDataSourceExportsSmartMinutesReviewMarkdown() throws {
        let root = RecordExportTestFixture.makeRoot(prefix: "InsightKitLiveSummaryReviewExport")
        let recordID = "live-summary-review-export"
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
        viewModel.sessionPhase = .reviewing
        viewModel.smartMinutesData = SmartMinutes(structuredSummary: "Export this Smart Minutes review.")
        viewModel.stateQueue.sync {
            viewModel._sessionState.lastMeetingID = recordID
        }

        let dataSource: any CenterStageDataSource = viewModel
        XCTAssertTrue(dataSource.canExportDocument)

        var cancellables = Set<AnyCancellable>()
        let exp = expectation(description: "summary review markdown export")
        exp.assertForOverFulfill = false
        viewModel.$lastExportPath
            .dropFirst()
            .sink { path in
                if !path.isEmpty {
                    exp.fulfill()
                }
            }
            .store(in: &cancellables)

        dataSource.onExportDocument(format: "markdown")

        wait(for: [exp], timeout: 5.0)

        XCTAssertTrue(rpcClient.documentExportCalls.isEmpty)
        XCTAssertEqual(URL(fileURLWithPath: dataSource.lastExportPath).pathExtension, "md")
        let markdown = try String(contentsOf: URL(fileURLWithPath: dataSource.lastExportPath), encoding: .utf8)
        XCTAssertTrue(markdown.contains("## 长文版结构化总结"))
        XCTAssertTrue(markdown.contains("本地导出不依赖 sidecar PDF runtime。"))
        XCTAssertTrue(markdown.contains("export locally"))
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

    func testPrepareTemporaryRecordingPrefersExistingVideoRecordingForReview() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InsightKitVideoLiveRecording_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let videoURL = tmp.appendingPathComponent("recording.mp4")
        try Data([0, 0, 0, 16, 102, 116, 121, 112]).write(to: videoURL)
        let viewModel = LiveSessionViewModel(
            rpcClient: RPCClientMock(),
            sidecarManager: SidecarManager(),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: ChunkAssembler(),
            asrService: LiveASRService()
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        viewModel.temporaryRecordingURL = videoURL

        let recordingURL = try XCTUnwrap(viewModel.prepareTemporaryRecordingForSave(meetingID: "video-live-recording-test"))

        XCTAssertEqual(recordingURL, videoURL)
        XCTAssertEqual(viewModel.temporaryRecordingURL, videoURL)
        XCTAssertEqual(viewModel.mediaURL, videoURL)
        XCTAssertNil(viewModel.recordingStatusMessage)
    }

    func testPrepareTemporaryRecordingShowsAudioOnlyStatusWhenExpectedVideoIsMissing() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InsightKitMissingVideoLiveRecording_\(UUID().uuidString)", isDirectory: true)
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

        _ = try assembler.append(samples: Array(repeating: Float(0.15), count: 8_000))

        let recordingURL = try XCTUnwrap(
            viewModel.prepareTemporaryRecordingForSave(
                meetingID: "missing-video-live-recording-test",
                expectedVisualMedia: true
            )
        )

        XCTAssertEqual(recordingURL.pathExtension, "wav")
        XCTAssertEqual(viewModel.mediaURL, recordingURL)
        XCTAssertTrue(viewModel.recordingStatusMessage?.contains("未保存到视频画面") == true)
    }

    func testProcessChunkAppliesSuccessfulPipelineOutcomeToTranscriptAndMetrics() throws {
        let pipeline = LiveTranscriptProcessingMock()
        pipeline.outcome = LiveTranscriptPipelineOutcome(
            chunkIndex: 2,
            latencyMs: 42,
            ingestedCount: 2,
            transcriptSegments: [
                TranscriptSegment(startMs: 3_000, endMs: 4_000, speaker: "B", source: "mic", text: "second"),
                TranscriptSegment(startMs: 2_000, endMs: 3_000, speaker: "A", source: "mic", text: "first"),
            ],
            captureState: .transcribing,
            firstSegmentMs: nil,
            lastTranscriptAt: Date(timeIntervalSince1970: 1_002),
            refresh: .none,
            providerMetric: nil,
            analysisRuntimeState: nil,
            errorMessage: nil
        )
        let viewModel = LiveSessionViewModel(
            rpcClient: RPCClientMock(),
            sidecarManager: SidecarManager(),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: ChunkAssembler(),
            asrService: LiveASRService(),
            transcriptPipeline: pipeline
        )
        viewModel.asrWarmStatus = ASRWarmStatus(ready: true, state: .ready, inProgress: false, attempt: 1, lastWarmMs: 1200, lastError: "")
        viewModel.captureHealth = CaptureHealthSnapshot(
            sessionStartedAt: Date(timeIntervalSince1970: 1_000),
            lastChunkAt: nil,
            lastTranscriptAt: nil,
            inputLevelMic: 0,
            inputLevelSystem: 0
        )
        viewModel.transcriptSegments = [
            TranscriptSegment(startMs: 1_000, endMs: 2_000, speaker: "host", source: "mic", text: "existing")
        ]
        viewModel.metrics.firstSegmentMs = 1_000
        viewModel.metrics.segmentsIngested = 5
        viewModel.recordingStatusMessage = LiveCaptureHealthHint.waitingForTranscript

        try viewModel.processChunk(makeLiveSessionTestChunk(index: 1), meetingID: "meeting-live")
        drainMainQueue()

        XCTAssertEqual(pipeline.processCalls.map(\.context.meetingID), ["meeting-live"])
        XCTAssertEqual(pipeline.processCalls.map(\.context.source), ["mic"])
        XCTAssertEqual(pipeline.processCalls.first?.context.warmReady, true)
        XCTAssertEqual(pipeline.processCalls.first?.context.hasTranscript, true)
        XCTAssertEqual(viewModel.transcriptSegments.map { $0.text }, ["existing", "first", "second"])
        XCTAssertEqual(viewModel.metrics.chunkIndex, 2)
        XCTAssertEqual(viewModel.metrics.latencyMs, 42)
        XCTAssertEqual(viewModel.metrics.segmentsIngested, 7)
        XCTAssertEqual(viewModel.metrics.firstSegmentMs, 1_000)
        XCTAssertEqual(viewModel.captureHealth.lastTranscriptAt, Date(timeIntervalSince1970: 1_002))
        XCTAssertEqual(viewModel.captureState, CaptureState.transcribing)
        XCTAssertNil(viewModel.recordingStatusMessage)
    }

    func testProcessChunkAppliesEmptyPipelineOutcomeWithoutAddingTranscriptSegments() throws {
        let pipeline = LiveTranscriptProcessingMock()
        pipeline.outcome = LiveTranscriptPipelineOutcome(
            chunkIndex: 4,
            latencyMs: 0,
            ingestedCount: 0,
            transcriptSegments: [],
            captureState: .capturing,
            firstSegmentMs: nil,
            lastTranscriptAt: nil,
            refresh: .none,
            providerMetric: nil,
            analysisRuntimeState: nil,
            errorMessage: nil
        )
        let viewModel = LiveSessionViewModel(
            rpcClient: RPCClientMock(),
            sidecarManager: SidecarManager(),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: ChunkAssembler(),
            asrService: LiveASRService(),
            transcriptPipeline: pipeline
        )
        viewModel.asrWarmStatus = ASRWarmStatus(ready: true, state: .ready, inProgress: false, attempt: 1, lastWarmMs: 1200, lastError: "")

        try viewModel.processChunk(makeLiveSessionTestChunk(index: 3), meetingID: "meeting-empty")
        drainMainQueue()

        XCTAssertEqual(pipeline.processCalls.map(\.context.meetingID), ["meeting-empty"])
        XCTAssertTrue(viewModel.transcriptSegments.isEmpty)
        XCTAssertEqual(viewModel.metrics.chunkIndex, 4)
        XCTAssertEqual(viewModel.metrics.segmentsIngested, 0)
        XCTAssertNil(viewModel.captureHealth.lastTranscriptAt)
        XCTAssertEqual(viewModel.captureState, CaptureState.capturing)
    }

    func testProcessChunkAppliesRefreshSuccessPipelineOutcomeToWorkbench() throws {
        let refreshedAt = Date(timeIntervalSince1970: 1_010)
        let pipeline = LiveTranscriptProcessingMock()
        pipeline.outcome = LiveTranscriptPipelineOutcome(
            chunkIndex: 5,
            latencyMs: 64,
            ingestedCount: 1,
            transcriptSegments: [
                TranscriptSegment(startMs: 4_000, endMs: 5_000, speaker: "A", source: "mic", text: "refresh insight")
            ],
            captureState: .transcribing,
            firstSegmentMs: 4_000,
            lastTranscriptAt: refreshedAt,
            refresh: .success(makeLiveSessionTestRefreshResult(updatedAt: refreshedAt, provider: "openai:gpt-4o-mini")),
            providerMetric: nil,
            analysisRuntimeState: nil,
            errorMessage: nil
        )
        let viewModel = LiveSessionViewModel(
            rpcClient: RPCClientMock(),
            sidecarManager: SidecarManager(),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: ChunkAssembler(),
            asrService: LiveASRService(),
            transcriptPipeline: pipeline
        )
        viewModel.analysisRuntimeState = .pausedTimeout
        viewModel.stateQueue.sync {
            viewModel.insightRefreshSuspended = true
        }

        try viewModel.processChunk(makeLiveSessionTestChunk(index: 4), meetingID: "meeting-refresh")
        drainMainQueue()

        XCTAssertEqual(viewModel.transcriptSegments.map { $0.text }, ["refresh insight"])
        XCTAssertEqual(viewModel.workbench.sessionOverview, "Live refresh overview.")
        XCTAssertEqual(viewModel.metrics.provider, "openai:gpt-4o-mini")
        XCTAssertEqual(viewModel.metrics.lastRefreshAt, refreshedAt)
        XCTAssertEqual(viewModel.analysisRuntimeState, AnalysisRuntimeState.ready)
        XCTAssertFalse(viewModel.stateQueue.sync { viewModel.insightRefreshSuspended })
    }

    func testProcessChunkAppliesAuthFailurePipelinePauseWhileKeepingTranscript() throws {
        let pipeline = LiveTranscriptProcessingMock()
        pipeline.outcome = LiveTranscriptPipelineOutcome(
            chunkIndex: 6,
            latencyMs: 55,
            ingestedCount: 1,
            transcriptSegments: [
                TranscriptSegment(startMs: 5_000, endMs: 6_000, speaker: "A", source: "mic", text: "auth failure transcript")
            ],
            captureState: .transcribing,
            firstSegmentMs: 5_000,
            lastTranscriptAt: Date(timeIntervalSince1970: 1_011),
            refresh: .paused(.authFailed),
            providerMetric: "analysis-paused",
            analysisRuntimeState: .pausedAuthFailed,
            errorMessage: "智能分析服务鉴权失败，转写继续、洞察已暂停。请打开设置修复 API 配置后重新开始直播洞察。"
        )
        let viewModel = LiveSessionViewModel(
            rpcClient: RPCClientMock(),
            sidecarManager: SidecarManager(),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: ChunkAssembler(),
            asrService: LiveASRService(),
            transcriptPipeline: pipeline
        )

        try viewModel.processChunk(makeLiveSessionTestChunk(index: 5), meetingID: "meeting-auth")
        drainMainQueue()

        XCTAssertEqual(viewModel.transcriptSegments.map { $0.text }, ["auth failure transcript"])
        XCTAssertEqual(viewModel.metrics.provider, "analysis-paused")
        XCTAssertEqual(viewModel.analysisRuntimeState, AnalysisRuntimeState.pausedAuthFailed)
        XCTAssertTrue(viewModel.errorMessage?.contains("鉴权失败") == true)
        XCTAssertTrue(viewModel.stateQueue.sync { viewModel.insightRefreshSuspended })
    }

    func testProcessChunkAppliesProviderTimeoutPipelinePauseWhileKeepingTranscript() throws {
        let pipeline = LiveTranscriptProcessingMock()
        pipeline.outcome = LiveTranscriptPipelineOutcome(
            chunkIndex: 7,
            latencyMs: 58,
            ingestedCount: 1,
            transcriptSegments: [
                TranscriptSegment(startMs: 6_000, endMs: 7_000, speaker: "A", source: "mic", text: "timeout transcript")
            ],
            captureState: .transcribing,
            firstSegmentMs: 6_000,
            lastTranscriptAt: Date(timeIntervalSince1970: 1_012),
            refresh: .paused(.timeout),
            providerMetric: "analysis-paused",
            analysisRuntimeState: .pausedTimeout,
            errorMessage: "智能分析探测超时，转写继续、洞察已暂停。请稍后重试或检查网络。"
        )
        let viewModel = LiveSessionViewModel(
            rpcClient: RPCClientMock(),
            sidecarManager: SidecarManager(),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: ChunkAssembler(),
            asrService: LiveASRService(),
            transcriptPipeline: pipeline
        )

        try viewModel.processChunk(makeLiveSessionTestChunk(index: 6), meetingID: "meeting-timeout")
        drainMainQueue()

        XCTAssertEqual(viewModel.transcriptSegments.map { $0.text }, ["timeout transcript"])
        XCTAssertEqual(viewModel.metrics.provider, "analysis-paused")
        XCTAssertEqual(viewModel.analysisRuntimeState, AnalysisRuntimeState.pausedTimeout)
        XCTAssertTrue(viewModel.errorMessage?.contains("探测超时") == true)
        XCTAssertTrue(viewModel.stateQueue.sync { viewModel.insightRefreshSuspended })
    }

    func testProcessChunkTreatsLiveRefreshTimeoutAsRecoverableStatus() throws {
        let pipeline = LiveTranscriptProcessingMock()
        pipeline.outcome = LiveTranscriptPipelineOutcome(
            chunkIndex: 8,
            latencyMs: 61,
            ingestedCount: 1,
            transcriptSegments: [
                TranscriptSegment(startMs: 7_000, endMs: 8_000, speaker: "A", source: "mic", text: "recoverable timeout transcript")
            ],
            captureState: .transcribing,
            firstSegmentMs: 7_000,
            lastTranscriptAt: Date(timeIntervalSince1970: 1_013),
            refresh: .paused(.timeout),
            providerMetric: "analysis-refresh-timeout",
            analysisRuntimeState: .ready,
            errorMessage: nil
        )
        let viewModel = LiveSessionViewModel(
            rpcClient: RPCClientMock(),
            sidecarManager: SidecarManager(),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: ChunkAssembler(),
            asrService: LiveASRService(),
            transcriptPipeline: pipeline
        )

        try viewModel.processChunk(makeLiveSessionTestChunk(index: 7), meetingID: "meeting-refresh-timeout")
        drainMainQueue()

        XCTAssertEqual(viewModel.transcriptSegments.map { $0.text }, ["recoverable timeout transcript"])
        XCTAssertEqual(viewModel.metrics.provider, "analysis-refresh-timeout")
        XCTAssertEqual(viewModel.analysisRuntimeState, AnalysisRuntimeState.ready)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.recordingStatusMessage?.contains("刷新超时") == true)
        XCTAssertFalse(viewModel.stateQueue.sync { viewModel.insightRefreshSuspended })
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

    func testPublishErrorSanitizesProviderNonJSONPayloadError() throws {
        let providerError = NSError(
            domain: "InsightKitTests",
            code: -10,
            userInfo: [
                NSLocalizedDescriptionKey: "Insight 侧车错误: provider returned non-JSON payload: Expecting ',' delimiter: line 42 column 32 (char 1169)"
            ]
        )
        let viewModel = LiveSessionViewModel(
            rpcClient: RPCClientMock(),
            sidecarManager: SidecarManager(),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: ChunkAssembler(),
            asrService: LiveASRService()
        )

        viewModel.publishError(providerError)
        drainMainQueue()

        XCTAssertTrue(viewModel.errorMessage?.contains("分析服务返回格式异常") == true)
        XCTAssertFalse(viewModel.errorMessage?.contains("line 42") == true)
        XCTAssertFalse(viewModel.errorMessage?.contains("char 1169") == true)
    }
}

private final class LiveTranscriptProcessingMock: LiveTranscriptProcessing {
    var outcome = LiveTranscriptPipelineOutcome(
        chunkIndex: 1,
        latencyMs: 0,
        ingestedCount: 0,
        transcriptSegments: [],
        captureState: .capturing,
        firstSegmentMs: nil,
        lastTranscriptAt: nil,
        refresh: .none,
        providerMetric: nil,
        analysisRuntimeState: nil,
        errorMessage: nil
    )
    private(set) var resetCalls = 0
    private(set) var processCalls: [(chunk: AudioChunk, context: LiveTranscriptPipelineContext)] = []

    func reset() {
        resetCalls += 1
    }

    func process(chunk: AudioChunk, context: LiveTranscriptPipelineContext) throws -> LiveTranscriptPipelineOutcome {
        processCalls.append((chunk: chunk, context: context))
        return outcome
    }
}

private func makeLiveSessionTestChunk(index: Int) -> AudioChunk {
    AudioChunk(
        index: index,
        url: URL(fileURLWithPath: "/tmp/live-session-\(index).wav"),
        startMs: index * 1_000,
        endMs: (index + 1) * 1_000,
        rms: 0.2
    )
}

private func makeLiveSessionTestRefreshResult(
    updatedAt: Date,
    provider: String
) -> InsightRefreshResult {
    InsightRefreshResult(
        package: InsightPackageV1(
            sessionOverview: .init(title: "Live", overview: "Live refresh overview.", topics: ["Live"]),
            highlightInsights: [],
            speakerPerspectives: [],
            decisionLedger: [],
            actionTracks: [],
            timelineBeats: [],
            provenanceLinks: []
        ),
        updatedAt: updatedAt,
        provider: provider,
        needsReviewCount: 0
    )
}

private func drainMainQueue(
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let expectation = XCTestExpectation(description: "main queue drained")
    DispatchQueue.main.async {
        expectation.fulfill()
    }
    XCTWaiter().wait(for: [expectation], timeout: 1.0)
}
