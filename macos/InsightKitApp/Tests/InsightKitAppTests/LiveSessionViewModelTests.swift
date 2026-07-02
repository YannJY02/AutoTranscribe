import AVFoundation
import Combine
import Darwin
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
            asrService: LiveASRService(),
            mediaAssetInspector: MediaAssetInspectorSpy(hasAudioTrack: false)
        )

        XCTAssertEqual(viewModel.inputMode, .microphone)
    }

    func testDeinitDuringRunningSessionDoesNotTriggerAsyncFinalizationWork() {
        var viewModel: LiveSessionViewModel? = LiveSessionViewModel(
            rpcClient: RPCClientMock(),
            sidecarManager: SidecarManager(),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: ChunkAssembler(),
            asrService: LiveASRService()
        )
        weak var releasedViewModel = viewModel

        viewModel?.stateQueue.sync {
            viewModel?._isRunningLock.lock()
            viewModel?._isRunning = true
            viewModel?._isRunningLock.unlock()
            viewModel?._sessionState.activeMeetingID = "live-deinit-test"
        }

        viewModel = nil

        XCTAssertNil(releasedViewModel)
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

    func testVisualPreviewPlanRoutesCameraAndScreenToCameraOverlay() {
        let plan = LiveVisualPreviewPlan.resolve(cameraEnabled: true, screenEnabled: true)

        XCTAssertEqual(plan.source, .screenWithCameraOverlay)
        XCTAssertTrue(plan.statusMessage?.contains("摄像头叠加") == true)
    }

    func testPresentationCaptureStatusDistinguishesOverlayFromFallback() {
        XCTAssertEqual(
            LivePresentationCaptureStatus.resolve(
                cameraEnabled: true,
                screenEnabled: true,
                presenterOverlayObserved: true
            ),
            .presenterOverlayCaptured
        )
        XCTAssertEqual(
            LivePresentationCaptureStatus.resolve(
                cameraEnabled: true,
                screenEnabled: true,
                presenterOverlayObserved: false
            ),
            .screenOnlyFallback
        )
    }

    func testPresentationCaptureStatusIncludesScreenPlusCameraOverlay() {
        XCTAssertEqual(
            LivePresentationCaptureStatus.resolve(
                cameraEnabled: true,
                screenEnabled: true,
                presenterOverlayObserved: false,
                cameraOverlayCaptured: true
            ),
            .screenPlusCameraCaptured
        )
    }

    func testCurrentPresentationStatusMarksCameraOverlayPathAsCaptured() {
        let viewModel = LiveSessionViewModel(
            rpcClient: RPCClientMock(),
            sidecarManager: SidecarManager(),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: ChunkAssembler(),
            asrService: LiveASRService()
        )

        viewModel.visualPreviewSource = .screenWithCameraOverlay

        XCTAssertEqual(viewModel.currentPresentationCaptureStatus(), .screenPlusCameraCaptured)
    }

    func testPauseRecordingDoesNotStopLiveSession() {
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
        viewModel.stateQueue.sync {
            viewModel._isRunningLock.lock()
            viewModel._isRunning = true
            viewModel._isRunningLock.unlock()
            viewModel._sessionState.activeMeetingID = "live-pause-test"
        }

        viewModel.onPauseRecording()

        XCTAssertTrue(viewModel.isRunning)
        XCTAssertTrue(viewModel.isLiveRecordingPaused())
        XCTAssertEqual(viewModel.sessionPhase, .running)
        XCTAssertNil(viewModel.stopDrainingMeetingID)
        let pausedTimeline = viewModel.stateQueue.sync { viewModel.captureTimeline }
        XCTAssertNotNil(pausedTimeline.currentPauseStartSec)
        XCTAssertTrue(pausedTimeline.pauseIntervals.isEmpty)

        Thread.sleep(forTimeInterval: 0.01)
        viewModel.onPauseRecording()

        XCTAssertTrue(viewModel.isRunning)
        XCTAssertFalse(viewModel.isLiveRecordingPaused())
        XCTAssertEqual(viewModel.sessionPhase, .running)
        let resumedTimeline = viewModel.stateQueue.sync { viewModel.captureTimeline }
        XCTAssertNil(resumedTimeline.currentPauseStartSec)
        XCTAssertEqual(resumedTimeline.pauseIntervals.count, 1)
        XCTAssertGreaterThan(resumedTimeline.pauseIntervals[0].durationSec, 0)
    }

    func testPausedLiveSessionIgnoresMixedSamples() {
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
        viewModel.stateQueue.sync {
            viewModel._isRunningLock.lock()
            viewModel._isRunning = true
            viewModel._isRunningLock.unlock()
            viewModel._sessionState.activeMeetingID = "live-paused-audio-test"
        }
        viewModel.pauseLiveSession()

        viewModel.handleMixedSamples(Array(repeating: Float(0.25), count: 8_000))

        let timeline = viewModel.stateQueue.sync { viewModel.captureTimeline }
        XCTAssertNil(timeline.audioStartSec)
    }

    @MainActor
    func testPausedLiveSessionSuppressesCaptureHealthWarnings() {
        let viewModel = LiveSessionViewModel(
            rpcClient: RPCClientMock(),
            sidecarManager: SidecarManager(),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: ChunkAssembler(),
            asrService: LiveASRService()
        )
        viewModel.captureState = .capturing
        viewModel.captureHealth = CaptureHealthSnapshot(
            sessionStartedAt: Date(timeIntervalSinceNow: -30),
            lastChunkAt: nil,
            lastTranscriptAt: nil,
            inputLevelMic: 0,
            inputLevelSystem: 0
        )
        viewModel.stateQueue.sync {
            viewModel._isRunningLock.lock()
            viewModel._isRunning = true
            viewModel._isRunningLock.unlock()
            viewModel._sessionState.activeMeetingID = "live-paused-health-test"
        }
        viewModel.pauseLiveSession()

        viewModel.evaluateCaptureHealthHint()

        XCTAssertEqual(viewModel.recordingStatusMessage, "录制已暂停。点击继续后会恢复写入音频和视频。")
    }

    func testSessionUIResetPreservesVisualFallbackSelection() {
        let viewModel = LiveSessionViewModel(
            rpcClient: RPCClientMock(),
            sidecarManager: SidecarManager(),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: ChunkAssembler(),
            asrService: LiveASRService()
        )

        viewModel.visualPreviewSource = .screen
        viewModel.visualSelectionUsesScreenOnlyFallback = true
        viewModel.resetSessionUI()

        XCTAssertEqual(viewModel.currentPresentationCaptureStatus(), .screenOnlyFallback)
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

    func testPrepareTemporaryRecordingTreatsNearSilentChunksAsNoCapturedAudio() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InsightKitSilentLiveRecording_\(UUID().uuidString)", isDirectory: true)
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

        _ = try assembler.append(samples: Array(repeating: Float(0.00002), count: 40_000))

        XCTAssertNil(viewModel.prepareTemporaryRecordingForSave(meetingID: "silent-live-recording-test"))
        XCTAssertNil(viewModel.temporaryRecordingURL)
        XCTAssertNil(viewModel.mediaURL)
        XCTAssertTrue(viewModel.recordingStatusMessage?.contains("未捕获到可保存音频") == true)
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
            asrService: LiveASRService(),
            mediaAssetInspector: MediaAssetInspectorSpy(hasAudioTrack: false, durationSec: 2.0)
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        viewModel.temporaryRecordingURL = videoURL

        let recordingURL = try XCTUnwrap(viewModel.prepareTemporaryRecordingForSave(meetingID: "video-live-recording-test"))

        XCTAssertEqual(recordingURL, videoURL)
        XCTAssertEqual(viewModel.temporaryRecordingURL, videoURL)
        XCTAssertEqual(viewModel.mediaURL, videoURL)
        XCTAssertNil(viewModel.recordingStatusMessage)
    }

    func testPrepareTemporaryRecordingRejectsUnplayableNonEmptyVideoRecording() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InsightKitInvalidVideoLiveRecording_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let videoURL = tmp.appendingPathComponent("recording.mp4")
        try Data("ftyp-but-no-moov".utf8).write(to: videoURL)
        let audioChunks = tmp.appendingPathComponent("chunks", isDirectory: true)
        let assembler = ChunkAssembler(chunkDurationSec: 2, sampleRate: 16_000, chunkDir: audioChunks)
        let viewModel = LiveSessionViewModel(
            rpcClient: RPCClientMock(),
            sidecarManager: SidecarManager(),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: assembler,
            asrService: LiveASRService(),
            mediaAssetInspector: MediaAssetInspectorSpy(hasAudioTrack: false, durationSec: nil)
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try assembler.append(samples: Array(repeating: Float(0.15), count: 8_000))
        viewModel.temporaryRecordingURL = videoURL

        let recordingURL = try XCTUnwrap(
            viewModel.prepareTemporaryRecordingForSave(
                meetingID: "invalid-video-live-recording-test",
                expectedVisualMedia: true
            )
        )

        XCTAssertEqual(recordingURL.pathExtension, "wav")
        XCTAssertEqual(viewModel.temporaryRecordingURL, recordingURL)
        XCTAssertEqual(viewModel.mediaURL, recordingURL)
        XCTAssertTrue(viewModel.recordingStatusMessage?.contains("未保存到视频画面") == true)
    }

    func testPrepareTemporaryRecordingComposesSinglePlayableVideoWhenVideoAndAudioAreCaptured() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InsightKitVideoAndAudioLiveRecording_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let videoURL = tmp.appendingPathComponent("recording.mp4")
        try Data([0, 0, 0, 16, 102, 116, 121, 112]).write(to: videoURL)
        let audioChunks = tmp.appendingPathComponent("chunks", isDirectory: true)
        let assembler = ChunkAssembler(chunkDurationSec: 2, sampleRate: 16_000, chunkDir: audioChunks)
        let meetingID = "video-and-audio-live-recording-test-\(UUID().uuidString)"
        let outputRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InsightKit")
            .appendingPathComponent(meetingID)
        let composer = ReviewMediaComposerSpy()
        let inspector = MediaAssetInspectorSpy(hasAudioTrack: false, durationSec: 2.0)
        let viewModel = LiveSessionViewModel(
            rpcClient: RPCClientMock(),
            sidecarManager: SidecarManager(),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: assembler,
            asrService: LiveASRService(),
            reviewMediaComposer: composer,
            mediaAssetInspector: inspector
        )
        defer { try? FileManager.default.removeItem(at: tmp) }
        defer { try? FileManager.default.removeItem(at: outputRoot) }

        _ = try assembler.append(samples: Array(repeating: Float(0.15), count: 8_000))
        viewModel.temporaryRecordingURL = videoURL

        let recordingURL = try XCTUnwrap(
            viewModel.prepareTemporaryRecordingForSave(
                meetingID: meetingID,
                expectedVisualMedia: true
            )
        )

        let call = try XCTUnwrap(composer.calls.first)
        XCTAssertEqual(inspector.checkedURLs, [videoURL])
        XCTAssertEqual(call.videoURL, videoURL)
        XCTAssertEqual(call.audioURL.pathExtension, "wav")
        XCTAssertEqual(recordingURL.lastPathComponent, "recording-with-audio.mp4")
        XCTAssertEqual(recordingURL, call.outputURL)
        XCTAssertEqual(viewModel.temporaryRecordingURL, recordingURL)
        XCTAssertEqual(viewModel.mediaURL, recordingURL)
        XCTAssertEqual(viewModel.reviewSourceMediaURL, recordingURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordingURL.path))
        XCTAssertNil(viewModel.recordingStatusMessage)
        XCTAssertNil(viewModel.reviewSourceStatusMessage)
    }

    func testPrepareTemporaryRecordingPassesCaptureTimelineToReviewMediaComposer() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InsightKitVideoAudioTimeline_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let videoURL = tmp.appendingPathComponent("recording.mp4")
        try Data([0, 0, 0, 16, 102, 116, 121, 112]).write(to: videoURL)
        let audioChunks = tmp.appendingPathComponent("chunks", isDirectory: true)
        let assembler = ChunkAssembler(chunkDurationSec: 2, sampleRate: 16_000, chunkDir: audioChunks)
        let meetingID = "video-audio-timeline-test-\(UUID().uuidString)"
        let outputRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InsightKit")
            .appendingPathComponent(meetingID)
        let composer = ReviewMediaComposerSpy()
        let inspector = MediaAssetInspectorSpy(hasAudioTrack: false, durationSec: 2.0)
        let viewModel = LiveSessionViewModel(
            rpcClient: RPCClientMock(),
            sidecarManager: SidecarManager(),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: assembler,
            asrService: LiveASRService(),
            reviewMediaComposer: composer,
            mediaAssetInspector: inspector
        )
        defer { try? FileManager.default.removeItem(at: tmp) }
        defer { try? FileManager.default.removeItem(at: outputRoot) }

        _ = try assembler.append(samples: Array(repeating: Float(0.15), count: 8_000))
        viewModel.temporaryRecordingURL = videoURL
        viewModel.captureTimeline.markVideoStart(at: 100)
        viewModel.captureTimeline.markAudioStartIfNeeded(at: 101.25)

        _ = try XCTUnwrap(
            viewModel.prepareTemporaryRecordingForSave(
                meetingID: meetingID,
                expectedVisualMedia: true
            )
        )

        let call = try XCTUnwrap(composer.calls.first)
        XCTAssertEqual(call.timeline.videoStartSec, 0, accuracy: 0.001)
        XCTAssertEqual(call.timeline.audioStartSec, 1.25, accuracy: 0.001)

        let sidecarURL = viewModel.captureTimelineSidecarURL(meetingID: meetingID)
        let sidecar = try JSONDecoder().decode(
            LiveMediaCaptureTimelineSidecarFixture.self,
            from: Data(contentsOf: sidecarURL)
        )
        XCTAssertEqual(sidecar.compositionTimeline.videoStartSec, 0, accuracy: 0.001)
        XCTAssertEqual(sidecar.compositionTimeline.audioStartSec, 1.25, accuracy: 0.001)
    }

    func testPrepareTemporaryRecordingPassesPauseAdjustedTimelineToReviewMediaComposer() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InsightKitVideoAudioPauseTimeline_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let videoURL = tmp.appendingPathComponent("recording.mp4")
        try Data([0, 0, 0, 16, 102, 116, 121, 112]).write(to: videoURL)
        let audioChunks = tmp.appendingPathComponent("chunks", isDirectory: true)
        let assembler = ChunkAssembler(chunkDurationSec: 2, sampleRate: 16_000, chunkDir: audioChunks)
        let meetingID = "video-audio-pause-timeline-test-\(UUID().uuidString)"
        let outputRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InsightKit")
            .appendingPathComponent(meetingID)
        let composer = ReviewMediaComposerSpy()
        let inspector = MediaAssetInspectorSpy(hasAudioTrack: false, durationSec: 2.0)
        let viewModel = LiveSessionViewModel(
            rpcClient: RPCClientMock(),
            sidecarManager: SidecarManager(),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: assembler,
            asrService: LiveASRService(),
            reviewMediaComposer: composer,
            mediaAssetInspector: inspector
        )
        defer { try? FileManager.default.removeItem(at: tmp) }
        defer { try? FileManager.default.removeItem(at: outputRoot) }

        _ = try assembler.append(samples: Array(repeating: Float(0.15), count: 8_000))
        viewModel.temporaryRecordingURL = videoURL
        viewModel.captureTimeline.markVideoStart(at: 100)
        viewModel.captureTimeline.markPauseStart(at: 102)
        viewModel.captureTimeline.markPauseEnd(at: 112)
        viewModel.captureTimeline.markAudioStartIfNeeded(at: 115)

        _ = try XCTUnwrap(
            viewModel.prepareTemporaryRecordingForSave(
                meetingID: meetingID,
                expectedVisualMedia: true
            )
        )

        let call = try XCTUnwrap(composer.calls.first)
        XCTAssertEqual(call.timeline.videoStartSec, 0, accuracy: 0.001)
        XCTAssertEqual(call.timeline.audioStartSec, 5, accuracy: 0.001)
        XCTAssertEqual(call.timeline.videoPauseIntervals.count, 1)
        XCTAssertEqual(call.timeline.videoPauseIntervals.first?.startSec ?? 0, 2, accuracy: 0.001)
        XCTAssertEqual(call.timeline.videoPauseIntervals.first?.endSec ?? 0, 12, accuracy: 0.001)

        let sidecarURL = viewModel.captureTimelineSidecarURL(meetingID: meetingID)
        let sidecar = try JSONDecoder().decode(
            LiveMediaCaptureTimelineSidecarFixture.self,
            from: Data(contentsOf: sidecarURL)
        )
        XCTAssertEqual(sidecar.compositionTimeline.videoStartSec, 0, accuracy: 0.001)
        XCTAssertEqual(sidecar.compositionTimeline.audioStartSec, 5, accuracy: 0.001)
        XCTAssertEqual(sidecar.compositionTimeline.videoPauseIntervals.count, 1)
        XCTAssertEqual(sidecar.pauseIntervals.count, 1)
        XCTAssertEqual(sidecar.pauseIntervals.first?.durationSec ?? 0, 10, accuracy: 0.001)
    }


    func testPrepareTemporaryRecordingKeepsOriginalVideoWhenItAlreadyHasAudio() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InsightKitVideoWithNativeAudio_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let videoURL = tmp.appendingPathComponent("recording.mp4")
        try Data([0, 0, 0, 16, 102, 116, 121, 112]).write(to: videoURL)
        let audioChunks = tmp.appendingPathComponent("chunks", isDirectory: true)
        let assembler = ChunkAssembler(chunkDurationSec: 2, sampleRate: 16_000, chunkDir: audioChunks)
        let composer = ReviewMediaComposerSpy()
        let inspector = MediaAssetInspectorSpy(hasAudioTrack: true, durationSec: 2.0)
        let viewModel = LiveSessionViewModel(
            rpcClient: RPCClientMock(),
            sidecarManager: SidecarManager(),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: assembler,
            asrService: LiveASRService(),
            reviewMediaComposer: composer,
            mediaAssetInspector: inspector
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try assembler.append(samples: Array(repeating: Float(0.15), count: 8_000))
        viewModel.temporaryRecordingURL = videoURL

        let recordingURL = try XCTUnwrap(
            viewModel.prepareTemporaryRecordingForSave(
                meetingID: "video-with-native-audio-test",
                expectedVisualMedia: true
            )
        )

        XCTAssertEqual(inspector.checkedURLs, [videoURL])
        XCTAssertTrue(composer.calls.isEmpty)
        XCTAssertEqual(recordingURL, videoURL)
        XCTAssertEqual(viewModel.temporaryRecordingURL, videoURL)
        XCTAssertEqual(viewModel.mediaURL, videoURL)
        XCTAssertEqual(viewModel.reviewSourceMediaURL, videoURL)
        XCTAssertNil(viewModel.recordingStatusMessage)
        XCTAssertNil(viewModel.reviewSourceStatusMessage)
    }

    func testPrepareTemporaryRecordingShowsAudioUnavailableStatusWhenVideoHasNoCapturedAudio() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InsightKitVideoWithoutAudioLiveRecording_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let videoURL = tmp.appendingPathComponent("recording.mp4")
        try Data([0, 0, 0, 16, 102, 116, 121, 112]).write(to: videoURL)
        let meetingID = "video-without-audio-live-recording-test-\(UUID().uuidString)"
        let outputRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InsightKit")
            .appendingPathComponent(meetingID)
        let viewModel = LiveSessionViewModel(
            rpcClient: RPCClientMock(),
            sidecarManager: SidecarManager(),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: ChunkAssembler(),
            asrService: LiveASRService(),
            mediaAssetInspector: MediaAssetInspectorSpy(hasAudioTrack: false, durationSec: 2.0)
        )
        defer { try? FileManager.default.removeItem(at: tmp) }
        defer { try? FileManager.default.removeItem(at: outputRoot) }

        viewModel.temporaryRecordingURL = videoURL

        let recordingURL = try XCTUnwrap(
            viewModel.prepareTemporaryRecordingForSave(
                meetingID: meetingID,
                expectedVisualMedia: true
            )
        )

        XCTAssertEqual(recordingURL, videoURL)
        XCTAssertEqual(viewModel.mediaURL, videoURL)
        XCTAssertEqual(viewModel.reviewSourceMediaURL, videoURL)
        XCTAssertTrue(viewModel.reviewSourceStatusMessage?.contains("没有可播放音频") == true)
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

    func testSaveToRecordsPersistsPresentationCaptureStatus() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InsightKitLiveSavePresentation_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let recordingURL = tmp.appendingPathComponent("recording.mp4")
        try Data("fake mp4".utf8).write(to: recordingURL)
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
        viewModel.pendingPresentationCaptureStatus = .screenOnlyFallback

        var cancellables = Set<AnyCancellable>()
        let exp = expectation(description: "live records.save presentation status")
        exp.assertForOverFulfill = false
        viewModel.$lastExportPath
            .dropFirst()
            .sink { path in
                if !path.isEmpty {
                    exp.fulfill()
                }
            }
            .store(in: &cancellables)

        viewModel.saveToRecords(meetingID: "live-save-presentation-status-test")

        wait(for: [exp], timeout: 5.0)
        XCTAssertEqual(rpcClient.recordsSaveCalls.first?.presentationStatus, .screenOnlyFallback)
    }

    func testSaveToRecordsPersistsScreenPlusCameraCaptureStatus() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InsightKitLiveSaveCameraOverlay_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let recordingURL = tmp.appendingPathComponent("recording.mp4")
        try Data("fake mp4".utf8).write(to: recordingURL)
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
        viewModel.pendingPresentationCaptureStatus = .screenPlusCameraCaptured

        var cancellables = Set<AnyCancellable>()
        let exp = expectation(description: "live records.save screen plus camera presentation status")
        exp.assertForOverFulfill = false
        viewModel.$lastExportPath
            .dropFirst()
            .sink { path in
                if !path.isEmpty {
                    exp.fulfill()
                }
            }
            .store(in: &cancellables)

        viewModel.saveToRecords(meetingID: "live-save-screen-plus-camera-status-test")

        wait(for: [exp], timeout: 5.0)
        XCTAssertEqual(rpcClient.recordsSaveCalls.first?.presentationStatus, .screenPlusCameraCaptured)
    }

    func testSaveToRecordsDowngradesPresenterOverlayWhenFinalMediaIsAudioOnly() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InsightKitLiveSavePresentationAudioOnly_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let recordingURL = tmp.appendingPathComponent("recording.wav")
        try Data("fake wav".utf8).write(to: recordingURL)
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
        viewModel.pendingPresentationCaptureStatus = .presenterOverlayCaptured

        var cancellables = Set<AnyCancellable>()
        let exp = expectation(description: "live records.save downgraded presentation status")
        exp.assertForOverFulfill = false
        viewModel.$lastExportPath
            .dropFirst()
            .sink { path in
                if !path.isEmpty {
                    exp.fulfill()
                }
            }
            .store(in: &cancellables)

        viewModel.saveToRecords(meetingID: "live-save-presentation-audio-only-test")

        wait(for: [exp], timeout: 5.0)
        XCTAssertEqual(rpcClient.recordsSaveCalls.first?.presentationStatus, .visualMediaUnavailable)
        XCTAssertEqual(rpcClient.recordsSaveCalls.first?.mediaType, "audio")
    }

    func testSaveToRecordsDowngradesScreenPlusCameraWhenFinalMediaIsAudioOnly() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InsightKitLiveSaveCameraOverlayAudioOnly_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let recordingURL = tmp.appendingPathComponent("recording.wav")
        try Data("fake wav".utf8).write(to: recordingURL)
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
        viewModel.pendingPresentationCaptureStatus = .screenPlusCameraCaptured

        var cancellables = Set<AnyCancellable>()
        let exp = expectation(description: "live records.save downgraded screen plus camera status")
        exp.assertForOverFulfill = false
        viewModel.$lastExportPath
            .dropFirst()
            .sink { path in
                if !path.isEmpty {
                    exp.fulfill()
                }
            }
            .store(in: &cancellables)

        viewModel.saveToRecords(meetingID: "live-save-screen-plus-camera-audio-only-test")

        wait(for: [exp], timeout: 5.0)
        XCTAssertEqual(rpcClient.recordsSaveCalls.first?.presentationStatus, .visualMediaUnavailable)
        XCTAssertEqual(rpcClient.recordsSaveCalls.first?.mediaType, "audio")
    }

    func testSaveToRecordsUsesPlayableMediaDurationWhenAvailable() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InsightKitLiveSavePlayableDuration_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let recordingURL = tmp.appendingPathComponent("recording.mp4")
        try Data("fake mp4".utf8).write(to: recordingURL)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let rpcClient = RPCClientMock()
        let inspector = MediaAssetInspectorSpy(hasAudioTrack: true, durationSec: 39.95)
        let viewModel = LiveSessionViewModel(
            rpcClient: rpcClient,
            sidecarManager: SidecarManager(),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: ChunkAssembler(),
            asrService: LiveASRService(),
            mediaAssetInspector: inspector
        )
        viewModel.temporaryRecordingURL = recordingURL
        viewModel.recordingDuration = 47.0

        var cancellables = Set<AnyCancellable>()
        let exp = expectation(description: "live records.save playable duration")
        exp.assertForOverFulfill = false
        viewModel.$lastExportPath
            .dropFirst()
            .sink { path in
                if !path.isEmpty {
                    exp.fulfill()
                }
            }
            .store(in: &cancellables)

        viewModel.saveToRecords(meetingID: "live-save-playable-duration-test")

        wait(for: [exp], timeout: 5.0)
        let call = try XCTUnwrap(rpcClient.recordsSaveCalls.first)
        XCTAssertEqual(call.sourcePath, recordingURL.path)
        XCTAssertEqual(call.mediaType, "video")
        XCTAssertEqual(call.durationSec, 39.95, accuracy: 0.001)
    }

    func testStopLiveSessionDrainsQueuedChunksBeforeSavingRecord() throws {
        let pipeline = LiveTranscriptProcessingMock()
        pipeline.outcome = LiveTranscriptPipelineOutcome(
            chunkIndex: 1,
            latencyMs: 10,
            ingestedCount: 1,
            transcriptSegments: [
                TranscriptSegment(startMs: 1_000, endMs: 2_000, speaker: "SPEAKER_00", source: "mic", text: "queued audio")
            ],
            captureState: .capturing,
            firstSegmentMs: 1_000,
            lastTranscriptAt: Date(),
            refresh: .none,
            providerMetric: nil,
            analysisRuntimeState: nil,
            errorMessage: nil
        )
        let rpcClient = RPCClientMock()
        let viewModel = LiveSessionViewModel(
            rpcClient: rpcClient,
            sidecarManager: SidecarManager(),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: ChunkAssembler(),
            asrService: LiveASRService(),
            transcriptPipeline: pipeline
        )
        viewModel.asrWarmStatus = ASRWarmStatus(
            ready: true,
            state: .ready,
            inProgress: false,
            attempt: 1,
            lastWarmMs: 1_000,
            lastError: ""
        )
        viewModel.stateQueue.sync {
            viewModel._isRunningLock.lock()
            viewModel._isRunning = true
            viewModel._isRunningLock.unlock()
            viewModel._sessionState.activeMeetingID = "live-stop-drain-test"
            viewModel.activeMode = .microphone
        }
        viewModel.sessionHandle = SessionHandle(activeMeetingID: "live-stop-drain-test", lastMeetingID: nil)
        viewModel.queuedChunks = [
            makeLiveSessionTestChunk(index: 1),
            makeLiveSessionTestChunk(index: 2),
        ]

        var cancellables = Set<AnyCancellable>()
        let exp = expectation(description: "record saved after queued chunks drain")
        exp.assertForOverFulfill = false
        viewModel.$lastExportPath
            .dropFirst()
            .sink { path in
                if !path.isEmpty {
                    exp.fulfill()
                }
            }
            .store(in: &cancellables)

        viewModel.stopLiveSession()

        wait(for: [exp], timeout: 5.0)
        XCTAssertEqual(pipeline.processCalls.map { $0.chunk.index }, [1, 2])
        XCTAssertEqual(rpcClient.recordsSaveCalls.first?.meetingID, "live-stop-drain-test")
    }

    func testSaveToRecordsReplacesLiveChunkTranscriptWithFinalMediaTranscript() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InsightKitLiveMediaTranscript_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let recordingURL = tmp.appendingPathComponent("recording.wav")
        try Data("RIFF----WAVE".utf8).write(to: recordingURL)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let rpcClient = RPCClientMock()
        rpcClient.asrTranscribeMediaStub = [
            RPCSegmentDelta(
                startMs: 22_000,
                endMs: 25_500,
                speaker: "SPEAKER_00",
                text: "final media aligned transcript",
                confidence: 0.91,
                source: "media"
            )
        ]
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
        viewModel.transcriptSegments = [
            TranscriptSegment(startMs: 0, endMs: 1_000, speaker: "live", source: "mic", text: "stale live chunk transcript")
        ]

        var cancellables = Set<AnyCancellable>()
        let exp = expectation(description: "live records.save uses media transcript")
        exp.assertForOverFulfill = false
        viewModel.$lastExportPath
            .dropFirst()
            .sink { path in
                if !path.isEmpty {
                    exp.fulfill()
                }
            }
            .store(in: &cancellables)

        viewModel.saveToRecords(meetingID: "live-media-transcript-test")

        wait(for: [exp], timeout: 5.0)
        XCTAssertEqual(rpcClient.asrTranscribeMediaCalls.map(\.mediaPath), [recordingURL.path])
        let savedSegments = try XCTUnwrap(rpcClient.recordsSaveSegments.first)
        XCTAssertEqual(savedSegments.count, 1)
        XCTAssertEqual(savedSegments.first?["start_ms"] as? Int, 22_000)
        XCTAssertEqual(savedSegments.first?["end_ms"] as? Int, 25_500)
        XCTAssertEqual(savedSegments.first?["text"] as? String, "final media aligned transcript")
        XCTAssertEqual(savedSegments.first?["source"] as? String, "media")
    }

    func testSaveToRecordsCanUseInjectedAppleSpeechFinalMediaTranscriber() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InsightKitAppleSpeechMediaTranscript_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let recordingURL = tmp.appendingPathComponent("recording.wav")
        try Data("RIFF----WAVE".utf8).write(to: recordingURL)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let rpcClient = RPCClientMock()
        let finalMediaTranscriber = FinalMediaTranscriberSpy(results: [
            .success([
                TranscriptSegment(
                    startMs: 0,
                    endMs: 840,
                    speaker: "Apple Speech",
                    source: "apple-speech",
                    text: "Hello, world."
                ),
            ]),
        ])
        let viewModel = LiveSessionViewModel(
            rpcClient: rpcClient,
            sidecarManager: SidecarManager(),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: ChunkAssembler(),
            asrService: LiveASRService(),
            finalMediaTranscriber: finalMediaTranscriber
        )
        viewModel.temporaryRecordingURL = recordingURL
        viewModel.transcriptSegments = [
            TranscriptSegment(startMs: 0, endMs: 1_000, speaker: "live", source: "mic", text: "stale live chunk transcript")
        ]

        var cancellables = Set<AnyCancellable>()
        let exp = expectation(description: "live records.save uses apple speech media transcript")
        exp.assertForOverFulfill = false
        viewModel.$lastExportPath
            .dropFirst()
            .sink { path in
                if !path.isEmpty {
                    exp.fulfill()
                }
            }
            .store(in: &cancellables)

        viewModel.saveToRecords(meetingID: "apple-speech-media-transcript-test")

        wait(for: [exp], timeout: 5.0)
        XCTAssertEqual(finalMediaTranscriber.calls.map(\.mediaPath), [recordingURL.path])
        XCTAssertTrue(rpcClient.asrTranscribeMediaCalls.isEmpty)
        let savedSegments = try XCTUnwrap(rpcClient.recordsSaveSegments.first)
        XCTAssertEqual(savedSegments.count, 1)
        XCTAssertEqual(savedSegments.first?["start_ms"] as? Int, 0)
        XCTAssertEqual(savedSegments.first?["end_ms"] as? Int, 840)
        XCTAssertEqual(savedSegments.first?["speaker"] as? String, "Apple Speech")
        XCTAssertEqual(savedSegments.first?["text"] as? String, "Hello, world.")
        XCTAssertEqual(savedSegments.first?["source"] as? String, "apple-speech")
    }

    func testFinalMediaRouterKeepsVideoContainersOnExistingRPCTranscriber() throws {
        let rpcClient = RPCClientMock()
        rpcClient.asrTranscribeMediaStub = [
            RPCSegmentDelta(
                startMs: 1_000,
                endMs: 2_000,
                speaker: "SPEAKER_00",
                text: "video media remains on existing transcriber",
                confidence: 0.9,
                source: "media"
            ),
        ]
        let router = FinalMediaTranscriptionRouter(
            rpcClient: rpcClient,
            appleSpeechPrototypeEnabled: { true }
        )

        let segments = try router.transcribeFinalMedia(mediaPath: "/tmp/recording.mp4", source: "media")

        XCTAssertEqual(rpcClient.asrTranscribeMediaCalls.map(\.mediaPath), ["/tmp/recording.mp4"])
        XCTAssertEqual(segments.map(\.text), ["video media remains on existing transcriber"])
        XCTAssertEqual(segments.map(\.source), ["media"])
    }

    func testSaveToRecordsDoesNotFallbackToLiveChunkTranscriptWhenFinalMediaTranscriptionFails() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InsightKitLiveMediaTranscriptFailure_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let recordingURL = tmp.appendingPathComponent("recording.wav")
        try Data("RIFF----WAVE".utf8).write(to: recordingURL)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let rpcClient = RPCClientMock()
        rpcClient.asrTranscribeMediaError = NSError(
            domain: "InsightKitTest",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "media transcription failed"]
        )
        let viewModel = LiveSessionViewModel(
            rpcClient: rpcClient,
            sidecarManager: SidecarManager(),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: ChunkAssembler(),
            asrService: LiveASRService()
        )
        viewModel.finalMediaTranscriptRetryDelays = []
        viewModel.temporaryRecordingURL = recordingURL
        viewModel.transcriptSegments = [
            TranscriptSegment(startMs: 0, endMs: 1_000, speaker: "live", source: "mic", text: "stale live chunk transcript")
        ]

        var cancellables = Set<AnyCancellable>()
        let exp = expectation(description: "live records.save keeps media without stale transcript")
        exp.assertForOverFulfill = false
        viewModel.$lastExportPath
            .dropFirst()
            .sink { path in
                if !path.isEmpty {
                    exp.fulfill()
                }
            }
            .store(in: &cancellables)

        viewModel.saveToRecords(meetingID: "live-media-transcript-failure-test")

        wait(for: [exp], timeout: 5.0)
        XCTAssertEqual(rpcClient.asrTranscribeMediaCalls.map(\.mediaPath), [recordingURL.path])
        XCTAssertEqual(rpcClient.transcriptReplaceCalls.first?.segments.count, 0)
        XCTAssertEqual(rpcClient.recordsSaveSegments.first?.count, 0)
    }

    func testSaveToRecordsRetriesFinalMediaTranscriptionBeforeSavingEmptyTranscript() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InsightKitLiveMediaTranscriptRetry_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let recordingURL = tmp.appendingPathComponent("recording.wav")
        try Data("RIFF----WAVE".utf8).write(to: recordingURL)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let rpcClient = RPCClientMock()
        rpcClient.asrTranscribeMediaQueue = [
            .failure(NSError(
                domain: "InsightKitTest",
                code: 43,
                userInfo: [NSLocalizedDescriptionKey: "media transcription still finalizing"]
            )),
            .success([
                RPCSegmentDelta(
                    startMs: 11_000,
                    endMs: 14_500,
                    speaker: "SPEAKER_00",
                    text: "retry succeeded on final media timeline",
                    confidence: 0.93,
                    source: "media"
                )
            ]),
        ]
        let viewModel = LiveSessionViewModel(
            rpcClient: rpcClient,
            sidecarManager: SidecarManager(),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: ChunkAssembler(),
            asrService: LiveASRService()
        )
        viewModel.finalMediaTranscriptRetryDelays = [0]
        viewModel.temporaryRecordingURL = recordingURL
        viewModel.transcriptSegments = [
            TranscriptSegment(startMs: 0, endMs: 1_000, speaker: "live", source: "mic", text: "stale live chunk transcript")
        ]

        var cancellables = Set<AnyCancellable>()
        let exp = expectation(description: "live records.save retries media transcript")
        exp.assertForOverFulfill = false
        viewModel.$lastExportPath
            .dropFirst()
            .sink { path in
                if !path.isEmpty {
                    exp.fulfill()
                }
            }
            .store(in: &cancellables)

        viewModel.saveToRecords(meetingID: "live-media-transcript-retry-test")

        wait(for: [exp], timeout: 5.0)
        XCTAssertEqual(rpcClient.asrTranscribeMediaCalls.count, 2)
        let savedSegments = try XCTUnwrap(rpcClient.recordsSaveSegments.first)
        XCTAssertEqual(savedSegments.count, 1)
        XCTAssertEqual(savedSegments.first?["start_ms"] as? Int, 11_000)
        XCTAssertEqual(savedSegments.first?["text"] as? String, "retry succeeded on final media timeline")
        XCTAssertEqual(savedSegments.first?["source"] as? String, "media")
    }

    func testBuildFinalInsightReplacesRuntimeTranscriptWithFinalMediaTranscriptBeforeGeneratingMinutes() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InsightKitLiveMediaFinalInsight_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let recordingURL = tmp.appendingPathComponent("recording.wav")
        try Data("RIFF----WAVE".utf8).write(to: recordingURL)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let rpcClient = RPCClientMock()
        rpcClient.asrTranscribeMediaStub = [
            RPCSegmentDelta(
                startMs: 34_000,
                endMs: 39_000,
                speaker: "SPEAKER_00",
                text: "media transcript used for final minutes",
                confidence: 0.88,
                source: "media"
            )
        ]
        let socketPath = "/tmp/insightkit-live-final-\(UUID().uuidString).sock"
        let sidecarSocket = ConnectableSidecarSocket(socketPath: socketPath)
        try sidecarSocket.start()
        defer { sidecarSocket.stop() }

        let viewModel = LiveSessionViewModel(
            rpcClient: rpcClient,
            sidecarManager: SidecarManager(socketPath: socketPath, startupTimeoutSec: 3),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: ChunkAssembler(),
            asrService: LiveASRService()
        )
        viewModel.temporaryRecordingURL = recordingURL
        viewModel.transcriptSegments = [
            TranscriptSegment(startMs: 0, endMs: 1_000, speaker: "live", source: "mic", text: "stale live transcript")
        ]
        viewModel.stateQueue.sync {
            viewModel._sessionState.lastMeetingID = "live-final-media-timeline-test"
        }

        var cancellables = Set<AnyCancellable>()
        let exp = expectation(description: "final insight saved")
        exp.assertForOverFulfill = false
        viewModel.$lastExportPath
            .dropFirst()
            .sink { path in
                if !path.isEmpty {
                    exp.fulfill()
                }
            }
            .store(in: &cancellables)

        viewModel.buildFinalInsight()

        wait(for: [exp], timeout: 5.0)
        XCTAssertEqual(Array(rpcClient.methodCalls.prefix(3)), [
            "asr.transcribe_media",
            "transcript.replace",
            "insight.build_final",
        ])
        let replace = try XCTUnwrap(rpcClient.transcriptReplaceCalls.first)
        XCTAssertEqual(replace.meetingID, "live-final-media-timeline-test")
        XCTAssertEqual(replace.segments.map(\.startMs), [34_000])
        XCTAssertEqual(replace.segments.map(\.text), ["media transcript used for final minutes"])
    }

    func testLiveSmartMinutesSpeakerRenameUpdatesRuntimeMinutesPackageAndPersistedRecord() throws {
        let root = RecordExportTestFixture.makeRoot(prefix: "InsightKitLiveSpeakerRename")
        let recordID = "live-speaker-rename"
        let recordPath = try RecordExportTestFixture.seedRecord(root: root, recordID: recordID, source: .live)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        [
          {"start_ms":1000,"end_ms":3000,"speaker":"SPEAKER_00","text":"Alice should appear everywhere."}
        ]
        """.write(to: recordPath.appendingPathComponent("transcript.json"), atomically: true, encoding: .utf8)

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
        viewModel.transcriptSegments = [
            TranscriptSegment(
                startMs: 1_000,
                endMs: 3_000,
                speaker: "SPEAKER_00",
                source: "media",
                text: "Alice should appear everywhere."
            )
        ]
        viewModel.smartMinutesData = SmartMinutes(
            structuredSummary: "Speaker correction summary.",
            speakerSummaries: [
                SpeakerMinutesSummary(speakerName: "SPEAKER_00", summary: "Original speaker summary.")
            ]
        )
        viewModel.lastInsightPackage = InsightPackageV1(
            sessionOverview: .init(title: "Live", overview: "Speaker correction summary.", topics: []),
            highlightInsights: [
                .init(
                    quote: "Important quote",
                    reason: "Important reason",
                    speaker: "SPEAKER_00",
                    evidenceSpan: .init(startMs: 1_000, endMs: 3_000)
                )
            ],
            speakerPerspectives: [
                .init(
                    speaker: "SPEAKER_00",
                    viewpoints: ["Original speaker summary."],
                    evidenceSpans: [.init(startMs: 1_000, endMs: 3_000)]
                )
            ],
            decisionLedger: [],
            actionTracks: [],
            timelineBeats: [],
            provenanceLinks: []
        )
        viewModel.finalizedMediaTranscriptCache = (
            mediaPath: "/tmp/recording.wav",
            segments: viewModel.transcriptSegments
        )
        viewModel.stateQueue.sync {
            viewModel._sessionState.lastMeetingID = recordID
        }

        XCTAssertEqual(viewModel.editableSpeakers, ["SPEAKER_00"])

        viewModel.renameSpeaker(from: "SPEAKER_00", to: "Alice")
        drainMainQueue()

        XCTAssertEqual(viewModel.transcriptSegments.map(\.speaker), ["Alice"])
        XCTAssertEqual(viewModel.smartMinutesData?.speakerSummaries.map(\.speakerName), ["Alice"])
        XCTAssertEqual(viewModel.lastInsightPackage?.speakerPerspectives.map(\.speaker), ["Alice"])
        XCTAssertEqual(viewModel.lastInsightPackage?.highlightInsights.map(\.speaker), ["Alice"])
        XCTAssertEqual(viewModel.finalizedMediaTranscriptCache?.segments.map(\.speaker), ["Alice"])

        let persistedTranscript = try String(contentsOf: recordPath.appendingPathComponent("transcript.json"), encoding: .utf8)
        XCTAssertTrue(persistedTranscript.contains("Alice"))
        XCTAssertFalse(persistedTranscript.contains("SPEAKER_00"))

        let markdown = try RecordDocumentExporter.renderMarkdown(
            metadata: recordsService.records.first ?? RecordMetadata(
                id: recordID,
                createdAt: Date(),
                duration: 30,
                mediaType: .audio,
                source: .live,
                userTags: [],
                autoTags: [],
                summaryPreview: "Speaker correction"
            ),
            recordPath: recordPath
        )
        XCTAssertTrue(markdown.contains("Alice"))

        let replace = try XCTUnwrap(rpcClient.transcriptReplaceCalls.first)
        XCTAssertEqual(replace.meetingID, recordID)
        XCTAssertEqual(replace.segments.map(\.speaker), ["Alice"])
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

private final class ReviewMediaComposerSpy: ReviewMediaComposing {
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
        try Data("merged mp4".utf8).write(to: outputURL)
        return outputURL
    }
}

private struct LiveMediaCaptureTimelineSidecarFixture: Decodable {
    let pauseIntervals: [LiveMediaCapturePauseInterval]
    let compositionTimeline: ReviewMediaCompositionTimeline
}

private final class MediaAssetInspectorSpy: MediaAssetInspecting {
    private let result: Bool
    private let durationResult: Double?
    private(set) var checkedURLs: [URL] = []
    private(set) var durationURLs: [URL] = []

    init(hasAudioTrack: Bool, durationSec: Double? = nil) {
        self.result = hasAudioTrack
        self.durationResult = durationSec
    }

    func hasAudioTrack(url: URL) -> Bool {
        checkedURLs.append(url)
        return result
    }

    func durationSec(url: URL) -> Double? {
        durationURLs.append(url)
        return durationResult
    }
}

private final class FinalMediaTranscriberSpy: FinalMediaTranscribing {
    private var results: [Result<[TranscriptSegment], Error>]
    private(set) var calls: [(mediaPath: String, source: String)] = []

    init(results: [Result<[TranscriptSegment], Error>]) {
        self.results = results
    }

    func transcribeFinalMedia(mediaPath: String, source: String) throws -> [TranscriptSegment] {
        calls.append((mediaPath, source))
        if results.isEmpty {
            return []
        }
        return try results.removeFirst().get()
    }
}

private final class ConnectableSidecarSocket {
    private let socketPath: String
    private var listenFD: Int32 = -1
    private var serverThread: Thread?
    private let finished = DispatchSemaphore(value: 0)

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func start() throws {
        _ = Darwin.unlink(socketPath)
        listenFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw posixError("socket") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= capacity else {
            Darwin.close(listenFD)
            listenFD = -1
            throw NSError(domain: "ConnectableSidecarSocket", code: Int(ENAMETOOLONG), userInfo: [
                NSLocalizedDescriptionKey: "Socket path is too long.",
            ])
        }

        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            buffer.initializeMemory(as: CChar.self, repeating: 0)
            _ = pathBytes.withUnsafeBytes { src in
                memcpy(buffer.baseAddress, src.baseAddress, min(buffer.count, src.count))
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddr in
                Darwin.bind(listenFD, sockAddr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let error = posixError("bind")
            Darwin.close(listenFD)
            listenFD = -1
            throw error
        }

        guard Darwin.listen(listenFD, 4) == 0 else {
            let error = posixError("listen")
            Darwin.close(listenFD)
            listenFD = -1
            throw error
        }

        serverThread = Thread { [weak self] in
            self?.run()
        }
        serverThread?.start()
    }

    func stop() {
        let fd = listenFD
        if fd >= 0 {
            listenFD = -1
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            _ = Darwin.close(fd)
        }
        _ = Darwin.unlink(socketPath)
        if serverThread != nil {
            _ = finished.wait(timeout: .now() + 1.0)
            serverThread = nil
        }
    }

    deinit {
        stop()
    }

    private func run() {
        defer { finished.signal() }
        while listenFD >= 0 {
            let clientFD = Darwin.accept(listenFD, nil, nil)
            guard clientFD >= 0 else { return }
            var noSigPipe: Int32 = 1
            _ = setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            var buffer = [UInt8](repeating: 0, count: 4096)
            let readN = Darwin.read(clientFD, &buffer, buffer.count)
            if readN > 0 {
                let response = #"{"jsonrpc":"2.0","result":{"ok":true}}"#
                response.withCString { pointer in
                    _ = Darwin.write(clientFD, pointer, strlen(pointer))
                }
                _ = Darwin.shutdown(clientFD, SHUT_RDWR)
            }
            Darwin.close(clientFD)
        }
    }

    private func posixError(_ operation: String) -> NSError {
        NSError(domain: "ConnectableSidecarSocket", code: Int(errno), userInfo: [
            NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(errno)))",
        ])
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
