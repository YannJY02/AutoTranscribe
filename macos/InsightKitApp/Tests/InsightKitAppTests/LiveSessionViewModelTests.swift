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
}
