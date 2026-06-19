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

    // Phase 4: Panel protocol support
    @Published var sessionPhase: SessionPhase = .preparing
    @Published var chapters: [ChapterSummary] = []
    @Published var smartMinutesData: SmartMinutes?
    @Published var notes: [TimestampedNote] = []
    @Published var currentPlaybackTime: TimeInterval?
    @Published var mediaSeekRequest: MediaSeekRequest?
    @Published var recordingDuration: TimeInterval = 0
    @Published var recordingStatusMessage: String?
    @Published var mediaURL: URL?
    let videoCaptureService = VideoCaptureService()
    var recordingDurationTimer: Timer?

    // Phase 5: Records persistence
    var recordsService: RecordsIndexService?
    var temporaryRecordingURL: URL?
    var lastInsightPackage: InsightPackageV1?

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

        configureForUITestingIfNeeded()
        refreshSidecarStatus()
    }

    deinit {
        shutdown()
    }

    func shutdown() {
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
    var hasPersistedRecordForExport: Bool {
        RecordDocumentExporter.hasPersistedRecord(meetingID: currentBuildTargetID(), recordsService: recordsService)
    }
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
        if isUITestingMode {
            updateMain {
                self.configureForUITestingIfNeeded()
            }
            return
        }
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
                        self.startRecordingDurationTimer()
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

        if stopUITestSessionIfNeeded(finalState: finalState) {
            return
        }

        stateQueue.sync {
            _isRunningLock.lock()
            _isRunning = false
            _isRunningLock.unlock()
        }
        captureMonitorTask?.cancel()
        captureMonitorTask = nil
        cancelWarmupTasks()
        stopRecordingDurationTimer()

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
                    _ = self.prepareTemporaryRecordingForSave(meetingID: meetingID)
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
                self.sessionPhase = .postSession
            }
            // Save record folder after session ends
            if let meetingID = activeMeetingID {
                self.saveToRecords(meetingID: meetingID)
            }
        }
    }

    func buildFinalInsight() {
        if buildUITestFinalInsightIfNeeded() {
            return
        }

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
                    self.lastInsightPackage = result.package
                    self.captureState = .idle
                    self.sessionPhase = .reviewing
                }
                self.saveToRecords(meetingID: meetingID, insightPackageOverride: result.package)
            } catch {
                self.publishError(error)
            }
        }
    }

    func exportDocument(format: String = "markdown") {
        rpcQueue.async { [weak self] in
            guard let self else { return }
            do {
                guard let meetingID = self.currentBuildTargetID() else {
                    throw NSError(domain: "InsightKit", code: -3, userInfo: [NSLocalizedDescriptionKey: "当前无会话，无法导出文档"])
                }
                if let url = try RecordDocumentExporter.exportIfPersistedRecordExists(
                    format: format,
                    meetingID: meetingID,
                    recordsService: self.recordsService
                ) {
                    self.updateMain {
                        self.lastExportPath = url.path
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

    // MARK: - Camera Preview

    func startCameraPreview() {
        if isUITestingMode {
            return
        }
        videoCaptureService.checkCameraPermission()
        switch videoCaptureService.cameraPermission {
        case .denied:
            // Already denied — open settings instead of crashing
            videoCaptureService.openCameraSettings()
            return
        case .unknown:
            // Not determined — request permission (requires NSCameraUsageDescription)
            Task { @MainActor in
                let granted = await videoCaptureService.requestCameraPermission()
                if granted {
                    startCameraCapture()
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
            guard let firstCamera = self.videoCaptureService.availableCameras.first else { return }
            try? self.videoCaptureService.startCamera(deviceID: firstCamera.id)
        }
    }

    func stopCameraPreview() {
        if isUITestingMode {
            return
        }
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
        // Phase 4 panel state
        sessionPhase = .preparing
        chapters = []
        smartMinutesData = nil
        notes = []
        currentPlaybackTime = nil
        mediaSeekRequest = nil
        recordingDuration = 0
        recordingStatusMessage = nil
        mediaURL = nil
        stopRecordingDurationTimer()
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
        let startTime = Date()
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
        temporaryRecordingURL = nil
        recordingStatusMessage = nil
        metrics.firstSegmentMs = transcriptSegments.first?.startMs ?? 0
        metrics.segmentsIngested = transcriptSegments.count
        metrics.provider = "ui-test"
        metrics.lastRefreshAt = Date()
        currentPlaybackTime = nil
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
