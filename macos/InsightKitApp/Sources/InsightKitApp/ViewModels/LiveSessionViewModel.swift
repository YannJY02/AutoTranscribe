import AVFoundation
import AppKit
import Combine
import Foundation

final class LiveSessionViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var selectedTab: InsightTab = .sessionOverview
    @Published var readingMode = true
    @Published var focusMode = false
    @Published var isExecutionPanelVisible = false

    @Published var inputMode: AudioInputMode = .microphone
    @Published var captureState: CaptureState = .idle
    @Published var transcriptSegments: [TranscriptSegment] = []
    @Published var workbench: InsightWorkbenchState = .empty
    @Published var actionItems: [ActionItem] = []
    @Published var metrics = LiveSessionMetrics()
    @Published var selectedEvidence: EvidenceRange?
    @Published var lastExportPath: String = ""

    @Published var systemAudioSources: [SystemAudioSourceItem] = []
    @Published var selectedSystemSourceID: String?
    @Published var isSystemAudioPickerPresented = false
    @Published var errorMessage: String?
    @Published var sidecarLabel = "sidecar: unknown"
    @Published var sidecarHealth = SidecarHealth.unknown
    @Published var permissionState: PermissionState = .unknown
    @Published var sessionHandle = SessionHandle()
    @Published var analysisRuntimeState: AnalysisRuntimeState = .ready
    @Published var captureHealth = CaptureHealthSnapshot.empty
    @Published var asrBackendStatus = ASRBackendStatus(
        configuredDevice: "auto",
        configuredComputeType: "int8",
        device: "auto",
        computeType: "int8",
        resolved: "",
        supportedComputeTypes: []
    )
    @Published var asrWarmStatus = ASRWarmStatus(ready: false, state: .idle, inProgress: false, attempt: 0, lastWarmMs: 0, lastError: "")
    @Published var liveWarmup = LiveWarmupSnapshot.empty

    // Services — internal so extensions can access them
    let rpcClient: InsightRPCClientProtocol
    let sidecarManager: SidecarManager
    let micCapture: MicCaptureService
    let systemAudioCapture: SystemAudioCaptureService
    let mixBus: AudioMixBus
    let chunkAssembler: ChunkAssembler
    let asrService: LiveASRServiceProtocol
    let transcriptPipeline: LiveTranscriptProcessing
    let reviewMediaComposer: ReviewMediaComposing
    let mediaAssetInspector: MediaAssetInspecting
    let finalMediaTranscriber: FinalMediaTranscribing
    let transcriptRecoveryService: TranscriptRecoveryServicing
    let analyticsSubmit: (@escaping (ProductAnalytics) -> Void) -> Void
    let recordingUptime: () -> TimeInterval

    // Queues — internal so extensions can access them
    /// Captured audio must reach disk even while a synchronous ASR request is busy.
    let audioArchiveQueue = DispatchQueue(label: "InsightKit.LiveSession.AudioArchive")
    let pipelineQueue = DispatchQueue(label: "InsightKit.LiveSession.Pipeline")
    let stateQueue = DispatchQueue(label: "InsightKit.LiveSession.State")
    /// Dedicated GCD queue for blocking RPC I/O – avoids exhausting Swift's
    /// cooperative thread pool which would stall all async/SwiftUI work.
    let rpcQueue = DispatchQueue(label: "InsightKit.LiveSession.RPC", qos: .userInitiated)
    let runtimeStartupGroup = DispatchGroup()
    var liveBackgroundSession: LiveBackgroundSession?
    var liveSummaryQueue: BoundedLiveWorkQueue<LiveBackgroundSession, LiveInsightRefreshOutcome>?
    var liveSpeakerQueue: BoundedLiveWorkQueue<LiveSpeakerRequest, LiveSpeakerEnrichmentResult>?

    // Session state — internal so extensions can access them
    var activeMode: AudioInputMode = .microphone
    var insightRefreshSuspended = false
    var stopDrainingMeetingID: String?
    var audioCaptureDraining = false
    var runtimeSessionStartingMeetingID: String?
    var captureMonitorTask: Task<Void, Never>?
    var lastCaptureHintAt: Date?
    var recordingPaused = false
    var captureStartupTask: Task<Void, Never>?
    /// Provisional audio is retained for A/V alignment, but is not a recording
    /// until the selected visual writer accepts its first frame.
    var visualRecordingStartPending = false

    var _isRunning = false
    var _sessionState = SessionHandle()
    let _isRunningLock = NSLock()

    // Chunk queue state — internal so Capture extension can access them
    var queuedChunks: [AudioChunk] = []
    var chunkInFlight = false
    let maxQueuedChunks = 8
    let warmupBacklogPolicy = WarmupBacklogPolicy(maxChunks: 2, maxBufferedAudioMs: 8_000)

    // Warmup state — internal so Warmup extension can access them
    let warmupRetryPolicy = WarmupRetryPolicy(maxAutomaticRetries: 1, retryDelaySec: 2)
    let warmupPollIntervalNs: UInt64 = 400_000_000
    var warmupKickTask: Task<Void, Never>?
    var warmupPollTask: Task<Void, Never>?
    var warmupRetryTask: Task<Void, Never>?
    var warmupFailureCount = 0
    var warmupRetryScheduled = false

    // Audio level state — internal so Capture extension can access them
    var lastMicLevelDispatch: Date?
    var lastSystemLevelDispatch: Date?
    var lastMicLevel: Float = 0
    var lastSystemLevel: Float = 0

    // Phase 4: Panel protocol support
    @Published var sessionPhase: SessionPhase = .preparing
    @Published var chapters: [ChapterSummary] = []
    @Published var smartMinutesData: SmartMinutes?
    @Published var notes: [TimestampedNote] = []
    @Published var currentPlaybackTime: TimeInterval?
    @Published var mediaSeekRequest: MediaSeekRequest?
    @Published var reviewSourcePlaybackRequested = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var isRecordingPaused = false
    @Published var recordingStatusMessage: String?
    @Published var transcriptRecoveryStatusMessage: String?
    @Published var isFinalizingLiveSession = false
    @Published private(set) var isExporting = false
    @Published var visualPreviewSource: LiveVisualPreviewSource = .none
    @Published var capturePreviewStatusMessage: String?
    @Published var mediaURL: URL?
    @Published var reviewSourceMediaURL: URL?
    @Published var reviewSourceStatusMessage: String?
    let videoCaptureService = VideoCaptureService()
    var recordingDurationTimer: Timer?
    var recordingClockStartUptime: TimeInterval?
    var recordingDurationAtClockStart: TimeInterval = 0
    var visualSelectionUsesScreenOnlyFallback = false
    var visualPreviewGeneration = UUID()
    var visualPreviewSetupTask: Task<Void, Never>?
    var visualPreviewPreparationPending = false

    // Phase 5: Records persistence
    var recordsService: RecordsIndexService?
    var temporaryRecordingURL: URL?
    var finalizedMediaTranscriptCache: (mediaPath: String, segments: [TranscriptSegment])?
    var finalMediaTranscriptRetryDelays: [TimeInterval] = [1, 2, 4, 8, 15]
    var lastInsightPackage: InsightPackageV1?
    var captureTimeline = LiveMediaCaptureTimeline()
    var pendingPresentationCaptureStatus: LivePresentationCaptureStatus?
    var delayedSummaryUITestFixture: DelayedSummarySocketFixture?

    init(
        rpcClient: InsightRPCClientProtocol = InsightRPCClient(),
        sidecarManager: SidecarManager = SidecarManager(),
        micCapture: MicCaptureService = MicCaptureService(),
        systemAudioCapture: SystemAudioCaptureService = SystemAudioCaptureService(),
        mixBus: AudioMixBus = AudioMixBus(),
        chunkAssembler: ChunkAssembler = ChunkAssembler(),
        asrService: LiveASRServiceProtocol = LiveASRService(),
        transcriptPipeline: LiveTranscriptProcessing? = nil,
        backgroundClientFactory: (() -> InsightRPCClientProtocol)? = nil,
        reviewMediaComposer: ReviewMediaComposing = AVFoundationReviewMediaComposer(),
        mediaAssetInspector: MediaAssetInspecting = AVFoundationMediaAssetInspector(),
        finalMediaTranscriber: FinalMediaTranscribing? = nil,
        transcriptRecoveryService: TranscriptRecoveryServicing? = nil,
        analyticsSubmit: @escaping (@escaping (ProductAnalytics) -> Void) -> Void = ProductAnalytics.submit,
        recordingUptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.rpcClient = rpcClient
        self.sidecarManager = sidecarManager
        self.micCapture = micCapture
        self.systemAudioCapture = systemAudioCapture
        self.mixBus = mixBus
        self.chunkAssembler = chunkAssembler
        self.asrService = asrService
        self.reviewMediaComposer = reviewMediaComposer
        self.mediaAssetInspector = mediaAssetInspector
        self.finalMediaTranscriber = finalMediaTranscriber ?? FinalMediaTranscriptionRouter(rpcClient: rpcClient)
        self.transcriptRecoveryService = transcriptRecoveryService ?? TranscriptRecoveryService(rpcClient: rpcClient)
        self.analyticsSubmit = analyticsSubmit
        self.recordingUptime = recordingUptime
        self.transcriptPipeline = transcriptPipeline ?? LiveTranscriptPipeline(
            runtime: InsightRPCLiveTranscriptPipelineRuntime(rpcClient: rpcClient)
        )
        let makeBackgroundClient = backgroundClientFactory ?? { rpcClient.makeBackgroundClient() }
        let summaryClient = makeBackgroundClient()
        let speakerClient = makeBackgroundClient()
        liveSummaryQueue = BoundedLiveWorkQueue(
            label: "InsightKit.LiveSession.Summary", maximumPending: 1, coalescesPending: true,
            operation: { session in LiveInsightRefreshOutcome.run(client: summaryClient, meetingID: session.meetingID) },
            completion: { [weak self] session, result in
                if case .success(let outcome) = result { self?.applyLiveInsightOutcome(outcome, session: session) }
            }
        )
        liveSpeakerQueue = BoundedLiveWorkQueue(
            label: "InsightKit.LiveSession.Speaker", maximumPending: 8,
            operation: { request in
                try speakerClient.asrEnrichLiveChunk(meetingID: request.session.meetingID, chunkID: request.chunkID)
            },
            completion: { [weak self] request, result in self?.applyLiveSpeakerResult(result, request: request) }
        )

        configureAudioCaptureCallbacks()
        self.videoCaptureService.onRecordingFirstFrame = { [weak self] time in
            self?.stateQueue.sync {
                self?.captureTimeline.markVideoStart(at: time)
            }
        }

        configureForUITestingIfNeeded()
        refreshSidecarStatus()
    }

    deinit {
        shutdownForDeinit()
    }

    func shutdown() {
        stopLiveSession()
        sidecarManager.stop()
    }

    private func shutdownForDeinit() {
        stopDelayedSummaryUITestScenario()
        liveSummaryQueue?.invalidate()
        liveSpeakerQueue?.invalidate()
        captureMonitorTask?.cancel()
        captureStartupTask?.cancel()
        cancelWarmupTasks()
        stopRecordingDurationTimer()

        micCapture.onBuffer = nil
        systemAudioCapture.onBuffer = nil
        mixBus.onMixedSamples = nil
        videoCaptureService.onRecordingFirstFrame = nil

        micCapture.stop()
        Task { [systemAudioCapture] in
            await systemAudioCapture.stop()
        }
        videoCaptureService.stopCapture()
        chunkAssembler.reset()
        transcriptPipeline.reset()
        sidecarManager.stop()
    }

    // MARK: - Computed State

    var isRunning: Bool {
        _isRunningLock.lock()
        defer { _isRunningLock.unlock() }
        return _isRunning
    }

    var canStartSession: Bool {
        !isRunning && !isFinalizingLiveSession && captureStartupTask == nil && currentActiveMeetingID() == nil
    }
    var isPreparingRecording: Bool { isRunning && sessionPhase == .preparing }
    var isActivelyRecording: Bool {
        isRunning && sessionPhase == .running && !isRecordingPaused && !isFinalizingLiveSession
    }
    var canStopSession: Bool { isRunning }
    var canBuildFinal: Bool { currentBuildTargetID() != nil }
    var canExportDocument: Bool { currentBuildTargetID() != nil && !isExporting }
    var hasPersistedRecordForExport: Bool {
        RecordDocumentExporter.hasPersistedRecord(meetingID: currentBuildTargetID(), recordsService: recordsService)
    }
    var canChangeInputMode: Bool { !isRunning }

    func setAudioInputSources(microphoneEnabled: Bool, systemAudioEnabled: Bool) {
        guard canChangeInputMode else { return }
        switch (microphoneEnabled, systemAudioEnabled) {
        case (true, false): inputMode = .microphone
        case (false, true): inputMode = .systemAudio
        case (true, true): inputMode = .mixed
        case (false, false): return
        }
    }

    var isFinalizingRecording: Bool { isFinalizingLiveSession }

    var shouldHoldChunksForWarmup: Bool {
        !asrWarmStatus.ready || stateQueue.sync {
            runtimeSessionStartingMeetingID != nil || visualRecordingStartPending
        }
    }

    var activeCaptureState: CaptureState {
        LiveCaptureStateMapper.captureState(
            warmReady: asrWarmStatus.ready,
            hasTranscript: metrics.firstSegmentMs > 0 || !transcriptSegments.isEmpty
        )
    }

    var liveProgressPresentation: LiveProgressPresentation? {
        if isFinalizingLiveSession {
            if stateQueue.sync(execute: { visualRecordingStartPending }) {
                return LiveProgressPresentation(title: "正在取消录制准备", message: "正在停止采集并清理临时数据。")
            }
            return LiveProgressPresentation(
                title: "正在整理录制内容",
                message: "正在保存回看资料、转写和笔记，完成后会进入智能纪要选择。"
            )
        }

        switch captureState {
        case .preparingRuntime:
            return LiveProgressPresentation(
                title: "正在准备本地语音运行时",
                message: "首次启动或切换模型时可能需要等待，请不要关闭窗口。"
            )
        case .warmingModel:
            let buffered = liveWarmup.bufferedChunks
            let message = buffered > 0
                ? "已暂存 \(buffered) 段音频，模型就绪后会继续转写。"
                : "模型就绪后会自动开始转写，请继续等待。"
            return LiveProgressPresentation(
                title: "正在预热本地语音模型",
                message: message
            )
        case .refreshing where sessionPhase == .postSession:
            return LiveProgressPresentation(
                title: "正在生成智能纪要",
                message: "正在根据本次转写生成结构化总结，完成后会进入回看。"
            )
        default:
            return nil
        }
    }

    // MARK: - Session Lifecycle

    func prepareForLiveEntry() {
        guard !isRunning else { return }
        inputMode = .microphone
        activeMode = .microphone
        mixBus.setMode(.microphone)
    }

    func reloadSystemAudioSources(selectDefaultSource: Bool = true) {
        if isUITestingMode {
            updateMain {
                self.updateSystemAudioSources([
                    SystemAudioSourceItem(
                        id: "ui-test-system-source",
                        kind: .display,
                        title: "主显示器",
                        subtitle: "内置显示器"
                    ),
                ], selectDefaultSource: selectDefaultSource)
                self.permissionState = .granted
                self.errorMessage = nil
            }
            return
        }
        Task {
            do {
                let sources = try await systemAudioCapture.listSources()
                updateMain {
                    self.updateSystemAudioSources(sources, selectDefaultSource: selectDefaultSource)
                }
            } catch {
                publishError(error)
            }
        }
    }

    func updateSystemAudioSources(_ sources: [SystemAudioSourceItem], selectDefaultSource: Bool) {
        systemAudioSources = sources
        if selectDefaultSource, selectedSystemSourceID == nil {
            selectedSystemSourceID = sources.first?.id
        }
    }

    func refreshSidecarStatus() {
        if isUITestingMode {
            updateMain {
                self.configureForUITestingIfNeeded()
            }
            return
        }
        let rpcClient = rpcClient
        rpcQueue.async { [weak self, rpcClient] in
            do {
                let status = try rpcClient.sidecarStatus()
                guard let self else { return }
                let running = (status["running"] as? Bool) ?? false
                let pid = (status["pid"] as? Int) ?? 0
                let socketPath = (status["socket_path"] as? String) ?? ""
                let uptime = (status["uptime_sec"] as? Int) ?? 0
                let ready = (status["ready"] as? Bool) ?? running
                let pyVersion = (status["python_version"] as? String) ?? ""
                self.updateMain {
                    self.sidecarHealth = SidecarHealth(
                        running: running,
                        pid: pid == 0 ? nil : pid,
                        socketPath: socketPath,
                        uptimeSec: uptime,
                        isReady: ready,
                        lastErrorCode: (status["last_error_code"] as? String) ?? "",
                        lastLatencyMs: (status["last_latency_ms"] as? Int) ?? 0
                    )
                    if running {
                        self.sidecarLabel = pyVersion.isEmpty
                            ? "sidecar: running (pid \(pid))"
                            : "sidecar: running (pid \(pid), py \(pyVersion))"
                    } else {
                        self.sidecarLabel = "sidecar: down"
                    }
                }
            } catch {
                guard let self else { return }
                self.updateMain {
                    self.sidecarHealth = .unknown
                    self.sidecarLabel = "sidecar: down"
                }
            }
        }
    }

    func startLiveSession() {
        if !canStartSession { return }

        if startUITestSessionIfNeeded() {
            return
        }

        let selectedMode = inputMode
        if selectedMode.requiresSystemAudioSource, selectedSystemSourceID == nil {
            errorMessage = "请先选择系统音频源。"
            isSystemAudioPickerPresented = true
            return
        }

        resetSessionUI()

        let meetingID = "live-\(UUID().uuidString)"
        let source = rpcSource(for: selectedMode)
        let startupAt = Date()
        let selectedAnalysisMode = AppConfigStore.shared.config.analysis.mode
        let provisionalAnalyticsPath = ProductAnalyticsPath.provisional(analysisMode: selectedAnalysisMode)
        analyticsSubmit { $0.beginWorkflow("live", provisionalPath: provisionalAnalyticsPath) }

        stateQueue.sync {
            _isRunningLock.lock()
            _isRunning = true
            _isRunningLock.unlock()
            _sessionState.activeMeetingID = meetingID
            _sessionState.lastMeetingID = nil
            runtimeSessionStartingMeetingID = meetingID
            activeMode = selectedMode
            insightRefreshSuspended = false
            recordingPaused = false
            captureTimeline.reset()
        }
        transcriptPipeline.reset()

        beginLiveBackgroundWork(meetingID: meetingID)

        updateMain {
            self.sessionHandle = SessionHandle(activeMeetingID: meetingID, lastMeetingID: nil)
        }

        mixBus.setMode(selectedMode)
        configureAudioCaptureCallbacks(meetingID: meetingID)
        captureState = .preparingRuntime
        sessionPhase = .preparing
        analysisRuntimeState = .ready
        captureHealth = CaptureHealthSnapshot(
            sessionStartedAt: startupAt,
            lastChunkAt: nil,
            lastTranscriptAt: nil,
            inputLevelMic: 0,
            inputLevelSystem: 0
        )
        startCaptureHealthMonitor()

        // Media capture starts independently from runtime/model preparation.
        // Stay on the setup surface until the selected sources and writer are armed.
        beginCaptureStartup(meetingID: meetingID, mode: selectedMode, systemSourceID: selectedSystemSourceID)

        let startupGroup = runtimeStartupGroup
        startupGroup.enter()
        rpcQueue.async { [weak self] in
            defer { startupGroup.leave() }
            guard let self else { return }
            guard self.isCurrentLiveSession(meetingID) else { return }
            do {
                let selectedEngine = AppConfigStore.shared.config.asr.engine
                let selectedModel = AppConfigStore.shared.currentASRModel()
                try self.sidecarManager.startIfNeeded(ensureReady: { [weak self] in
                    guard let self else { return }
                    _ = try self.rpcClient.ensureReady(timeoutSec: 6)
                })
                guard self.isCurrentLiveSession(meetingID) else { return }
                self.refreshSidecarStatus()
                try self.assertLiveSidecarCapabilities()
                try self.ensureRuntimeReady(requireASR: true, requireProvider: false, allowProviderProbeFailure: true)
                guard self.isCurrentLiveSession(meetingID) else { return }
                try self.rpcClient.sessionStart(meetingID: meetingID, title: "直播洞察", source: source)
                guard self.isCurrentLiveSession(meetingID) else { return }
                self.stateQueue.sync { self.runtimeSessionStartingMeetingID = nil }
                let analyticsPath = ProductAnalyticsPath(
                    providers: try? self.rpcClient.providersStatus(probeActive: false),
                    analysisMode: selectedAnalysisMode
                )
                self.analyticsSubmit { $0.resolveWorkflow("live", path: analyticsPath) }
                self.updateMain {
                    guard self.isCurrentLiveSession(meetingID) else { return }
                    self.captureState = .warmingModel
                    self.liveWarmup = LiveWarmupSnapshot(
                        state: .idle,
                        attempt: 0,
                        bufferedChunks: 0,
                        bufferedAudioMs: 0,
                        automaticRetryCount: 0,
                        isRetryScheduled: false,
                        lastError: ""
                    )
                }
                self.probeProvidersInBackground()

                self.updateMain {
                    guard self.isCurrentLiveSession(meetingID) else { return }
                    self.beginWarmupLifecycle(
                        meetingID: meetingID,
                        startupAt: startupAt,
                        engine: selectedEngine,
                        model: selectedModel
                    )
                }
            } catch {
                guard self.isCurrentLiveSession(meetingID) else { return }
                self.analyticsSubmit(ProductAnalytics.failure {
                    $0.workflowFailed(
                        "live",
                        phase: "preparing",
                        errorCode: "runtime-unavailable",
                        recoveryAction: "retry"
                    )
                })
                self.publishError(error)
                self.stopLiveSession(finalState: .error(error.localizedDescription))
            }
        }
    }

    func isCurrentLiveSession(_ meetingID: String) -> Bool {
        stateQueue.sync { isRunning && _sessionState.activeMeetingID == meetingID }
    }

    func beginCaptureStartup(
        meetingID: String, mode: AudioInputMode, systemSourceID: String?, readinessTimeoutSec: TimeInterval = 5
    ) {
        stateQueue.sync { visualRecordingStartPending = visualPreviewSource != .none }
        captureStartupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.captureStartupTask = nil }
            do {
                guard self.isCurrentLiveSession(meetingID), !Task.isCancelled else { return }
                if mode != .systemAudio {
                    try await self.micCapture.start()
                }
                guard self.isCurrentLiveSession(meetingID), !Task.isCancelled else {
                    await self.micCapture.stopAndDrain()
                    return
                }
                if self.visualPreviewSource != .none, !self.videoCaptureService.isCapturing,
                   !self.visualPreviewPreparationPending, self.visualPreviewSetupTask == nil {
                    self.restartSelectedVisualPreview()
                }
                if mode != .microphone {
                    guard let sourceID = systemSourceID else {
                        throw NSError(domain: "InsightKit", code: -1, userInfo: [NSLocalizedDescriptionKey: "缺少系统音频源"])
                    }
                    try await self.systemAudioCapture.start(sourceID: sourceID)
                }
                guard self.isCurrentLiveSession(meetingID), !Task.isCancelled else {
                    await self.micCapture.stopAndDrain()
                    await self.systemAudioCapture.stop()
                    return
                }
                self.configureVideoCaptureCallbacks(meetingID: meetingID)
                try await self.startVisualRecordingWhenReady(meetingID: meetingID, timeoutSec: readinessTimeoutSec)
                guard !Task.isCancelled, self.stateQueue.sync(execute: {
                    guard self.isRunning, self._sessionState.activeMeetingID == meetingID else { return false }
                    self.visualRecordingStartPending = false
                    return true
                }) else { return }
                self.permissionState = .granted
                self.sessionPhase = .running
                self.beginRecordingClockForCapturedMedia()
                self.pipelineQueue.async { self.pumpChunkQueueIfNeeded(meetingID: meetingID) }
            } catch {
                guard self.isCurrentLiveSession(meetingID), !Task.isCancelled else { return }
                self.analyticsSubmit(ProductAnalytics.failure {
                    $0.workflowFailed("live", phase: "preparing", errorCode: "runtime-unavailable", recoveryAction: "retry")
                })
                self.publishError(error)
                self.stopLiveSession(finalState: .error(error.localizedDescription))
            }
        }
    }

    @MainActor
    func startVisualRecordingWhenReady(meetingID: String, timeoutSec: TimeInterval = 5) async throws {
        guard visualPreviewSource != .none else { return }
        var readinessDeadline: TimeInterval?
        while true {
            try Task.checkCancellation()
            guard isCurrentLiveSession(meetingID) else { throw CancellationError() }
            // Overlay camera capture may start before the screen stream setup
            // completes. Both the source and its setup task must be ready.
            let setupPending = visualPreviewPreparationPending || visualPreviewSetupTask != nil
            if videoCaptureService.isCapturing, !setupPending { break }
            // Permission dialogs and the system sharing picker are interactive;
            // only a settled source that does not become ready can time out.
            if setupPending {
                readinessDeadline = nil
            } else if readinessDeadline == nil {
                readinessDeadline = ProcessInfo.processInfo.systemUptime + timeoutSec
            }
            guard readinessDeadline.map({ ProcessInfo.processInfo.systemUptime < $0 }) ?? true else {
                throw NSError(domain: "InsightKit", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "视频采集尚未就绪。请检查屏幕共享或摄像头预览后重试。"
                ])
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard startVisualRecordingIfNeeded(meetingID: meetingID) else {
            throw NSError(domain: "InsightKit", code: -1, userInfo: [
                NSLocalizedDescriptionKey: capturePreviewStatusMessage ?? "视频录制未能启动。"
            ])
        }
        try await waitForVisualRecordingStart(meetingID: meetingID, timeoutSec: timeoutSec)
    }

    func waitForVisualRecordingStart(meetingID: String, timeoutSec: TimeInterval = 5) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeoutSec
        while true {
            try Task.checkCancellation()
            guard isCurrentLiveSession(meetingID) else { throw CancellationError() }
            if stateQueue.sync(execute: { captureTimeline.videoStartSec != nil }) { return }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw NSError(domain: "InsightKit", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "未收到可录制的视频画面。请检查屏幕共享或摄像头预览后重试。"
                ])
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func stopLiveSession() {
        stopLiveSession(finalState: .idle)
    }

    func stopLiveSession(finalState: CaptureState) {
        if !isRunning { return }
        invalidateLiveBackgroundWork()

        if stopUITestSessionIfNeeded(finalState: finalState) {
            return
        }

        let stopTime = recordingUptime()
        let (activeMeetingID, discardUnstartedRecording) = stateQueue.sync {
            _isRunningLock.lock()
            _isRunning = false
            _isRunningLock.unlock()
            if recordingPaused {
                captureTimeline.markPauseEnd(at: stopTime)
            }
            stopDrainingMeetingID = _sessionState.activeMeetingID
            audioCaptureDraining = true
            visualPreviewGeneration = UUID()
            return (_sessionState.activeMeetingID, visualRecordingStartPending)
        }
        captureMonitorTask?.cancel()
        captureMonitorTask = nil
        cancelWarmupTasks()
        captureStartupTask?.cancel()
        visualPreviewSetupTask?.cancel()
        visualPreviewSetupTask = nil
        visualPreviewPreparationPending = false
        stopRecordingDurationTimer(at: stopTime)
        updateMain {
            self.isFinalizingLiveSession = true
            self.isRecordingPaused = false
            self.recordingStatusMessage = discardUnstartedRecording ? nil
                : "录制已停止，正在处理剩余音频并生成最终转写，请保持应用打开。"
        }

        micCapture.stop()
        let systemAudioStopped = systemAudioCapture.beginStop()
        let presentationCaptureStatus = currentPresentationCaptureStatus()
        pendingPresentationCaptureStatus = presentationCaptureStatus
        let expectedVisualMedia = presentationCaptureStatus != nil
        let provisionalVideoURL = discardUnstartedRecording ? temporaryRecordingURL : nil
        let videoRecordingFinished = expectedVisualMedia ? videoCaptureService.beginFinishRecording() : nil
        videoCaptureService.stopCapture()

        Task { [weak self] in
            guard let self else { return }
            await self.micCapture.stopAndDrain()
            await systemAudioStopped.value
            await self.mixBus.finish()
            self.stateQueue.sync {
                self.audioCaptureDraining = false
                self.recordingPaused = false
            }
            if let videoRecordingFinished {
                self.temporaryRecordingURL = await videoRecordingFinished.value
            }
            if let provisionalVideoURL {
                try? FileManager.default.removeItem(at: provisionalVideoURL)
                self.temporaryRecordingURL = nil
            }
            // Acceptance and the archive barrier share one queue: a buffer is
            // either submitted before this barrier or rejected after sealing.
            self.stateQueue.sync {
                self.audioArchiveQueue.async {
                    var tail: [AudioChunk] = []
                    do {
                        let remaining = discardUnstartedRecording ? [] : try self.chunkAssembler.flush(
                            minDurationSec: 1 / Double(self.chunkAssembler.sampleRate))
                        if !self.shouldHoldChunksForWarmup {
                            tail = remaining.filter { $0.endMs - $0.startMs >= 1_000 }
                        }
                    } catch {
                        self.publishError(error)
                    }
                    // Preserve media before any fallible final ASR/runtime RPC.
                    if let meetingID = activeMeetingID, !discardUnstartedRecording {
                        _ = self.prepareTemporaryRecordingForSave(
                            meetingID: meetingID,
                            expectedVisualMedia: expectedVisualMedia
                        )
                    }
                    self.finalizeStoppedLiveSession(
                        meetingID: activeMeetingID, tail: tail, finalState: finalState,
                        discardUnstartedRecording: discardUnstartedRecording
                    )
                }
            }
        }
    }

    private func finalizeStoppedLiveSession(
        meetingID activeMeetingID: String?, tail: [AudioChunk], finalState: CaptureState,
        discardUnstartedRecording: Bool = false
    ) {
        pipelineQueue.async { [weak self] in
            guard let self else { return }
            // A cancelled startup may still be finishing an RPC. Its session
            // creation must settle before the finalization lease is requested.
            self.runtimeStartupGroup.wait()
            var drainedSegments: [TranscriptSegment] = []
            var finalizationLeaseToken: String?
            var finalizationFailed = false
            do {
                let pendingChunks = discardUnstartedRecording ? [] : self.queuedChunks
                self.queuedChunks.removeAll(keepingCapacity: false)
                self.chunkInFlight = false
                if let meetingID = activeMeetingID {
                    for chunk in pendingChunks {
                        let outcome = try self.processChunk(chunk, meetingID: meetingID)
                        drainedSegments.append(contentsOf: outcome.transcriptSegments)
                    }
                }
                if let meetingID = activeMeetingID {
                    for chunk in tail {
                        let outcome = try self.processChunk(chunk, meetingID: meetingID)
                        drainedSegments.append(contentsOf: outcome.transcriptSegments)
                    }
                }
                if let meetingID = activeMeetingID {
                    if discardUnstartedRecording {
                        try self.rpcClient.sessionStop(meetingID: meetingID)
                    } else {
                        let leaseToken = UUID().uuidString
                        finalizationLeaseToken = leaseToken
                        try self.rpcClient.sessionStopForFinalization(meetingID: meetingID, leaseToken: leaseToken)
                    }
                }
            } catch {
                finalizationFailed = true
                self.analyticsSubmit(ProductAnalytics.failure { analytics in
                    analytics.workflowFailed(
                        "live",
                        phase: "finalizing",
                        errorCode: "unknown",
                        recoveryAction: "retry"
                    )
                })
                self.publishError(error)
            }

            self.audioArchiveQueue.sync { self.chunkAssembler.reset() }
            if discardUnstartedRecording, let url = self.temporaryRecordingURL {
                try? FileManager.default.removeItem(at: url)
                self.temporaryRecordingURL = nil
            }
            self.stateQueue.sync {
                if !discardUnstartedRecording {
                    self._sessionState.lastMeetingID = activeMeetingID ?? self._sessionState.lastMeetingID
                }
                self._sessionState.activeMeetingID = nil
                self.stopDrainingMeetingID = nil
                self.runtimeSessionStartingMeetingID = nil
                self.visualRecordingStartPending = false
            }
            self.transcriptPipeline.reset()
            self.syncSessionHandleFromState()
            self.updateMain {
                self.metrics.queueDepth = 0
                if !finalizationFailed {
                    self.captureState = finalState
                }
                self.sessionPhase = discardUnstartedRecording ? .preparing : .postSession
            }
            // Save record folder after session ends
            if let meetingID = activeMeetingID, !discardUnstartedRecording {
                let transcriptOverride = (self.transcriptSegments + drainedSegments)
                    .sorted { $0.startMs < $1.startMs }
                self.saveToRecords(
                    meetingID: meetingID,
                    transcriptSegmentsOverride: transcriptOverride.isEmpty ? nil : transcriptOverride,
                    finalizationLeaseToken: finalizationLeaseToken,
                    completionCaptureState: finalState,
                    recoveringFinalizationFailure: finalizationFailed
                )
            } else {
                self.updateMain {
                    self.isFinalizingLiveSession = false
                }
            }
        }
    }

    func buildFinalInsight() {
        invalidateLiveBackgroundWork()
        if buildUITestFinalInsightIfNeeded() {
            return
        }

        guard let buildTargetID = currentBuildTargetID() else {
            publishError(NSError(domain: "InsightKit", code: -2, userInfo: [NSLocalizedDescriptionKey: "当前无会话，无法生成定稿洞察"]))
            return
        }
        updateMain {
            self.captureState = .refreshing
        }

        rpcQueue.async { [weak self] in
            guard let self else { return }
            ProductAnalytics.submit { $0.recoveryAttempted("live", phase: "analysis") }
            var analysisStartedAt: UInt64?
            do {
                try self.sidecarManager.startIfNeeded(ensureReady: { [weak self] in
                    guard let self else { return }
                    _ = try self.rpcClient.ensureReady(timeoutSec: 6)
                })
                self.refreshSidecarStatus()
                try self.ensureRuntimeReady(requireASR: false, requireProvider: true, allowProviderProbeFailure: false)
                if let mediaURL = self.temporaryRecordingURL {
                    let mediaSegments = try self.finalTranscriptSegmentsForRecord(
                        mediaURL: mediaURL,
                        capturedSegments: self.transcriptSegments
                    )
                    try self.replaceRuntimeTranscript(meetingID: buildTargetID, segments: mediaSegments)
                }
                let startedAt = DispatchTime.now().uptimeNanoseconds
                analysisStartedAt = startedAt
                let result = try self.rpcClient.buildFinal(meetingID: buildTargetID)
                let analysisLatencyMS = Int((DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
                self.updateWorkbench(result, analyticsLatencyMilliseconds: analysisLatencyMS)
                ProductAnalytics.submit { $0.recoveryCompleted("live", phase: "analysis", succeeded: true) }
                self.updateMain {
                    self.lastInsightPackage = result.package
                    self.errorMessage = nil
                    self.captureState = .idle
                    self.sessionPhase = .reviewing
                }
                self.saveToRecords(meetingID: buildTargetID, insightPackageOverride: result.package)
            } catch {
                let analysisLatencyMS = analysisStartedAt.map {
                    Int((DispatchTime.now().uptimeNanoseconds - $0) / 1_000_000)
                }
                ProductAnalytics.submit(ProductAnalytics.failure {
                    $0.workflowFailed(
                        "live",
                        phase: "analysis",
                        errorCode: "unknown",
                        recoveryAction: "retry",
                        analysisLatencyMilliseconds: analysisLatencyMS
                    )
                })
                self.updateMain {
                    if self.captureState == .refreshing {
                        self.captureState = .idle
                    }
                }
                self.publishError(error)
            }
        }
    }

    func exportDocument(format: String = "markdown") {
        guard let meetingID = currentBuildTargetID(), !isExporting else { return }
        isExporting = true
        ProductAnalytics.submit { $0.exportAttempted("live") }
        rpcQueue.async { [weak self] in
            guard let self else { return }
            do {
                if let url = try RecordDocumentExporter.exportIfPersistedRecordExists(
                    format: format,
                    meetingID: meetingID,
                    recordsService: self.recordsService
                ) {
                    self.updateMain {
                        self.finishExport()
                        self.lastExportPath = url.path
                        let recordPath = self.recordsService?.recordFolderURL(for: meetingID)
                        let duration = self.recordingDuration
                        let hasBlockingError = self.errorMessage != nil
                        ProductAnalytics.submit(ProductAnalytics.completion(evaluating: {
                            MeetingAssetWorkflowSuccess.evaluate(
                                recordPath: recordPath,
                                duration: duration,
                                exportCompleted: true,
                                hasBlockingError: hasBlockingError
                            )
                        }) { analytics, completionEvaluation in
                            analytics.exportCompleted("live")
                            analytics.workflowCompleted("live", evaluation: completionEvaluation)
                        })
                    }
                    return
                }
                try self.sidecarManager.startIfNeeded(ensureReady: { [weak self] in
                    guard let self else { return }
                    _ = try self.rpcClient.ensureReady(timeoutSec: 6)
                })
                try self.ensureRuntimeReady(requireASR: false, requireProvider: true, allowProviderProbeFailure: false)
                let result = try self.rpcClient.documentExport(meetingID: meetingID, format: format, outputDir: "")
                self.updateMain {
                    self.finishExport()
                    self.lastExportPath = result.path
                    let recordPath = self.recordsService?.recordFolderURL(for: meetingID)
                    let duration = self.recordingDuration
                    let hasBlockingError = self.errorMessage != nil
                    ProductAnalytics.submit(ProductAnalytics.completion(evaluating: {
                        MeetingAssetWorkflowSuccess.evaluate(
                            recordPath: recordPath,
                            duration: duration,
                            exportCompleted: true,
                            hasBlockingError: hasBlockingError
                        )
                    }) { analytics, completionEvaluation in
                        analytics.exportCompleted("live")
                        analytics.workflowCompleted("live", evaluation: completionEvaluation)
                    })
                }
            } catch {
                ProductAnalytics.submit(ProductAnalytics.failure { analytics in
                    analytics.workflowFailed("live", phase: "exporting", errorCode: "unknown", recoveryAction: "retry")
                })
                self.updateMain {
                    self.finishExport()
                    self.publishError(error)
                }
            }
        }
    }

    private func finishExport() {
        isExporting = false
        if recordingStatusMessage == "导出正在完成，请稍候再新建会话。" {
            recordingStatusMessage = nil
        }
    }

    @discardableResult
    func resetForNewSession() -> Bool {
        guard !isExporting else {
            recordingStatusMessage = "导出正在完成，请稍候再新建会话。"
            return false
        }
        guard !isFinalizingLiveSession else {
            recordingStatusMessage = "录制资料正在保存，请稍候再新建会话。"
            return false
        }
        if isRunning {
            stopLiveSession()
            return false
        }
        guard captureStartupTask == nil else { return false }
        let analyticsPhase = sessionPhase == .postSession
            ? "finalizing"
            : sessionPhase == .reviewing ? "reviewing" : "running"
        analyticsSubmit { $0.workflowCancelled("live", phase: analyticsPhase) }
        stopLiveSession()
        stopCameraPreview()
        stateQueue.sync {
            self._sessionState = SessionHandle()
        }
        syncSessionHandleFromState()
        resetSessionUI()
        prepareForLiveEntry()
        refreshSidecarStatus()
        return true
    }

    // MARK: - UI Actions

    func selectSystemSource(_ sourceID: String?) { selectedSystemSourceID = sourceID }
    func selectEvidence(_ range: EvidenceRange?) { selectedEvidence = range }
    func clearError() { errorMessage = nil }

    func updateActionStatus(id: UUID, status: String) {
        guard let idx = actionItems.firstIndex(where: { $0.id == id }) else { return }
        actionItems[idx].status = status
        syncActionTracksToWorkbench()
    }

    func updateActionOwner(id: UUID, owner: String) {
        guard let idx = actionItems.firstIndex(where: { $0.id == id }) else { return }
        actionItems[idx].owner = owner
        syncActionTracksToWorkbench()
    }

    func updateActionDueAt(id: UUID, dueAt: String) {
        guard let idx = actionItems.firstIndex(where: { $0.id == id }) else { return }
        actionItems[idx].dueAt = dueAt
        syncActionTracksToWorkbench()
    }

    func openMicrophonePrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }

    func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Camera Preview

    @discardableResult
    func startVisualRecordingIfNeeded(meetingID: String) -> Bool {
        guard visualPreviewSource != .none else { return true }
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InsightKit")
            .appendingPathComponent(meetingID)
        let outputURL = tmpDir.appendingPathComponent("recording.mp4")

        do {
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            try videoCaptureService.startRecording(to: outputURL)
            temporaryRecordingURL = outputURL
            return true
        } catch {
            temporaryRecordingURL = nil
            capturePreviewStatusMessage = "视频录制未能启动。请检查预览后重试。\(error.localizedDescription)"
            return false
        }
    }

    var isCameraPreviewSelected: Bool {
        switch visualPreviewSource {
        case .none:
            return false
        case .camera, .presenterOverlay, .screenWithCameraOverlay:
            return true
        case .screen:
            return visualSelectionUsesScreenOnlyFallback
        }
    }

    var isScreenPreviewSelected: Bool {
        switch visualPreviewSource {
        case .none, .camera:
            return false
        case .screen, .presenterOverlay, .screenWithCameraOverlay:
            return true
        }
    }

    func applyVisualPreviewSelection(cameraEnabled: Bool, screenEnabled: Bool) {
        guard !isRunning, !isFinalizingLiveSession else { return }
        visualSelectionUsesScreenOnlyFallback = false
        let plan = LiveVisualPreviewPlan.resolve(
            cameraEnabled: cameraEnabled,
            screenEnabled: screenEnabled
        )
        capturePreviewStatusMessage = plan.statusMessage

        guard !isUITestingMode else {
            visualPreviewSource = plan.source
            return
        }

        if visualPreviewSource == plan.source {
            return
        }
        stateQueue.sync { visualPreviewGeneration = UUID() }
        visualPreviewSetupTask?.cancel()
        visualPreviewSetupTask = nil
        visualPreviewPreparationPending = false

        if visualPreviewSource != .none {
            videoCaptureService.stopCapture(waitUntilStopped: true)
        }

        visualPreviewSource = plan.source

        switch plan.source {
        case .none:
            videoCaptureService.stopCapture()
            capturePreviewStatusMessage = nil
        case .camera:
            startCameraPreview()
        case .screen:
            startScreenPreview(receivingMessage: plan.statusMessage)
        case .presenterOverlay:
            startPresenterOverlayPreview()
        case .screenWithCameraOverlay:
            startCameraOverlayScreenPreview()
        }
    }

    func currentPresentationCaptureStatus() -> LivePresentationCaptureStatus? {
        if visualSelectionUsesScreenOnlyFallback, visualPreviewSource != .none {
            return .screenOnlyFallback
        }

        switch visualPreviewSource {
        case .none:
            return nil
        case .camera:
            return .cameraOnly
        case .screen:
            return .screenOnly
        case .presenterOverlay:
            return LivePresentationCaptureStatus.resolve(
                cameraEnabled: true,
                screenEnabled: true,
                presenterOverlayObserved: videoCaptureService.presenterOverlayObserved
            )
        case .screenWithCameraOverlay:
            return .screenPlusCameraCaptured
        }
    }

    func startCameraPreview() {
        if isUITestingMode {
            return
        }
        capturePreviewStatusMessage = "正在准备摄像头预览..."
        visualPreviewPreparationPending = true
        let generation = stateQueue.sync { visualPreviewGeneration }
        videoCaptureService.checkCameraPermission()
        switch videoCaptureService.cameraPermission {
        case .denied:
            visualPreviewPreparationPending = false
            // Already denied — open settings instead of crashing
            capturePreviewStatusMessage = "摄像头权限未开启。请在系统设置中允许 InsightKit 使用摄像头。"
            videoCaptureService.openCameraSettings()
            return
        case .unknown:
            // Not determined — request permission (requires NSCameraUsageDescription)
            Task { @MainActor in
                let granted = await videoCaptureService.requestCameraPermission()
                guard isCurrentVisualPreview(generation) else { return }
                if granted {
                    startCameraCapture()
                } else {
                    visualPreviewPreparationPending = false
                    capturePreviewStatusMessage = "摄像头权限未开启。请在系统设置中允许 InsightKit 使用摄像头。"
                }
            }
        case .granted:
            startCameraCapture()
        }
    }

    private func startCameraCapture() {
        let generation = stateQueue.sync { visualPreviewGeneration }
        videoCaptureService.enumerateCameras()
        // enumerateCameras dispatches to main async; wait briefly for results
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.isCurrentVisualPreview(generation) else { return }
            defer { self.visualPreviewPreparationPending = false }
            guard let firstCamera = self.videoCaptureService.availableCameras.first else {
                self.capturePreviewStatusMessage = "没有找到可用摄像头。请检查设备连接后再试。"
                return
            }
            do {
                try self.videoCaptureService.startCamera(deviceID: firstCamera.id)
                self.capturePreviewStatusMessage = nil
            } catch {
                self.capturePreviewStatusMessage = error.localizedDescription
            }
        }
    }

    func startScreenPreview(receivingMessage: String? = nil) {
        if isUITestingMode {
            return
        }
        let message = receivingMessage
            ?? "正在准备屏幕预览；若一直没有画面，请确认系统设置已允许 InsightKit 录制屏幕。"
        capturePreviewStatusMessage = message
        visualPreviewPreparationPending = true
        let generation = stateQueue.sync { visualPreviewGeneration }

        Task { [weak self] in
            guard let self else { return }
            await self.videoCaptureService.enumerateScreens()
            await MainActor.run {
                guard self.isCurrentVisualPreview(generation) else { return }
                self.startFirstAvailableScreenPreview(receivingMessage: message)
            }
        }
    }

    func startPresenterOverlayPreview() {
        if isUITestingMode {
            return
        }
        capturePreviewStatusMessage = "屏幕录制 + Presenter Overlay。请在 macOS 视频效果菜单中确认演示者叠加；如果未开启，本次 Record 将仅包含屏幕。"
        visualPreviewPreparationPending = true
        let generation = stateQueue.sync { visualPreviewGeneration }
        videoCaptureService.checkCameraPermission()
        switch videoCaptureService.cameraPermission {
        case .denied:
            visualPreviewPreparationPending = false
            capturePreviewStatusMessage = "摄像头权限未开启。请在系统设置中允许 InsightKit 使用摄像头，Presenter Overlay 才能由 macOS 合入画面。"
            videoCaptureService.openCameraSettings()
            return
        case .unknown:
            Task { @MainActor in
                let granted = await videoCaptureService.requestCameraPermission()
                guard isCurrentVisualPreview(generation) else { return }
                if granted {
                    startPresenterOverlayScreenPreview()
                } else {
                    visualPreviewPreparationPending = false
                    capturePreviewStatusMessage = "摄像头权限未开启。请在系统设置中允许 InsightKit 使用摄像头，Presenter Overlay 才能由 macOS 合入画面。"
                }
            }
        case .granted:
            startPresenterOverlayScreenPreview()
        }
    }

    private func startPresenterOverlayScreenPreview() {
        let generation = stateQueue.sync { visualPreviewGeneration }
        Task { [weak self] in
            guard let self else { return }
            await self.videoCaptureService.enumerateScreens()
            await MainActor.run {
                guard self.isCurrentVisualPreview(generation) else { return }
                self.startFirstAvailableScreenPreview(
                    receivingMessage: "正在接收屏幕画面。请在 Apple 的系统共享界面中确认 Presenter Overlay；否则本次 Record 将仅包含屏幕。",
                    usesPresenterOverlayPicker: true
                )
            }
        }
    }

    func startCameraOverlayScreenPreview() {
        if isUITestingMode {
            return
        }
        capturePreviewStatusMessage = "屏幕录制 + 摄像头叠加。正在准备摄像头画面..."
        visualPreviewPreparationPending = true
        let generation = stateQueue.sync { visualPreviewGeneration }
        videoCaptureService.checkCameraPermission()
        switch videoCaptureService.cameraPermission {
        case .denied:
            startScreenOnlyFallbackPreview(reason: "摄像头权限未开启。当前仅保存屏幕；摄像头不会写入本次 Record。")
        case .unknown:
            Task { @MainActor in
                let granted = await videoCaptureService.requestCameraPermission()
                guard isCurrentVisualPreview(generation) else { return }
                if granted {
                    startCameraOverlayScreenCapture()
                } else {
                    startScreenOnlyFallbackPreview(reason: "摄像头权限未开启。当前仅保存屏幕；摄像头不会写入本次 Record。")
                }
            }
        case .granted:
            startCameraOverlayScreenCapture()
        }
    }

    private func startCameraOverlayScreenCapture() {
        let generation = stateQueue.sync { visualPreviewGeneration }
        Task { [weak self] in
            guard let self else { return }
            await self.videoCaptureService.enumerateScreens()
            await MainActor.run {
                guard self.isCurrentVisualPreview(generation) else { return }
                self.startFirstAvailableScreenPreview(
                    receivingMessage: "屏幕录制 + 摄像头叠加。保存的 Record 应包含屏幕与摄像头画面。",
                    usesCameraOverlay: true
                )
            }
        }
    }

    private func startScreenOnlyFallbackPreview(reason: String) {
        visualSelectionUsesScreenOnlyFallback = true
        visualPreviewSource = .screen
        startScreenPreview(receivingMessage: reason)
    }

    @MainActor
    private func startFirstAvailableScreenPreview(
        receivingMessage: String = "正在接收屏幕画面；若一直黑屏，请确认系统设置已允许 InsightKit 录制屏幕。",
        usesPresenterOverlayPicker: Bool = false,
        usesCameraOverlay: Bool = false
    ) {
        let generation = stateQueue.sync { visualPreviewGeneration }
        defer { visualPreviewPreparationPending = false }
        guard let firstScreen = videoCaptureService.availableScreens.first(where: { $0.kind == .screen }) else {
            capturePreviewStatusMessage = "没有找到可预览的显示器。请检查屏幕录制权限或重新打开 Live Workspace。"
            return
        }

        let rawID = firstScreen.id.hasPrefix("screen:")
            ? String(firstScreen.id.dropFirst("screen:".count))
            : firstScreen.id
        guard let displayID = UInt32(rawID) else {
            capturePreviewStatusMessage = "屏幕来源无效。请重新打开 Live Workspace 后再试。"
            return
        }

        capturePreviewStatusMessage = receivingMessage
        visualPreviewSetupTask = Task { [weak self] in
            guard let self else { return }
            guard self.isCurrentVisualPreview(generation) else { return }
            defer {
                if self.isCurrentVisualPreview(generation) { self.visualPreviewSetupTask = nil }
            }
            do {
                if usesCameraOverlay {
                    try await self.videoCaptureService.startScreenCaptureWithCameraOverlay(displayID: displayID)
                } else if usesPresenterOverlayPicker {
                    try await self.videoCaptureService.startPresenterOverlayCapture(displayID: displayID)
                } else {
                    try await self.videoCaptureService.startScreenCapture(displayID: displayID)
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.isCurrentVisualPreview(generation) else { return }
                await MainActor.run {
                    guard self.isCurrentVisualPreview(generation) else { return }
                    if usesCameraOverlay {
                        self.visualSelectionUsesScreenOnlyFallback = true
                        self.visualPreviewSource = .screen
                        self.capturePreviewStatusMessage = "摄像头叠加未能启动，当前仅保存屏幕；摄像头不会写入本次 Record。\(error.localizedDescription)"
                    } else {
                        self.capturePreviewStatusMessage = "\(error.localizedDescription) 请在系统设置中允许 InsightKit 录制屏幕。"
                    }
                }
                if usesCameraOverlay {
                    guard self.isCurrentVisualPreview(generation) else { return }
                    do {
                        try await self.videoCaptureService.startScreenCapture(displayID: displayID)
                    } catch {
                        await MainActor.run {
                            guard self.isCurrentVisualPreview(generation) else { return }
                            self.capturePreviewStatusMessage = "\(error.localizedDescription) 请在系统设置中允许 InsightKit 录制屏幕。"
                        }
                    }
                }
            }
        }
    }

    func stopCameraPreview() {
        visualPreviewSource = .none
        visualSelectionUsesScreenOnlyFallback = false
        stateQueue.sync { visualPreviewGeneration = UUID() }
        visualPreviewSetupTask?.cancel()
        visualPreviewSetupTask = nil
        visualPreviewPreparationPending = false
        capturePreviewStatusMessage = nil
        if isUITestingMode {
            return
        }
        videoCaptureService.stopCapture()
    }

    func isCurrentVisualPreview(_ generation: UUID) -> Bool {
        stateQueue.sync { visualPreviewGeneration == generation }
    }

    private func restartSelectedVisualPreview() {
        stateQueue.sync { visualPreviewGeneration = UUID() }
        visualPreviewSetupTask?.cancel()
        visualPreviewSetupTask = nil
        visualPreviewPreparationPending = false
        switch visualPreviewSource {
        case .none: break
        case .camera: startCameraPreview()
        case .screen: startScreenPreview()
        case .presenterOverlay: startPresenterOverlayPreview()
        case .screenWithCameraOverlay: startCameraOverlayScreenPreview()
        }
    }

    // MARK: - Private Helpers

    func publishError(_ error: Error) {
        let raw = error.localizedDescription
        if raw.localizedCaseInsensitiveContains("privacy")
            || raw.localizedCaseInsensitiveContains("permission")
            || raw.localizedCaseInsensitiveContains("麦克风")
            || raw.localizedCaseInsensitiveContains("屏幕录制") {
            permissionState = .denied
            updateMain {
                self.captureState = .recoveringPermission
                self.errorMessage = raw
            }
            return
        }

        var message = raw
        var analysisStateOverride: AnalysisRuntimeState?
        let lower = raw.lowercased()
        if let sanitized = AnalysisProviderErrorPresentation.sanitizedMessage(for: raw) {
            message = sanitized
            analysisStateOverride = .pausedInvalidResponse
        } else if lower.contains("method not found")
            || lower.contains("circuit-open")
            || lower.contains("sidecar.ensure_ready") {
            message = "本地服务版本或状态异常，请打开设置执行“一键测试服务”并重启应用。"
        } else if lower.contains("traceback") {
            message = "本地服务执行失败，请稍后重试；若持续失败，请在设置执行“一键修复语音识别”。"
        }

        updateMain {
            if let analysisStateOverride {
                self.analysisRuntimeState = analysisStateOverride
            }
            self.captureState = .error(message)
            self.errorMessage = message
        }
    }

    func updateMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    func resetSessionUI() {
        stopDelayedSummaryUITestScenario()
        invalidateLiveBackgroundWork()
        cancelWarmupTasks()
        stopRecordingDurationTimer()
        captureState = .idle
        transcriptSegments = []
        workbench = .empty
        actionItems = []
        metrics = LiveSessionMetrics()
        errorMessage = nil
        selectedEvidence = nil
        lastExportPath = ""
        analysisRuntimeState = .ready
        captureHealth = .empty
        asrWarmStatus = ASRWarmStatus(ready: false, state: .idle, inProgress: false, attempt: 0, lastWarmMs: 0, lastError: "")
        liveWarmup = .empty
        lastCaptureHintAt = nil
        queuedChunks.removeAll(keepingCapacity: false)
        chunkInFlight = false
        warmupFailureCount = 0
        warmupRetryScheduled = false
        audioArchiveQueue.sync { chunkAssembler.reset() }
        // Phase 4 panel state
        sessionPhase = .preparing
        chapters = []
        smartMinutesData = nil
        notes = []
        currentPlaybackTime = nil
        mediaSeekRequest = nil
        reviewSourcePlaybackRequested = false
        recordingDuration = 0
        recordingStatusMessage = nil
        isFinalizingLiveSession = false
        mediaURL = nil
        reviewSourceMediaURL = nil
        reviewSourceStatusMessage = nil
        temporaryRecordingURL = nil
        finalizedMediaTranscriptCache = nil
        pendingPresentationCaptureStatus = nil
        stopDrainingMeetingID = nil
        recordingPaused = false
        stateQueue.sync {
            audioCaptureDraining = false
            runtimeSessionStartingMeetingID = nil
            visualRecordingStartPending = false
            captureTimeline.reset()
        }
        isRecordingPaused = false
    }

    func pauseLiveSession() {
        guard isRunning else { return }
        let pauseTime = recordingUptime()
        let didPause = stateQueue.sync {
            guard !recordingPaused else { return false }
            mixBus.flushPendingSamples()
            recordingPaused = true
            captureTimeline.markPauseStart(at: pauseTime)
            return true
        }
        guard didPause else { return }
        videoCaptureService.pauseRecording(at: pauseTime)
        stopRecordingDurationTimer(at: pauseTime)
        updateMain {
            self.isRecordingPaused = true
            self.recordingStatusMessage = "录制已暂停。点击继续后会恢复写入音频和视频。"
        }
    }

    func resumeLiveSession() {
        guard isRunning else { return }
        let resumeTime = recordingUptime()
        let didResume = stateQueue.sync {
            guard recordingPaused else { return false }
            recordingPaused = false
            captureTimeline.markPauseEnd(at: resumeTime)
            return true
        }
        guard didResume else { return }
        videoCaptureService.resumeRecording(at: resumeTime)
        startRecordingDurationTimer(at: resumeTime)
        updateMain {
            self.isRecordingPaused = false
            if self.recordingStatusMessage == "录制已暂停。点击继续后会恢复写入音频和视频。" {
                self.recordingStatusMessage = nil
            }
        }
    }

    func isLiveRecordingPaused() -> Bool {
        stateQueue.sync { recordingPaused }
    }

    func syncSessionHandleFromState() {
        let handle = stateQueue.sync { _sessionState }
        updateMain {
            self.sessionHandle = handle
        }
    }

    func currentActiveMeetingID() -> String? {
        stateQueue.sync { _sessionState.activeMeetingID }
    }

    func currentBuildTargetID() -> String? {
        stateQueue.sync { _sessionState.buildTargetID }
    }

    func rpcSource(for mode: AudioInputMode) -> String {
        switch mode {
        case .microphone: return "mic"
        case .systemAudio: return "system"
        case .mixed: return "mixed"
        }
    }

    // MARK: - Recording Duration Timer

    func beginRecordingClockForCapturedMedia() {
        // Video/audio composition starts where all selected media are available.
        // Waiting for the first visual frame must not inflate the visible duration.
        let commonStart = stateQueue.sync {
            [captureTimeline.audioStartSec, captureTimeline.videoStartSec].compactMap { $0 }.max()
        }
        startRecordingDurationTimer(at: commonStart)
        updateRecordingDuration(at: recordingUptime())
    }

    func startRecordingDurationTimer(at uptime: TimeInterval? = nil) {
        let startTime = uptime ?? recordingUptime()
        stopRecordingDurationTimer(at: startTime)
        recordingDurationAtClockStart = recordingDuration
        recordingClockStartUptime = startTime
        recordingDurationTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.updateRecordingDuration(at: self.recordingUptime())
        }
    }

    func stopRecordingDurationTimer(at uptime: TimeInterval? = nil) {
        updateRecordingDuration(at: uptime ?? recordingUptime())
        recordingDurationTimer?.invalidate()
        recordingDurationTimer = nil
        recordingClockStartUptime = nil
    }

    func updateRecordingDuration(at uptime: TimeInterval) {
        guard let startedAt = recordingClockStartUptime else { return }
        recordingDuration = recordingDurationAtClockStart + max(0, uptime - startedAt)
    }
}

enum UITestLaunchOptions {
    private static var arguments: [String] {
        ProcessInfo.processInfo.arguments
    }

    private static var environment: [String: String] {
        ProcessInfo.processInfo.environment
    }

    /// Enables synthetic UI workflow behavior. Storage, credentials and telemetry
    /// isolation use UITestStorageContext, including session-ID-only launches.
    static var isEnabled: Bool {
        environment["INSIGHTKIT_UI_TEST_MODE"] == "1"
            || arguments.contains("--ui-test-mode")
            || argumentValue(for: "-INSIGHTKIT_UI_TEST_MODE") == "1"
    }

    static var routeOverride: String {
        if let route = environment["INSIGHTKIT_UI_TEST_ROUTE"], !route.isEmpty {
            return route
        }
        if let route = argumentValue(for: "--ui-test-route"), !route.isEmpty {
            return route
        }
        if let route = argumentValue(for: "-INSIGHTKIT_UI_TEST_ROUTE"), !route.isEmpty {
            return route
        }
        if let inlineRoute = arguments.first(where: { $0.hasPrefix("--ui-test-route=") }) {
            return String(inlineRoute.dropFirst("--ui-test-route=".count))
        }
        return ""
    }

    private static func argumentValue(for flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }
}

extension LiveSessionViewModel {
    var isUITestingMode: Bool {
        UITestLaunchOptions.isEnabled
    }

    func configureForUITestingIfNeeded() {
        guard isUITestingMode else { return }
        errorMessage = nil
        sidecarLabel = "sidecar: ui-test"
        sidecarHealth = SidecarHealth(
            running: true,
            pid: 9999,
            socketPath: "/tmp/insightkit-ui-test.sock",
            uptimeSec: 0,
            isReady: true,
            lastErrorCode: "",
            lastLatencyMs: 0
        )
        permissionState = .granted
        selectedSystemSourceID = selectedSystemSourceID ?? "ui-test-system-source"
    }

    func startUITestSessionIfNeeded() -> Bool {
        guard isUITestingMode else { return false }

        resetSessionUI()

        let meetingID = "ui-test-live-session"
        stateQueue.sync {
            _isRunningLock.lock()
            _isRunning = true
            _isRunningLock.unlock()
            _sessionState.activeMeetingID = meetingID
            _sessionState.lastMeetingID = nil
            activeMode = inputMode
        }

        sessionHandle = SessionHandle(activeMeetingID: meetingID, lastMeetingID: nil)
        captureState = .capturing
        permissionState = .granted
        sessionPhase = .running
        recordingDuration = 83
        selectedSystemSourceID = selectedSystemSourceID ?? "ui-test-system-source"
        transcriptSegments = Self.uiTestTranscriptSegments
        mediaURL = nil
        reviewSourceMediaURL = nil
        reviewSourceStatusMessage = nil
        temporaryRecordingURL = nil
        recordingStatusMessage = nil
        metrics.firstSegmentMs = transcriptSegments.first?.startMs ?? 0
        metrics.segmentsIngested = transcriptSegments.count
        metrics.provider = "ui-test"
        metrics.lastRefreshAt = Date()
        currentPlaybackTime = nil
        reviewSourcePlaybackRequested = false
        notes = []
        smartMinutesData = nil
        lastInsightPackage = nil
        beginLiveBackgroundWork(meetingID: meetingID)
        startDelayedSummaryUITestScenario(meetingID: meetingID)
        return true
    }

    func stopUITestSessionIfNeeded(finalState: CaptureState) -> Bool {
        guard isUITestingMode, isRunning else { return false }
        stopDelayedSummaryUITestScenario()

        stopRecordingDurationTimer()
        stateQueue.sync {
            _isRunningLock.lock()
            _isRunning = false
            _isRunningLock.unlock()
            _sessionState.lastMeetingID = _sessionState.activeMeetingID
            _sessionState.activeMeetingID = nil
            recordingPaused = false
        }
        syncSessionHandleFromState()

        captureState = finalState
        sessionPhase = .postSession
        metrics.queueDepth = 0
        isRecordingPaused = false
        recordingDuration = max(recordingDuration, 83)
        return true
    }

    func buildUITestFinalInsightIfNeeded() -> Bool {
        guard isUITestingMode else { return false }
        stopDelayedSummaryUITestScenario()

        let result = InsightRefreshResult(
            package: Self.uiTestInsightPackage,
            updatedAt: Date(),
            provider: "ui-test",
            needsReviewCount: 0
        )
        updateWorkbench(result)
        lastInsightPackage = result.package
        captureState = .idle
        sessionPhase = .reviewing
        return true
    }

    private static var uiTestTranscriptSegments: [TranscriptSegment] {
        [
            TranscriptSegment(
                startMs: 0,
                endMs: 8_000,
                speaker: "主持人",
                source: "mic",
                text: "我们先确认本次会议的目标和交付时间。"
            ),
            TranscriptSegment(
                startMs: 18_000,
                endMs: 29_000,
                speaker: "产品",
                source: "mic",
                text: "第一版需要把实时转写链路和纪要流程都走通。"
            ),
            TranscriptSegment(
                startMs: 42_000,
                endMs: 56_000,
                speaker: "工程",
                source: "mic",
                text: "我们会先补稳定的辅助功能标识，再完善端到端测试。"
            ),
        ]
    }

    private static var uiTestInsightPackage: InsightPackageV1 {
        let spans = [
            InsightPackageV1.EvidenceSpan(startMs: 0, endMs: 8_000),
            InsightPackageV1.EvidenceSpan(startMs: 18_000, endMs: 29_000),
            InsightPackageV1.EvidenceSpan(startMs: 42_000, endMs: 56_000),
        ]

        return InsightPackageV1(
            sessionOverview: .init(
                title: "UI 测试会议",
                overview: "确认实时转写工作区的关键交互都可被稳定驱动。",
                topics: ["实时转写", "辅助功能", "E2E 测试"]
            ),
            highlightInsights: [
                .init(
                    quote: "第一版需要把实时转写链路和纪要流程都走通。",
                    reason: "定义了本次验证的核心范围。",
                    speaker: "产品",
                    evidenceSpan: spans[1]
                ),
            ],
            speakerPerspectives: [
                .init(
                    speaker: "工程",
                    viewpoints: ["优先补齐可被 UI 自动化稳定定位的交互节点。"],
                    evidenceSpans: [spans[2]]
                ),
            ],
            decisionLedger: [
                .init(
                    problem: "实时转写流程难以稳定自动化",
                    options: ["依赖真实权限", "补辅助功能标识后驱动"],
                    decision: "补齐辅助功能标识并加入测试专用状态",
                    rationale: "减少权限、侧车和环境抖动对 UI 自动化的影响。",
                    owner: "工程",
                    needsReview: false,
                    evidenceSpan: spans[2]
                ),
            ],
            actionTracks: [
                .init(
                    task: "补齐实时转写卡片的辅助功能标识",
                    owner: "工程",
                    dueAt: "今天",
                    priority: "high",
                    status: "open",
                    needsReview: false,
                    evidenceSpan: spans[2]
                ),
            ],
            timelineBeats: [
                .init(timestamp: "00:00", title: "目标确认", summary: "确认测试目标与交付范围。"),
                .init(timestamp: "00:18", title: "范围收敛", summary: "明确第一版需要覆盖的实时流程。"),
                .init(timestamp: "00:42", title: "实现方案", summary: "决定先补辅助功能标识与 E2E 用例。"),
            ],
            provenanceLinks: []
        )
    }
}
