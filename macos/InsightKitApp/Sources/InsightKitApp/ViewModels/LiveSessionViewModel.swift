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

    // Queues — internal so extensions can access them
    let pipelineQueue = DispatchQueue(label: "InsightKit.LiveSession.Pipeline")
    let stateQueue = DispatchQueue(label: "InsightKit.LiveSession.State")
    /// Dedicated GCD queue for blocking RPC I/O – avoids exhausting Swift's
    /// cooperative thread pool which would stall all async/SwiftUI work.
    let rpcQueue = DispatchQueue(label: "InsightKit.LiveSession.RPC", qos: .userInitiated)

    // Session state — internal so extensions can access them
    var liveCoordinator = LiveInsightCoordinator()
    var activeMode: AudioInputMode = .microphone
    var recentFingerprints: [String] = []
    var insightRefreshSuspended = false
    var captureMonitorTask: Task<Void, Never>?
    var lastCaptureHintAt: Date?

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

    init(
        rpcClient: InsightRPCClientProtocol = InsightRPCClient(),
        sidecarManager: SidecarManager = SidecarManager(),
        micCapture: MicCaptureService = MicCaptureService(),
        systemAudioCapture: SystemAudioCaptureService = SystemAudioCaptureService(),
        mixBus: AudioMixBus = AudioMixBus(),
        chunkAssembler: ChunkAssembler = ChunkAssembler(),
        asrService: LiveASRServiceProtocol = LiveASRService()
    ) {
        self.rpcClient = rpcClient
        self.sidecarManager = sidecarManager
        self.micCapture = micCapture
        self.systemAudioCapture = systemAudioCapture
        self.mixBus = mixBus
        self.chunkAssembler = chunkAssembler
        self.asrService = asrService

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

        refreshSidecarStatus()
    }

    deinit {
        stopLiveSession()
        sidecarManager.stop()
    }

    // MARK: - Computed State

    var isRunning: Bool {
        _isRunningLock.lock()
        defer { _isRunningLock.unlock() }
        return _isRunning
    }

    var canStartSession: Bool { !isRunning }
    var canStopSession: Bool { isRunning }
    var canBuildFinal: Bool { currentBuildTargetID() != nil }
    var canExportDocument: Bool { currentBuildTargetID() != nil }
    var canChangeInputMode: Bool { !isRunning }

    var shouldHoldChunksForWarmup: Bool { !asrWarmStatus.ready }

    var activeCaptureState: CaptureState {
        LiveCaptureStateMapper.captureState(
            warmReady: asrWarmStatus.ready,
            hasTranscript: metrics.firstSegmentMs > 0 || !transcriptSegments.isEmpty
        )
    }

    // MARK: - Session Lifecycle

    func prepareForLiveEntry() {
        guard !isRunning else { return }
        inputMode = .microphone
        activeMode = .microphone
        mixBus.setMode(.microphone)
    }

    func reloadSystemAudioSources() {
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
        rpcQueue.async { [weak self] in
            guard let self else { return }
            do {
                let status = try self.rpcClient.sidecarStatus()
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
                self.updateMain {
                    self.sidecarHealth = .unknown
                    self.sidecarLabel = "sidecar: down"
                }
            }
        }
    }

    func startLiveSession() {
        if isRunning { return }

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

        stateQueue.sync {
            _isRunningLock.lock()
            _isRunning = true
            _isRunningLock.unlock()
            _sessionState.activeMeetingID = meetingID
            _sessionState.lastMeetingID = nil
            activeMode = selectedMode
            insightRefreshSuspended = false
            liveCoordinator.reset()
            recentFingerprints.removeAll(keepingCapacity: true)
        }

        updateMain {
            self.sessionHandle = SessionHandle(activeMeetingID: meetingID, lastMeetingID: nil)
        }

        mixBus.setMode(selectedMode)
        captureState = .preparingRuntime
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
                    "asr.prewarm",
                    "transcript.delta",
                    "insight.refresh_live",
                ])
                try self.ensureRuntimeReady(requireASR: true, requireProvider: false, allowProviderProbeFailure: true)
                try self.rpcClient.sessionStart(meetingID: meetingID, title: "直播洞察", source: source)
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
                        self.permissionState = .granted
                        self.beginWarmupLifecycle(
                            meetingID: meetingID,
                            startupAt: startupAt,
                            engine: selectedEngine,
                            model: selectedModel
                        )
                    } catch {
                        self.publishError(error)
                        self.stopLiveSession(finalState: .error(error.localizedDescription))
                    }
                }
            } catch {
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

        stateQueue.sync {
            _isRunningLock.lock()
            _isRunning = false
            _isRunningLock.unlock()
        }
        captureMonitorTask?.cancel()
        captureMonitorTask = nil
        cancelWarmupTasks()

        micCapture.stop()
        Task {
            await systemAudioCapture.stop()
        }

        pipelineQueue.async { [weak self] in
            guard let self else { return }
            let activeMeetingID = self.currentActiveMeetingID()
            let shouldFlushTail = self.asrWarmStatus.ready
            do {
                self.queuedChunks.removeAll(keepingCapacity: false)
                self.chunkInFlight = false
                if shouldFlushTail {
                    let tail = try self.chunkAssembler.flush(minDurationSec: 1.0)
                    if let meetingID = activeMeetingID {
                        for chunk in tail {
                            try self.processChunk(chunk, meetingID: meetingID)
                        }
                    }
                }
                if let meetingID = activeMeetingID {
                    try? self.rpcClient.sessionStop(meetingID: meetingID)
                }
            } catch {
                self.publishError(error)
            }

            self.chunkAssembler.reset()
            self.stateQueue.sync {
                self.liveCoordinator.reset()
                self._sessionState.lastMeetingID = activeMeetingID ?? self._sessionState.lastMeetingID
                self._sessionState.activeMeetingID = nil
            }
            self.syncSessionHandleFromState()
            self.updateMain {
                self.metrics.queueDepth = 0
                self.captureState = finalState
            }
        }
    }

    func buildFinalInsight() {
        rpcQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.sidecarManager.startIfNeeded(ensureReady: { [weak self] in
                    guard let self else { return }
                    _ = try self.rpcClient.ensureReady(timeoutSec: 6)
                })
                self.refreshSidecarStatus()
                try self.ensureRuntimeReady(requireASR: false, requireProvider: true, allowProviderProbeFailure: false)
                guard let meetingID = self.currentBuildTargetID() else {
                    throw NSError(domain: "InsightKit", code: -2, userInfo: [NSLocalizedDescriptionKey: "当前无会话，无法生成定稿洞察"])
                }
                self.updateMain {
                    self.captureState = .refreshing
                }
                let result = try self.rpcClient.buildFinal(meetingID: meetingID)
                self.updateWorkbench(result)
                self.updateMain {
                    self.captureState = .idle
                }
            } catch {
                self.publishError(error)
            }
        }
    }

    func exportDocument(format: String = "markdown") {
        rpcQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.sidecarManager.startIfNeeded(ensureReady: { [weak self] in
                    guard let self else { return }
                    _ = try self.rpcClient.ensureReady(timeoutSec: 6)
                })
                try self.ensureRuntimeReady(requireASR: false, requireProvider: true, allowProviderProbeFailure: false)
                guard let meetingID = self.currentBuildTargetID() else {
                    throw NSError(domain: "InsightKit", code: -3, userInfo: [NSLocalizedDescriptionKey: "当前无会话，无法导出文档"])
                }
                let result = try self.rpcClient.documentExport(meetingID: meetingID, format: format, outputDir: "txt")
                self.updateMain {
                    self.lastExportPath = result.path
                }
            } catch {
                self.publishError(error)
            }
        }
    }

    func resetForNewSession() {
        stopLiveSession()
        stateQueue.sync {
            self._sessionState = SessionHandle()
        }
        syncSessionHandleFromState()
        resetSessionUI()
        prepareForLiveEntry()
        refreshSidecarStatus()
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
        let lower = raw.lowercased()
        if lower.contains("method not found")
            || lower.contains("circuit-open")
            || lower.contains("sidecar.ensure_ready") {
            message = "本地服务版本或状态异常，请打开设置执行“一键测试服务”并重启应用。"
        } else if lower.contains("traceback") {
            message = "本地服务执行失败，请稍后重试；若持续失败，请在设置执行“一键修复语音识别”。"
        }

        updateMain {
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
}
