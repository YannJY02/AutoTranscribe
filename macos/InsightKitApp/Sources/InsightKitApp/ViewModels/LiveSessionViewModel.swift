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

    // Queues — internal so extensions can access them
    let pipelineQueue = DispatchQueue(label: "InsightKit.LiveSession.Pipeline")
    let stateQueue = DispatchQueue(label: "InsightKit.LiveSession.State")
    /// Dedicated GCD queue for blocking RPC I/O – avoids exhausting Swift's
    /// cooperative thread pool which would stall all async/SwiftUI work.
    let rpcQueue = DispatchQueue(label: "InsightKit.LiveSession.RPC", qos: .userInitiated)

    // Session state — internal so extensions can access them
    var activeMode: AudioInputMode = .microphone
    var insightRefreshSuspended = false
    var stopDrainingMeetingID: String?
    var captureMonitorTask: Task<Void, Never>?
    var lastCaptureHintAt: Date?
    var recordingPaused = false

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
    var visualSelectionUsesScreenOnlyFallback = false

    // Phase 5: Records persistence
    var recordsService: RecordsIndexService?
    var temporaryRecordingURL: URL?
    var finalizedMediaTranscriptCache: (mediaPath: String, segments: [TranscriptSegment])?
    var finalMediaTranscriptRetryDelays: [TimeInterval] = [1, 2, 4, 8, 15]
    var lastInsightPackage: InsightPackageV1?
    var captureTimeline = LiveMediaCaptureTimeline()
    var pendingPresentationCaptureStatus: LivePresentationCaptureStatus?

    init(
        rpcClient: InsightRPCClientProtocol = InsightRPCClient(),
        sidecarManager: SidecarManager = SidecarManager(),
        micCapture: MicCaptureService = MicCaptureService(),
        systemAudioCapture: SystemAudioCaptureService = SystemAudioCaptureService(),
        mixBus: AudioMixBus = AudioMixBus(),
        chunkAssembler: ChunkAssembler = ChunkAssembler(),
        asrService: LiveASRServiceProtocol = LiveASRService(),
        transcriptPipeline: LiveTranscriptProcessing? = nil,
        reviewMediaComposer: ReviewMediaComposing = AVFoundationReviewMediaComposer(),
        mediaAssetInspector: MediaAssetInspecting = AVFoundationMediaAssetInspector(),
        finalMediaTranscriber: FinalMediaTranscribing? = nil,
        transcriptRecoveryService: TranscriptRecoveryServicing? = nil,
        analyticsSubmit: @escaping (@escaping (ProductAnalytics) -> Void) -> Void = ProductAnalytics.submit
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
        self.transcriptPipeline = transcriptPipeline ?? LiveTranscriptPipeline(
            runtime: InsightRPCLiveTranscriptPipelineRuntime(rpcClient: rpcClient)
        )

        self.micCapture.onBuffer = { [weak self] buffer in
            self?.recordInputLevel(buffer: buffer, source: .microphone)
            self?.mixBus.ingestMicrophone(buffer)
        }

        self.systemAudioCapture.onBuffer = { [weak self] buffer in
            self?.recordInputLevel(buffer: buffer, source: .systemAudio)
            self?.mixBus.ingestSystemAudio(buffer)
        }

        self.mixBus.onMixedSamples = { [weak self] samples in
            self?.handleMixedSamples(samples)
        }
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
        captureMonitorTask?.cancel()
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
        !isRunning && currentActiveMeetingID() == nil
    }
    var canStopSession: Bool { isRunning }
    var canBuildFinal: Bool { currentBuildTargetID() != nil }
    var canExportDocument: Bool { currentBuildTargetID() != nil && !isExporting }
    var hasPersistedRecordForExport: Bool {
        RecordDocumentExporter.hasPersistedRecord(meetingID: currentBuildTargetID(), recordsService: recordsService)
    }
    var canChangeInputMode: Bool { !isRunning }
    var isFinalizingRecording: Bool { isFinalizingLiveSession }

    var shouldHoldChunksForWarmup: Bool { !asrWarmStatus.ready }

    var activeCaptureState: CaptureState {
        LiveCaptureStateMapper.captureState(
            warmReady: asrWarmStatus.ready,
            hasTranscript: metrics.firstSegmentMs > 0 || !transcriptSegments.isEmpty
        )
    }

    var liveProgressPresentation: LiveProgressPresentation? {
        if isFinalizingLiveSession {
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

    func reloadSystemAudioSources() {
        if isUITestingMode {
            updateMain {
                self.systemAudioSources = [
                    SystemAudioSourceItem(
                        id: "ui-test-system-source",
                        kind: .display,
                        title: "主显示器",
                        subtitle: "内置显示器"
                    ),
                ]
                self.selectedSystemSourceID = "ui-test-system-source"
                self.permissionState = .granted
                self.errorMessage = nil
            }
            return
        }
        Task {
            do {
                let sources = try await systemAudioCapture.listSources()
                updateMain {
                    self.systemAudioSources = sources
                    if self.selectedSystemSourceID == nil {
                        self.selectedSystemSourceID = sources.first?.id
                    }
                }
            } catch {
                publishError(error)
            }
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
            activeMode = selectedMode
            insightRefreshSuspended = false
            recordingPaused = false
            captureTimeline.reset()
        }
        transcriptPipeline.reset()

        updateMain {
            self.sessionHandle = SessionHandle(activeMeetingID: meetingID, lastMeetingID: nil)
        }

        mixBus.setMode(selectedMode)
        captureState = .preparingRuntime
        sessionPhase = .running
        analysisRuntimeState = .ready
        captureHealth = CaptureHealthSnapshot(
            sessionStartedAt: startupAt,
            lastChunkAt: nil,
            lastTranscriptAt: nil,
            inputLevelMic: 0,
            inputLevelSystem: 0
        )
        startCaptureHealthMonitor()

        rpcQueue.async { [weak self] in
            guard let self else { return }
            do {
                let selectedEngine = AppConfigStore.shared.config.asr.engine
                let selectedModel = AppConfigStore.shared.currentASRModel()
                try self.sidecarManager.startIfNeeded(ensureReady: { [weak self] in
                    guard let self else { return }
                    _ = try self.rpcClient.ensureReady(timeoutSec: 6)
                })
                self.refreshSidecarStatus()
                try self.assertSidecarCapabilities([
                    "session.start",
                    "session.stop",
                    "asr.transcribe_chunk",
                    "asr.transcribe_media",
                    "asr.prewarm",
                    "transcript.delta",
                    "transcript.replace",
                    "insight.refresh_live",
                    "records.save",
                ])
                try self.ensureRuntimeReady(requireASR: true, requireProvider: false, allowProviderProbeFailure: true)
                try self.rpcClient.sessionStart(meetingID: meetingID, title: "直播洞察", source: source)
                let analyticsPath = ProductAnalyticsPath(
                    providers: try? self.rpcClient.providersStatus(probeActive: false),
                    analysisMode: selectedAnalysisMode
                )
                self.analyticsSubmit { $0.resolveWorkflow("live", path: analyticsPath) }
                self.updateMain {
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

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        if selectedMode != .systemAudio {
                            try await self.micCapture.start()
                        }
                        if selectedMode != .microphone {
                            guard let sourceID = self.selectedSystemSourceID else {
                                throw NSError(domain: "InsightKit", code: -1, userInfo: [NSLocalizedDescriptionKey: "缺少系统音频源"])
                            }
                            try await self.systemAudioCapture.start(sourceID: sourceID)
                        }
                        self.startVisualRecordingIfNeeded(meetingID: meetingID)
                        self.permissionState = .granted
                        self.startRecordingDurationTimer()
                        self.beginWarmupLifecycle(
                            meetingID: meetingID,
                            startupAt: startupAt,
                            engine: selectedEngine,
                            model: selectedModel
                        )
                    } catch {
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
            } catch {
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

    func stopLiveSession() {
        stopLiveSession(finalState: .idle)
    }

    func stopLiveSession(finalState: CaptureState) {
        if !isRunning { return }

        if stopUITestSessionIfNeeded(finalState: finalState) {
            return
        }

        let stopTime = ProcessInfo.processInfo.systemUptime
        let activeMeetingID = stateQueue.sync {
            _isRunningLock.lock()
            _isRunning = false
            _isRunningLock.unlock()
            if recordingPaused {
                captureTimeline.markPauseEnd(at: stopTime)
            }
            recordingPaused = false
            stopDrainingMeetingID = _sessionState.activeMeetingID
            return _sessionState.activeMeetingID
        }
        captureMonitorTask?.cancel()
        captureMonitorTask = nil
        cancelWarmupTasks()
        stopRecordingDurationTimer()
        updateMain {
            self.isFinalizingLiveSession = true
            self.isRecordingPaused = false
            self.recordingStatusMessage = "录制已停止，正在处理剩余音频并生成最终转写，请保持应用打开。"
        }

        micCapture.stop()
        Task {
            await systemAudioCapture.stop()
        }
        let presentationCaptureStatus = currentPresentationCaptureStatus()
        pendingPresentationCaptureStatus = presentationCaptureStatus
        let expectedVisualMedia = presentationCaptureStatus != nil
        if expectedVisualMedia {
            temporaryRecordingURL = self.videoCaptureService.finishRecording()
        }
        self.videoCaptureService.stopCapture()

        pipelineQueue.async { [weak self] in
            guard let self else { return }
            let shouldFlushTail = self.asrWarmStatus.ready
            var drainedSegments: [TranscriptSegment] = []
            var finalizationLeaseToken: String?
            do {
                let pendingChunks = self.queuedChunks
                self.queuedChunks.removeAll(keepingCapacity: false)
                self.chunkInFlight = false
                if let meetingID = activeMeetingID {
                    for chunk in pendingChunks {
                        let outcome = try self.processChunk(chunk, meetingID: meetingID)
                        drainedSegments.append(contentsOf: outcome.transcriptSegments)
                    }
                }
                if shouldFlushTail {
                    let tail = try self.chunkAssembler.flush(minDurationSec: 1.0)
                    if let meetingID = activeMeetingID {
                        for chunk in tail {
                            let outcome = try self.processChunk(chunk, meetingID: meetingID)
                            drainedSegments.append(contentsOf: outcome.transcriptSegments)
                        }
                    }
                }
                if let meetingID = activeMeetingID {
                    let leaseToken = UUID().uuidString
                    finalizationLeaseToken = leaseToken
                    try self.rpcClient.sessionStopForFinalization(
                        meetingID: meetingID,
                        leaseToken: leaseToken
                    )
                    _ = self.prepareTemporaryRecordingForSave(
                        meetingID: meetingID,
                        expectedVisualMedia: expectedVisualMedia
                    )
                }
            } catch {
                self.publishError(error)
            }

            self.chunkAssembler.reset()
            self.stateQueue.sync {
                self._sessionState.lastMeetingID = activeMeetingID ?? self._sessionState.lastMeetingID
                self._sessionState.activeMeetingID = nil
                self.stopDrainingMeetingID = nil
            }
            self.transcriptPipeline.reset()
            self.syncSessionHandleFromState()
            self.updateMain {
                self.metrics.queueDepth = 0
                self.captureState = finalState
                self.sessionPhase = .postSession
            }
            // Save record folder after session ends
            if let meetingID = activeMeetingID {
                let transcriptOverride = (self.transcriptSegments + drainedSegments)
                    .sorted { $0.startMs < $1.startMs }
                self.saveToRecords(
                    meetingID: meetingID,
                    transcriptSegmentsOverride: transcriptOverride.isEmpty ? nil : transcriptOverride,
                    finalizationLeaseToken: finalizationLeaseToken
                )
            } else {
                self.updateMain {
                    self.isFinalizingLiveSession = false
                }
            }
        }
    }

    func buildFinalInsight() {
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
                        ProductAnalytics.submit { analytics in
                            analytics.exportCompleted("live")
                            analytics.workflowCompleted("live", evaluation: .evaluate(recordPath: recordPath, duration: duration, exportCompleted: true, hasBlockingError: hasBlockingError))
                        }
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
                    ProductAnalytics.submit { analytics in
                        analytics.exportCompleted("live")
                        analytics.workflowCompleted("live", evaluation: .evaluate(recordPath: recordPath, duration: duration, exportCompleted: true, hasBlockingError: hasBlockingError))
                    }
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
        let analyticsPhase = sessionPhase == .postSession
            ? "finalizing"
            : sessionPhase == .reviewing ? "reviewing" : "running"
        analyticsSubmit { $0.workflowCancelled("live", phase: analyticsPhase) }
        stopLiveSession()
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

    func startVisualRecordingIfNeeded(meetingID: String) {
        guard visualPreviewSource != .none else { return }
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InsightKit")
            .appendingPathComponent(meetingID)
        let outputURL = tmpDir.appendingPathComponent("recording.mp4")

        do {
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            try videoCaptureService.startRecording(to: outputURL)
            stateQueue.sync {
                captureTimeline.markVideoStart()
            }
            temporaryRecordingURL = outputURL
        } catch {
            temporaryRecordingURL = nil
            capturePreviewStatusMessage = "视频回看录制未能启动；本次结束后将保留音频、转写与笔记。\(error.localizedDescription)"
        }
    }

    func applyVisualPreviewSelection(cameraEnabled: Bool, screenEnabled: Bool) {
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
        videoCaptureService.checkCameraPermission()
        switch videoCaptureService.cameraPermission {
        case .denied:
            // Already denied — open settings instead of crashing
            capturePreviewStatusMessage = "摄像头权限未开启。请在系统设置中允许 InsightKit 使用摄像头。"
            videoCaptureService.openCameraSettings()
            return
        case .unknown:
            // Not determined — request permission (requires NSCameraUsageDescription)
            Task { @MainActor in
                let granted = await videoCaptureService.requestCameraPermission()
                if granted {
                    startCameraCapture()
                } else {
                    capturePreviewStatusMessage = "摄像头权限未开启。请在系统设置中允许 InsightKit 使用摄像头。"
                }
            }
        case .granted:
            startCameraCapture()
        }
    }

    private func startCameraCapture() {
        videoCaptureService.enumerateCameras()
        // enumerateCameras dispatches to main async; wait briefly for results
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
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

        Task { [weak self] in
            guard let self else { return }
            await self.videoCaptureService.enumerateScreens()
            await MainActor.run {
                self.startFirstAvailableScreenPreview(receivingMessage: message)
            }
        }
    }

    func startPresenterOverlayPreview() {
        if isUITestingMode {
            return
        }
        capturePreviewStatusMessage = "屏幕录制 + Presenter Overlay。请在 macOS 视频效果菜单中确认演示者叠加；如果未开启，本次 Record 将仅包含屏幕。"
        videoCaptureService.checkCameraPermission()
        switch videoCaptureService.cameraPermission {
        case .denied:
            capturePreviewStatusMessage = "摄像头权限未开启。请在系统设置中允许 InsightKit 使用摄像头，Presenter Overlay 才能由 macOS 合入画面。"
            videoCaptureService.openCameraSettings()
            return
        case .unknown:
            Task { @MainActor in
                let granted = await videoCaptureService.requestCameraPermission()
                if granted {
                    startPresenterOverlayScreenPreview()
                } else {
                    capturePreviewStatusMessage = "摄像头权限未开启。请在系统设置中允许 InsightKit 使用摄像头，Presenter Overlay 才能由 macOS 合入画面。"
                }
            }
        case .granted:
            startPresenterOverlayScreenPreview()
        }
    }

    private func startPresenterOverlayScreenPreview() {
        Task { [weak self] in
            guard let self else { return }
            await self.videoCaptureService.enumerateScreens()
            await MainActor.run {
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
        videoCaptureService.checkCameraPermission()
        switch videoCaptureService.cameraPermission {
        case .denied:
            startScreenOnlyFallbackPreview(reason: "摄像头权限未开启。当前仅保存屏幕；摄像头不会写入本次 Record。")
        case .unknown:
            Task { @MainActor in
                let granted = await videoCaptureService.requestCameraPermission()
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
        Task { [weak self] in
            guard let self else { return }
            await self.videoCaptureService.enumerateScreens()
            await MainActor.run {
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
        Task { [weak self] in
            guard let self else { return }
            do {
                if usesCameraOverlay {
                    try await self.videoCaptureService.startScreenCaptureWithCameraOverlay(displayID: displayID)
                } else if usesPresenterOverlayPicker {
                    try await self.videoCaptureService.startPresenterOverlayCapture(displayID: displayID)
                } else {
                    try await self.videoCaptureService.startScreenCapture(displayID: displayID)
                }
            } catch {
                await MainActor.run {
                    if usesCameraOverlay {
                        self.visualSelectionUsesScreenOnlyFallback = true
                        self.visualPreviewSource = .screen
                        self.capturePreviewStatusMessage = "摄像头叠加未能启动，当前仅保存屏幕；摄像头不会写入本次 Record。\(error.localizedDescription)"
                    } else {
                        self.capturePreviewStatusMessage = "\(error.localizedDescription) 请在系统设置中允许 InsightKit 录制屏幕。"
                    }
                }
                if usesCameraOverlay {
                    do {
                        try await self.videoCaptureService.startScreenCapture(displayID: displayID)
                    } catch {
                        await MainActor.run {
                            self.capturePreviewStatusMessage = "\(error.localizedDescription) 请在系统设置中允许 InsightKit 录制屏幕。"
                        }
                    }
                }
            }
        }
    }

    func stopCameraPreview() {
        if isUITestingMode {
            return
        }
        visualPreviewSource = .none
        capturePreviewStatusMessage = nil
        videoCaptureService.stopCapture()
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
        cancelWarmupTasks()
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
        chunkAssembler.reset()
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
            captureTimeline.reset()
        }
        stopRecordingDurationTimer()
        isRecordingPaused = false
    }

    func pauseLiveSession() {
        guard isRunning else { return }
        let pauseTime = ProcessInfo.processInfo.systemUptime
        let didPause = stateQueue.sync {
            guard !recordingPaused else { return false }
            recordingPaused = true
            captureTimeline.markPauseStart(at: pauseTime)
            return true
        }
        guard didPause else { return }
        videoCaptureService.pauseRecording(at: pauseTime)
        stopRecordingDurationTimer()
        updateMain {
            self.isRecordingPaused = true
            self.recordingStatusMessage = "录制已暂停。点击继续后会恢复写入音频和视频。"
        }
    }

    func resumeLiveSession() {
        guard isRunning else { return }
        let resumeTime = ProcessInfo.processInfo.systemUptime
        let didResume = stateQueue.sync {
            guard recordingPaused else { return false }
            recordingPaused = false
            captureTimeline.markPauseEnd(at: resumeTime)
            return true
        }
        guard didResume else { return }
        videoCaptureService.resumeRecording(at: resumeTime)
        startRecordingDurationTimer()
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

    func startRecordingDurationTimer() {
        stopRecordingDurationTimer()
        let startTime = Date().addingTimeInterval(-recordingDuration)
        recordingDurationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.recordingDuration = Date().timeIntervalSince(startTime)
        }
    }

    func stopRecordingDurationTimer() {
        recordingDurationTimer?.invalidate()
        recordingDurationTimer = nil
    }
}

enum UITestLaunchOptions {
    private static var arguments: [String] {
        ProcessInfo.processInfo.arguments
    }

    private static var environment: [String: String] {
        ProcessInfo.processInfo.environment
    }

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
        return true
    }

    func stopUITestSessionIfNeeded(finalState: CaptureState) -> Bool {
        guard isUITestingMode, isRunning else { return false }

        stateQueue.sync {
            _isRunningLock.lock()
            _isRunning = false
            _isRunningLock.unlock()
            _sessionState.lastMeetingID = _sessionState.activeMeetingID
            _sessionState.activeMeetingID = nil
        }
        syncSessionHandleFromState()

        captureState = finalState
        sessionPhase = .postSession
        metrics.queueDepth = 0
        recordingDuration = max(recordingDuration, 83)
        return true
    }

    func buildUITestFinalInsightIfNeeded() -> Bool {
        guard isUITestingMode else { return false }

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
