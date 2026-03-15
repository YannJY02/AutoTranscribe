import AVFoundation
import AppKit
import Combine
import Foundation

protocol InsightRPCClientProtocol {
    func sessionStart(meetingID: String, title: String, source: String) throws
    func sessionStop(meetingID: String) throws
    func transcriptDelta(meetingID: String, segments: [RPCSegmentDelta]) throws -> Int
    func transcriptList(meetingID: String, limit: Int) throws -> [TranscriptSegment]
    func refreshLive(meetingID: String, windowSec: Int) throws -> InsightRefreshResult
    func buildFinal(meetingID: String) throws -> InsightRefreshResult
    func documentExport(meetingID: String, format: String, outputDir: String) throws -> DocumentExportResult
    func transcriptionImport(filePath: String, title: String) throws -> TranscriptionImportResult
    func transcriptionWatchStart(dirs: [String]) throws -> TranscriptionWatchResult
    func transcriptionWatchStop() throws -> TranscriptionWatchResult
    func transcriptionStatus(limit: Int?) throws -> TranscriptionStatusResult
    func transcriptionCancel(jobID: String, reason: String) throws -> TranscriptionCancelResult
    func sidecarStatus() throws -> [String: Any]
    func sidecarVersion() throws -> [String: Any]
    func sidecarShutdown() throws -> [String: Any]
    func ensureReady(timeoutSec: Int) throws -> [String: Any]
    func asrRuntimeStatus(engine: LocalASREngine?) throws -> ASRRuntimeStatus
    func asrRuntimeBootstrap(model: String, engine: LocalASREngine?) throws -> ASRBootstrapResult
    func asrPrewarm(model: String, engine: LocalASREngine?, timeoutSec: Int) throws -> ASRPrewarmResult
    func asrTranscribeChunk(wavPath: String, offsetMs: Int, source: String) throws -> [RPCSegmentDelta]
    func providersStatus(probeActive: Bool) throws -> AnalysisProvidersStatus
    func providerProbe(vendor: ProviderVendor, model: String, baseURL: String, forceRefresh: Bool) throws -> ProviderProbeResult
    func diagnosticsQuickCheck(probeTimeoutSec: Int) throws -> DiagnosticReport
}

extension InsightRPCClientProtocol {
    func transcriptionStatus() throws -> TranscriptionStatusResult {
        try transcriptionStatus(limit: nil)
    }

    func providersStatus() throws -> AnalysisProvidersStatus {
        try providersStatus(probeActive: false)
    }

    func diagnosticsQuickCheck() throws -> DiagnosticReport {
        try diagnosticsQuickCheck(probeTimeoutSec: 6)
    }
}

extension InsightRPCClient: InsightRPCClientProtocol {}

protocol LiveASRServiceProtocol {
    func transcribe(chunk: AudioChunk, source: String) throws -> [RPCSegmentDelta]
}

extension LiveASRService: LiveASRServiceProtocol {}

struct WarmupBacklogUpdate: Equatable {
    let queue: [AudioChunk]
    let droppedExisting: [AudioChunk]
    let droppedIncoming: Bool
    let bufferedAudioMs: Int
}

struct WarmupBacklogPolicy {
    let maxChunks: Int
    let maxBufferedAudioMs: Int

    func enqueue(_ chunk: AudioChunk, into queued: [AudioChunk]) -> WarmupBacklogUpdate {
        guard maxChunks > 0, maxBufferedAudioMs > 0 else {
            return WarmupBacklogUpdate(queue: queued, droppedExisting: [], droppedIncoming: true, bufferedAudioMs: queued.bufferedAudioMs)
        }

        var nextQueue = queued
        var droppedExisting: [AudioChunk] = []
        let incomingDuration = max(0, chunk.endMs - chunk.startMs)

        while !nextQueue.isEmpty && (nextQueue.count >= maxChunks || nextQueue.bufferedAudioMs + incomingDuration > maxBufferedAudioMs) {
            if let silentIndex = nextQueue.firstIndex(where: \.isLikelySilent) {
                droppedExisting.append(nextQueue.remove(at: silentIndex))
                continue
            }
            if chunk.isLikelySilent {
                return WarmupBacklogUpdate(
                    queue: nextQueue,
                    droppedExisting: droppedExisting,
                    droppedIncoming: true,
                    bufferedAudioMs: nextQueue.bufferedAudioMs
                )
            }
            droppedExisting.append(nextQueue.removeFirst())
        }

        if nextQueue.count >= maxChunks || nextQueue.bufferedAudioMs + incomingDuration > maxBufferedAudioMs {
            return WarmupBacklogUpdate(
                queue: nextQueue,
                droppedExisting: droppedExisting,
                droppedIncoming: true,
                bufferedAudioMs: nextQueue.bufferedAudioMs
            )
        }

        nextQueue.append(chunk)
        return WarmupBacklogUpdate(
            queue: nextQueue,
            droppedExisting: droppedExisting,
            droppedIncoming: false,
            bufferedAudioMs: nextQueue.bufferedAudioMs
        )
    }
}

enum WarmupRetryAction: Equatable {
    case retry(afterSeconds: Int)
    case failSession
}

struct WarmupRetryPolicy {
    let maxAutomaticRetries: Int
    let retryDelaySec: Int

    func action(forFailureCount failureCount: Int) -> WarmupRetryAction {
        if failureCount <= maxAutomaticRetries {
            return .retry(afterSeconds: retryDelaySec)
        }
        return .failSession
    }
}

enum LiveCaptureStateMapper {
    static func captureState(warmReady: Bool, hasTranscript: Bool) -> CaptureState {
        guard warmReady else { return .warmingModel }
        return hasTranscript ? .transcribing : .capturing
    }
}

private extension Array where Element == AudioChunk {
    var bufferedAudioMs: Int {
        reduce(0) { partialResult, chunk in
            partialResult + Swift.max(0, chunk.endMs - chunk.startMs)
        }
    }
}

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

    private let rpcClient: InsightRPCClientProtocol
    private let sidecarManager: SidecarManager
    private let micCapture: MicCaptureService
    private let systemAudioCapture: SystemAudioCaptureService
    private let mixBus: AudioMixBus
    private let chunkAssembler: ChunkAssembler
    private let asrService: LiveASRServiceProtocol

    private let pipelineQueue = DispatchQueue(label: "InsightKit.LiveSession.Pipeline")
    private let stateQueue = DispatchQueue(label: "InsightKit.LiveSession.State")
    /// Dedicated GCD queue for blocking RPC I/O – avoids exhausting Swift's
    /// cooperative thread pool which would stall all async/SwiftUI work.
    private let rpcQueue = DispatchQueue(label: "InsightKit.LiveSession.RPC", qos: .userInitiated)

    private var liveCoordinator = LiveInsightCoordinator()
    private var activeMode: AudioInputMode = .microphone
    private var recentFingerprints: [String] = []
    private var insightRefreshSuspended = false
    private var captureMonitorTask: Task<Void, Never>?
    private var lastCaptureHintAt: Date?

    private var _isRunning = false
    private var _sessionState = SessionHandle()
    private let _isRunningLock = NSLock()
    private var queuedChunks: [AudioChunk] = []
    private var chunkInFlight = false
    private let maxQueuedChunks = 8
    private let warmupBacklogPolicy = WarmupBacklogPolicy(maxChunks: 2, maxBufferedAudioMs: 8_000)
    private let warmupRetryPolicy = WarmupRetryPolicy(maxAutomaticRetries: 1, retryDelaySec: 2)
    private let warmupPollIntervalNs: UInt64 = 400_000_000
    private var warmupKickTask: Task<Void, Never>?
    private var warmupPollTask: Task<Void, Never>?
    private var warmupRetryTask: Task<Void, Never>?
    private var warmupFailureCount = 0
    private var warmupRetryScheduled = false

    // Fix 2: Throttle audio-level UI updates to ~15 Hz.
    private var lastMicLevelDispatch: Date?
    private var lastSystemLevelDispatch: Date?
    private var lastMicLevel: Float = 0
    private var lastSystemLevel: Float = 0

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

    var isRunning: Bool {
        _isRunningLock.lock()
        defer { _isRunningLock.unlock() }
        return _isRunning
    }

    var canStartSession: Bool {
        !isRunning
    }

    var canStopSession: Bool {
        isRunning
    }

    var canBuildFinal: Bool {
        currentBuildTargetID() != nil
    }

    var canExportDocument: Bool {
        currentBuildTargetID() != nil
    }

    var canChangeInputMode: Bool {
        !isRunning
    }

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
        if isRunning {
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
        analysisRuntimeState = .ready
        captureHealth = CaptureHealthSnapshot(
            sessionStartedAt: startupAt,
            lastChunkAt: nil,
            lastTranscriptAt: nil,
            inputLevelMic: 0,
            inputLevelSystem: 0
        )
        startCaptureHealthMonitor()

        // Split into: (1) blocking RPC on rpcQueue, then (2) async audio capture on Task.
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

                // Audio capture must be started from an async context
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

    private func stopLiveSession(finalState: CaptureState) {
        if !isRunning {
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

    func selectSystemSource(_ sourceID: String?) {
        selectedSystemSourceID = sourceID
    }

    func selectEvidence(_ range: EvidenceRange?) {
        selectedEvidence = range
    }

    func clearError() {
        errorMessage = nil
    }

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
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func handleMixedSamples(_ samples: [Float]) {
        if samples.isEmpty || !isRunning {
            return
        }

        pipelineQueue.async { [weak self] in
            guard let self else { return }
            guard self.isRunning else { return }
            do {
                let chunks = try self.chunkAssembler.append(samples: samples)
                guard let meetingID = self.currentActiveMeetingID() else { return }
                for chunk in chunks {
                    self.enqueueChunkForProcessing(chunk, meetingID: meetingID)
                }
            } catch {
                self.publishError(error)
            }
        }
    }

    private func enqueueChunkForProcessing(_ chunk: AudioChunk, meetingID: String) {
        if shouldHoldChunksForWarmup {
            let update = warmupBacklogPolicy.enqueue(chunk, into: queuedChunks)
            for dropped in update.droppedExisting {
                try? FileManager.default.removeItem(at: dropped.url)
            }
            if update.droppedIncoming {
                try? FileManager.default.removeItem(at: chunk.url)
            }
            queuedChunks = update.queue
            let droppedCount = update.droppedExisting.count + (update.droppedIncoming ? 1 : 0)
            updateMain {
                if droppedCount > 0 {
                    self.metrics.droppedChunks += droppedCount
                }
                self.metrics.queueDepth = self.queuedChunks.count
                self.liveWarmup.bufferedChunks = self.queuedChunks.count
                self.liveWarmup.bufferedAudioMs = update.bufferedAudioMs
            }
            return
        }

        if queuedChunks.count >= maxQueuedChunks {
            if let idx = queuedChunks.firstIndex(where: { $0.isLikelySilent }) {
                let dropped = queuedChunks.remove(at: idx)
                try? FileManager.default.removeItem(at: dropped.url)
                updateMain {
                    self.metrics.droppedChunks += 1
                }
            } else if chunk.isLikelySilent {
                try? FileManager.default.removeItem(at: chunk.url)
                updateMain {
                    self.metrics.droppedChunks += 1
                    self.metrics.queueDepth = self.queuedChunks.count
                }
                return
            } else if let dropped = queuedChunks.first {
                queuedChunks.removeFirst()
                try? FileManager.default.removeItem(at: dropped.url)
                updateMain {
                    self.metrics.droppedChunks += 1
                }
            }
        }

        queuedChunks.append(chunk)
        updateMain {
            self.metrics.queueDepth = self.queuedChunks.count
            self.liveWarmup.bufferedChunks = self.queuedChunks.count
            self.liveWarmup.bufferedAudioMs = self.queuedChunks.bufferedAudioMs
        }
        pumpChunkQueueIfNeeded(meetingID: meetingID)
    }

    private func pumpChunkQueueIfNeeded(meetingID: String) {
        guard !chunkInFlight else {
            return
        }
        guard !queuedChunks.isEmpty else {
            updateMain {
                self.metrics.queueDepth = 0
                self.liveWarmup.bufferedChunks = 0
                self.liveWarmup.bufferedAudioMs = 0
            }
            return
        }
        guard isRunning else {
            queuedChunks.removeAll(keepingCapacity: false)
            chunkInFlight = false
            updateMain {
                self.metrics.queueDepth = 0
                self.liveWarmup.bufferedChunks = 0
                self.liveWarmup.bufferedAudioMs = 0
            }
            return
        }

        chunkInFlight = true
        let chunk = queuedChunks.removeFirst()
        updateMain {
            self.metrics.queueDepth = self.queuedChunks.count
            self.liveWarmup.bufferedChunks = self.queuedChunks.count
            self.liveWarmup.bufferedAudioMs = self.queuedChunks.bufferedAudioMs
        }

        do {
            try processChunk(chunk, meetingID: meetingID)
        } catch {
            publishError(error)
        }

        chunkInFlight = false
        pumpChunkQueueIfNeeded(meetingID: meetingID)
    }

    private func processChunk(_ chunk: AudioChunk, meetingID: String) throws {
        updateMain {
            self.captureHealth.lastChunkAt = Date()
        }

        let t0 = Date()
        let source = rpcSource(for: activeMode)
        var segments = try rpcClient.asrTranscribeChunk(
            wavPath: chunk.url.path,
            offsetMs: chunk.startMs,
            source: source
        )
        segments = deduplicateSegments(segments)

        guard !segments.isEmpty else {
            updateMain {
                self.captureState = self.activeCaptureState
                self.metrics.chunkIndex = max(self.metrics.chunkIndex, chunk.index + 1)
            }
            return
        }

        let ingested = try rpcClient.transcriptDelta(meetingID: meetingID, segments: segments)
        let now = Date()

        // Prepare all values before dispatching to main thread.
        let newSegments = segments.map {
            TranscriptSegment(
                startMs: $0.startMs,
                endMs: $0.endMs,
                speaker: $0.speaker.isEmpty ? "未标注" : $0.speaker,
                source: $0.source,
                text: $0.text
            )
        }
        let latencyMs = Int(now.timeIntervalSince(t0) * 1000)
        let chunkIdx = chunk.index + 1

        var shouldRefresh = false
        stateQueue.sync {
            shouldRefresh = liveCoordinator.registerIngested(ingested, now: now)
        }

        if shouldRefresh {
            let refreshSuspended = stateQueue.sync { insightRefreshSuspended }
            if refreshSuspended {
                // Fix 3: Single batched update for paused-analysis path.
                updateMain {
                    self.metrics.chunkIndex = max(self.metrics.chunkIndex, chunkIdx)
                    self.metrics.latencyMs = latencyMs
                    self.metrics.segmentsIngested += ingested
                    if self.metrics.firstSegmentMs == 0, let startedAt = self.captureHealth.sessionStartedAt {
                        self.metrics.firstSegmentMs = max(1, Int(now.timeIntervalSince(startedAt) * 1000))
                    }
                    self.transcriptSegments.append(contentsOf: newSegments)
                    self.transcriptSegments.sort { $0.startMs < $1.startMs }
                    self.captureHealth.lastTranscriptAt = now
                    self.captureState = self.activeCaptureState
                    self.metrics.provider = "analysis-paused"
                }
                return
            }
            // Insight refresh path.
            updateMain {
                self.captureState = .refreshing
            }
            do {
                let result = try rpcClient.refreshLive(meetingID: meetingID, windowSec: 120)
                stateQueue.sync {
                    liveCoordinator.markRefreshed(at: now)
                    insightRefreshSuspended = false
                }
                // Fix 3: Single batched update combining metrics + segments + workbench.
                updateMain {
                    self.metrics.chunkIndex = max(self.metrics.chunkIndex, chunkIdx)
                    self.metrics.latencyMs = latencyMs
                    self.metrics.segmentsIngested += ingested
                    if self.metrics.firstSegmentMs == 0, let startedAt = self.captureHealth.sessionStartedAt {
                        self.metrics.firstSegmentMs = max(1, Int(now.timeIntervalSince(startedAt) * 1000))
                    }
                    self.transcriptSegments.append(contentsOf: newSegments)
                    self.transcriptSegments.sort { $0.startMs < $1.startMs }
                    self.captureHealth.lastTranscriptAt = now
                    self.analysisRuntimeState = .ready
                    self.captureState = self.activeCaptureState
                }
                updateWorkbench(result)
            } catch {
                if isProviderAuthFailure(error) || isProviderProbeTimeout(error) {
                    stateQueue.sync {
                        liveCoordinator.markRefreshed(at: now)
                        insightRefreshSuspended = true
                    }
                    updateMain {
                        self.metrics.chunkIndex = max(self.metrics.chunkIndex, chunkIdx)
                        self.metrics.latencyMs = latencyMs
                        self.metrics.segmentsIngested += ingested
                        if self.metrics.firstSegmentMs == 0, let startedAt = self.captureHealth.sessionStartedAt {
                            self.metrics.firstSegmentMs = max(1, Int(now.timeIntervalSince(startedAt) * 1000))
                        }
                        self.transcriptSegments.append(contentsOf: newSegments)
                        self.transcriptSegments.sort { $0.startMs < $1.startMs }
                        self.captureHealth.lastTranscriptAt = now
                        self.captureState = self.activeCaptureState
                        self.metrics.provider = "analysis-paused"
                        if self.isProviderProbeTimeout(error) {
                            self.analysisRuntimeState = .pausedTimeout
                            self.errorMessage = "智能分析探测超时，转写继续、洞察已暂停。请稍后重试或检查网络。"
                        } else {
                            self.analysisRuntimeState = .pausedAuthFailed
                            self.errorMessage = "智能分析服务鉴权失败，转写继续、洞察已暂停。请打开设置修复 API 配置后重新开始直播洞察。"
                        }
                    }
                } else {
                    throw error
                }
            }
            return
        }

        // Fix 3: Single batched update for no-refresh path.
        updateMain {
            self.metrics.chunkIndex = max(self.metrics.chunkIndex, chunkIdx)
            self.metrics.latencyMs = latencyMs
            self.metrics.segmentsIngested += ingested
            if self.metrics.firstSegmentMs == 0, let startedAt = self.captureHealth.sessionStartedAt {
                self.metrics.firstSegmentMs = max(1, Int(now.timeIntervalSince(startedAt) * 1000))
            }
            self.transcriptSegments.append(contentsOf: newSegments)
            self.transcriptSegments.sort { $0.startMs < $1.startMs }
            self.captureHealth.lastTranscriptAt = now
            self.captureState = self.activeCaptureState
        }
    }

    private func deduplicateSegments(_ segments: [RPCSegmentDelta]) -> [RPCSegmentDelta] {
        var result: [RPCSegmentDelta] = []

        for seg in segments {
            let normalizedText = seg.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if normalizedText.isEmpty {
                continue
            }
            let key = "\(seg.startMs / 500)-\(normalizedText)"
            if recentFingerprints.contains(key) {
                continue
            }
            recentFingerprints.append(key)
            if recentFingerprints.count > 40 {
                recentFingerprints.removeFirst(recentFingerprints.count - 40)
            }
            result.append(seg)
        }

        return result
    }

    private func updateWorkbench(_ result: InsightRefreshResult) {
        let package = result.package
        updateMain {
            self.workbench = InsightWorkbenchState(
                sessionOverview: package.sessionOverview.overview,
                highlightInsights: package.highlightInsights.map {
                    WorkbenchItem(
                        title: $0.quote,
                        body: $0.reason,
                        meta: $0.speaker.isEmpty ? "" : "发言人：\($0.speaker)",
                        evidence: $0.evidenceSpan.range
                    )
                },
                speakerPerspectives: package.speakerPerspectives.map {
                    WorkbenchItem(
                        title: $0.speaker,
                        body: $0.viewpoints.joined(separator: "\n"),
                        meta: "观点数：\($0.viewpoints.count)",
                        evidence: $0.evidenceSpans.first?.range
                    )
                },
                decisionLedger: package.decisionLedger.map {
                    WorkbenchItem(
                        title: $0.problem,
                        body: "方案：\($0.options.joined(separator: " / "))\n决策：\($0.decision)\n依据：\($0.rationale)",
                        meta: "负责人：\($0.owner)\(($0.needsReview == true) ? " · 需复核" : "")",
                        evidence: $0.evidenceSpan.range
                    )
                },
                actionTracks: package.actionTracks.map {
                    WorkbenchItem(
                        title: $0.task,
                        body: "负责人：\($0.owner)\n截止：\($0.dueAt.isEmpty ? "未设置" : $0.dueAt)",
                        meta: "状态：\($0.status) · 优先级：\($0.priority)\(($0.needsReview == true) ? " · 需复核" : "")",
                        evidence: $0.evidenceSpan.range
                    )
                },
                timelineBeats: package.timelineBeats.map {
                    WorkbenchItem(
                        title: "\($0.timestamp) \($0.title)",
                        body: $0.summary,
                        meta: "",
                        evidence: nil
                    )
                }
            )

            self.actionItems = package.actionTracks.map {
                ActionItem(
                    task: $0.task,
                    owner: $0.owner,
                    status: $0.status,
                    dueAt: $0.dueAt,
                    priority: $0.priority,
                    needsReview: $0.needsReview ?? false,
                    evidence: $0.evidenceSpan.range
                )
            }

            self.metrics.provider = result.provider
            self.metrics.needsReviewCount = result.needsReviewCount
            self.metrics.lastRefreshAt = result.updatedAt ?? Date()
        }
    }

    private func resetSessionUI() {
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

    private func syncActionTracksToWorkbench() {
        workbench.actionTracks = actionItems.map { item in
            WorkbenchItem(
                title: item.task,
                body: "负责人：\(item.owner)\n截止：\(item.dueAt.isEmpty ? "未设置" : item.dueAt)",
                meta: "状态：\(item.status) · 优先级：\(item.priority)\(item.needsReview ? " · 需复核" : "")",
                evidence: item.evidence
            )
        }
    }

    private func publishError(_ error: Error) {
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

    private func updateMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    private var shouldHoldChunksForWarmup: Bool {
        !asrWarmStatus.ready
    }

    private var activeCaptureState: CaptureState {
        LiveCaptureStateMapper.captureState(
            warmReady: asrWarmStatus.ready,
            hasTranscript: metrics.firstSegmentMs > 0 || !transcriptSegments.isEmpty
        )
    }

    private func cancelWarmupTasks(cancelRetry: Bool = true) {
        warmupKickTask?.cancel()
        warmupKickTask = nil
        warmupPollTask?.cancel()
        warmupPollTask = nil
        if cancelRetry {
            warmupRetryTask?.cancel()
            warmupRetryTask = nil
        }
    }

    private func performRPC<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            rpcQueue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func beginWarmupLifecycle(
        meetingID: String,
        startupAt: Date,
        engine: LocalASREngine,
        model: String,
        resetFailures: Bool = true
    ) {
        cancelWarmupTasks(cancelRetry: false)
        if resetFailures {
            stateQueue.sync {
                warmupFailureCount = 0
                warmupRetryScheduled = false
            }
        }
        updateMain {
            self.captureState = .warmingModel
            self.liveWarmup.state = self.asrWarmStatus.ready ? .ready : .loading
            self.liveWarmup.attempt = max(self.liveWarmup.attempt, self.asrWarmStatus.attempt)
            self.liveWarmup.isRetryScheduled = false
            self.liveWarmup.automaticRetryCount = self.stateQueue.sync { self.warmupFailureCount }
            if self.asrWarmStatus.ready {
                self.liveWarmup.lastError = ""
            }
        }

        if asrWarmStatus.ready {
            markWarmReady(meetingID: meetingID, startupAt: startupAt, backend: asrBackendStatus, warm: asrWarmStatus)
            return
        }

        warmupKickTask = Task { [weak self] in
            guard let self else { return }
            await self.runWarmupKick(meetingID: meetingID, startupAt: startupAt, engine: engine, model: model)
        }
        warmupPollTask = Task { [weak self] in
            guard let self else { return }
            await self.runWarmupPoll(meetingID: meetingID, startupAt: startupAt, engine: engine, model: model)
        }
    }

    private func runWarmupKick(
        meetingID: String,
        startupAt: Date,
        engine: LocalASREngine,
        model: String
    ) async {
        do {
            let result = try await performRPC {
                try self.rpcClient.asrPrewarm(model: model, engine: engine, timeoutSec: 20)
            }
            applyWarmSnapshot(result.warm, backend: result.backend)
            if result.warm.ready || result.state == .ready {
                markWarmReady(meetingID: meetingID, startupAt: startupAt, backend: result.backend, warm: result.warm)
            } else if result.state == .failed || result.warm.state == .failed {
                await handleWarmFailure(
                    message: result.error.isEmpty ? result.warm.lastError : result.error,
                    meetingID: meetingID,
                    startupAt: startupAt,
                    engine: engine,
                    model: model,
                    attempt: max(result.attempt, result.warm.attempt)
                )
            }
        } catch {
            await handleWarmFailure(
                message: error.localizedDescription,
                meetingID: meetingID,
                startupAt: startupAt,
                engine: engine,
                model: model,
                attempt: max(1, asrWarmStatus.attempt)
            )
        }
    }

    private func runWarmupPoll(
        meetingID: String,
        startupAt: Date,
        engine: LocalASREngine,
        model: String
    ) async {
        while !Task.isCancelled {
            if !isRunning || currentActiveMeetingID() != meetingID {
                return
            }
            do {
                let status = try await performRPC {
                    try self.rpcClient.asrRuntimeStatus(engine: engine)
                }
                applyWarmSnapshot(status.warm, backend: status.backend)
                if status.warm.ready {
                    markWarmReady(meetingID: meetingID, startupAt: startupAt, backend: status.backend, warm: status.warm)
                    return
                }
                if status.warm.state == .failed {
                    await handleWarmFailure(
                        message: status.warm.lastError,
                        meetingID: meetingID,
                        startupAt: startupAt,
                        engine: engine,
                        model: model,
                        attempt: status.warm.attempt
                    )
                    return
                }
            } catch {
                await handleWarmFailure(
                    message: error.localizedDescription,
                    meetingID: meetingID,
                    startupAt: startupAt,
                    engine: engine,
                    model: model,
                    attempt: max(1, asrWarmStatus.attempt)
                )
                return
            }
            try? await Task.sleep(nanoseconds: warmupPollIntervalNs)
        }
    }

    private func applyWarmSnapshot(_ warm: ASRWarmStatus, backend: ASRBackendStatus) {
        updateMain {
            self.asrBackendStatus = backend
            self.asrWarmStatus = warm
            self.liveWarmup.state = warm.state
            self.liveWarmup.attempt = max(self.liveWarmup.attempt, warm.attempt)
            self.liveWarmup.lastError = warm.lastError
            self.liveWarmup.isRetryScheduled = self.stateQueue.sync { self.warmupRetryScheduled }
            self.liveWarmup.automaticRetryCount = self.stateQueue.sync { self.warmupFailureCount }
        }
    }

    private func markWarmReady(
        meetingID: String,
        startupAt: Date,
        backend: ASRBackendStatus,
        warm: ASRWarmStatus
    ) {
        let warmReadyMs = max(warm.lastWarmMs, Int(Date().timeIntervalSince(startupAt) * 1000))
        stateQueue.sync {
            warmupRetryScheduled = false
        }
        updateMain {
            self.asrBackendStatus = backend
            self.asrWarmStatus = warm
            if self.metrics.warmReadyMs == 0 {
                self.metrics.warmReadyMs = warmReadyMs
            } else {
                self.metrics.warmReadyMs = max(self.metrics.warmReadyMs, warmReadyMs)
            }
            self.liveWarmup.state = .ready
            self.liveWarmup.attempt = max(self.liveWarmup.attempt, warm.attempt)
            self.liveWarmup.lastError = ""
            self.liveWarmup.isRetryScheduled = false
            self.captureState = self.activeCaptureState
        }
        pipelineQueue.async { [weak self] in
            guard let self else { return }
            self.pumpChunkQueueIfNeeded(meetingID: meetingID)
        }
    }

    private func handleWarmFailure(
        message: String,
        meetingID: String,
        startupAt: Date,
        engine: LocalASREngine,
        model: String,
        attempt: Int
    ) async {
        guard isRunning, currentActiveMeetingID() == meetingID else {
            return
        }

        let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "模型预热失败。"
            : message

        let decision: WarmupRetryAction = stateQueue.sync {
            if warmupRetryScheduled {
                return .retry(afterSeconds: warmupRetryPolicy.retryDelaySec)
            }
            warmupFailureCount += 1
            return warmupRetryPolicy.action(forFailureCount: warmupFailureCount)
        }

        let failedWarm = ASRWarmStatus(
            ready: false,
            state: .failed,
            inProgress: false,
            attempt: max(1, attempt),
            lastWarmMs: asrWarmStatus.lastWarmMs,
            lastError: normalizedMessage
        )
        applyWarmSnapshot(failedWarm, backend: asrBackendStatus)

        switch decision {
        case .retry(let afterSeconds):
            let shouldSchedule = stateQueue.sync {
                if warmupRetryScheduled {
                    return false
                }
                warmupRetryScheduled = true
                return true
            }
            guard shouldSchedule else { return }

            updateMain {
                self.captureState = .warmingModel
                self.errorMessage = "本地语音识别预热失败，\(afterSeconds)s 后自动重试。"
                self.liveWarmup.isRetryScheduled = true
                self.liveWarmup.automaticRetryCount = self.stateQueue.sync { self.warmupFailureCount }
            }

            warmupRetryTask?.cancel()
            warmupRetryTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(afterSeconds) * 1_000_000_000)
                guard !Task.isCancelled, self.isRunning, self.currentActiveMeetingID() == meetingID else {
                    return
                }
                self.stateQueue.sync {
                    self.warmupRetryScheduled = false
                }
                self.warmupRetryTask = nil
                self.beginWarmupLifecycle(
                    meetingID: meetingID,
                    startupAt: startupAt,
                    engine: engine,
                    model: model,
                    resetFailures: false
                )
            }
        case .failSession:
            updateMain {
                self.errorMessage = normalizedMessage
            }
            stopLiveSession(finalState: .error(normalizedMessage))
        }
    }

    private func syncSessionHandleFromState() {
        let handle = stateQueue.sync { _sessionState }
        updateMain {
            self.sessionHandle = handle
        }
    }

    private func currentActiveMeetingID() -> String? {
        stateQueue.sync { _sessionState.activeMeetingID }
    }

    private func currentBuildTargetID() -> String? {
        stateQueue.sync { _sessionState.buildTargetID }
    }

    private func rpcSource(for mode: AudioInputMode) -> String {
        switch mode {
        case .microphone:
            return "mic"
        case .systemAudio:
            return "system"
        case .mixed:
            return "mixed"
        }
    }

    private func probeProvidersInBackground() {
        rpcQueue.async { [weak self] in
            guard let self else { return }
            guard self.isRunning else { return }
            do {
                try self.ensureRuntimeReady(requireASR: false, requireProvider: true, allowProviderProbeFailure: true)
            } catch {
                self.updateMain {
                    if self.errorMessage == nil || self.errorMessage?.isEmpty == true {
                        self.errorMessage = "智能分析暂不可用，转写继续。请在设置中完成服务配置后重试。"
                    }
                }
            }
        }
    }

    private func ensureRuntimeReady(requireASR: Bool, requireProvider: Bool, allowProviderProbeFailure: Bool) throws {
        func restartAndRetry() throws {
            try sidecarManager.rebootstrap(ensureReady: { [weak self] in
                guard let self else { return }
                _ = try self.rpcClient.ensureReady(timeoutSec: 6)
            })
        }

        if requireASR {
            let selectedEngine = AppConfigStore.shared.config.asr.engine
            let selectedModel = AppConfigStore.shared.currentASRModel()
            let asr: ASRRuntimeStatus
            do {
                asr = try rpcClient.asrRuntimeStatus(engine: selectedEngine)
            } catch {
                if error.localizedDescription.lowercased().contains("method not found: asr.runtime.status") {
                    try restartAndRetry()
                    asr = try rpcClient.asrRuntimeStatus(engine: selectedEngine)
                } else {
                    throw error
                }
            }
            updateMain {
                self.asrBackendStatus = asr.backend
                self.asrWarmStatus = asr.warm
            }
            if !asr.ready {
                if AppConfigStore.shared.config.download.autoBootstrapEnabled {
                    _ = try rpcClient.asrRuntimeBootstrap(model: selectedModel, engine: selectedEngine)
                    let retried = try rpcClient.asrRuntimeStatus(engine: selectedEngine)
                    updateMain {
                        self.asrBackendStatus = retried.backend
                        self.asrWarmStatus = retried.warm
                    }
                    if retried.ready {
                        return
                    }
                }
                throw NSError(
                    domain: "InsightKit",
                    code: -4201,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "本地语音识别未就绪（\(selectedEngine.displayName) / \(asr.modelName)）。请打开设置，点击“一键修复语音识别”。",
                    ]
                )
            }
        }

        if requireProvider {
            let configStore = AppConfigStore.shared
            let selectedVendor = configStore.config.analysis.selectedVendor
            let selectedProfile = configStore.profile(for: selectedVendor)
            let providers: AnalysisProvidersStatus
            do {
                providers = try rpcClient.providersStatus(probeActive: false)
            } catch {
                if error.localizedDescription.lowercased().contains("method not found: analysis.providers.status") {
                    try restartAndRetry()
                    providers = try rpcClient.providersStatus(probeActive: false)
                } else if allowProviderProbeFailure && isProviderProbeTimeout(error) {
                    stateQueue.sync { insightRefreshSuspended = true }
                    updateMain {
                        self.analysisRuntimeState = .pausedTimeout
                        self.errorMessage = "智能分析探测超时，转写继续、洞察已暂停。"
                    }
                    return
                } else {
                    throw error
                }
            }
            if !providers.activeReady {
                updateMain {
                    self.analysisRuntimeState = .missingConfig
                }
                throw NSError(
                    domain: "InsightKit",
                    code: -4202,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "分析模型未配置完成（当前厂商: \(providers.selectedVendor.displayName)）。请在设置中填写 API Key 与 Model ID。",
                    ]
                )
            }

            let probe: ProviderProbeResult
            do {
                probe = try rpcClient.providerProbe(
                    vendor: selectedVendor,
                    model: selectedProfile.modelID,
                    baseURL: selectedProfile.baseURL,
                    forceRefresh: true
                )
            } catch {
                if error.localizedDescription.lowercased().contains("method not found: analysis.provider.probe") {
                    try restartAndRetry()
                    probe = try rpcClient.providerProbe(
                        vendor: selectedVendor,
                        model: selectedProfile.modelID,
                        baseURL: selectedProfile.baseURL,
                        forceRefresh: true
                    )
                } else if allowProviderProbeFailure && isProviderProbeTimeout(error) {
                    stateQueue.sync { insightRefreshSuspended = true }
                    updateMain {
                        self.analysisRuntimeState = .pausedTimeout
                        self.errorMessage = "智能分析探测超时，转写继续、洞察已暂停。"
                    }
                    return
                } else {
                    throw error
                }
            }
            if !probe.ok {
                if allowProviderProbeFailure {
                    stateQueue.sync { insightRefreshSuspended = true }
                    updateMain {
                        self.analysisRuntimeState = probe.code == .authFailed ? .pausedAuthFailed : .pausedTimeout
                        self.errorMessage = "智能分析暂不可用，转写继续、洞察已暂停。请在设置中修复后重试。"
                    }
                    return
                }
                var msg = probe.message
                if !probe.hint.isEmpty {
                    msg += " \(probe.hint)"
                }
                throw NSError(
                    domain: "InsightKit",
                    code: -4203,
                    userInfo: [NSLocalizedDescriptionKey: msg]
                )
            }
            stateQueue.sync { insightRefreshSuspended = false }
            updateMain {
                self.analysisRuntimeState = .ready
            }
        }
    }

    private func isProviderAuthFailure(_ error: Error) -> Bool {
        let lower = error.localizedDescription.lowercased()
        if lower.contains("鉴权失败") || lower.contains("authentication fails") {
            return true
        }
        return lower.contains("http 401") || lower.contains("governor")
    }

    private func isProviderProbeTimeout(_ error: Error) -> Bool {
        let lower = error.localizedDescription.lowercased()
        return lower.contains("调用超时: analysis.provider.probe")
            || lower.contains("调用超时: analysis.providers.status")
            || lower.contains("probe_timeout")
    }

    private func recordInputLevel(buffer: AVAudioPCMBuffer, source: AudioMixBus.Source) {
        let level = rmsLevel(buffer)
        let now = Date()
        let minInterval: TimeInterval = 0.067 // ~15 Hz
        let threshold: Float = 0.02

        switch source {
        case .microphone:
            if let last = lastMicLevelDispatch,
               now.timeIntervalSince(last) < minInterval,
               abs(level - lastMicLevel) < threshold {
                return
            }
            lastMicLevel = level
            lastMicLevelDispatch = now
        case .systemAudio:
            if let last = lastSystemLevelDispatch,
               now.timeIntervalSince(last) < minInterval,
               abs(level - lastSystemLevel) < threshold {
                return
            }
            lastSystemLevel = level
            lastSystemLevelDispatch = now
        }

        updateMain {
            switch source {
            case .microphone:
                self.captureHealth.inputLevelMic = level
            case .systemAudio:
                self.captureHealth.inputLevelSystem = level
            }
        }
    }

    private func rmsLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard buffer.frameLength > 0 else { return 0 }
        if let channel = buffer.floatChannelData?[0] {
            let count = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<count {
                let v = channel[i]
                sum += v * v
            }
            return min(1, sqrt(sum / Float(count)))
        }
        return 0
    }

    private func startCaptureHealthMonitor() {
        captureMonitorTask?.cancel()
        captureMonitorTask = Task.detached { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if !self.isRunning {
                    break
                }
                await self.evaluateCaptureHealthHint()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    @MainActor
    private func evaluateCaptureHealthHint() {
        guard isRunning else { return }
        switch captureState {
        case .preparingRuntime, .warmingModel:
            return
        default:
            break
        }
        let now = Date()
        if let last = lastCaptureHintAt, now.timeIntervalSince(last) < 10 {
            return
        }
        guard let started = captureHealth.sessionStartedAt else { return }
        if captureHealth.lastChunkAt == nil, now.timeIntervalSince(started) >= 10 {
            errorMessage = "采集无输入：请检查音频源选择、麦克风/屏幕录制权限，或先切换到“仅麦克风”排查。"
            lastCaptureHintAt = now
            return
        }

        if captureHealth.lastTranscriptAt == nil, now.timeIntervalSince(started) >= 20 {
            errorMessage = "识别中：当前暂未产出文本，可能是静音、环境噪声或音量过低。"
            lastCaptureHintAt = now
        }
    }

    private func assertSidecarCapabilities(_ required: [String]) throws {
        let version: [String: Any]
        do {
            version = try rpcClient.sidecarVersion()
        } catch {
            if error.localizedDescription.lowercased().contains("method not found: sidecar.version") {
                return
            }
            throw error
        }
        guard let actions = version["capabilities"] as? [String], !actions.isEmpty else {
            return
        }
        let missing = required.filter { !actions.contains($0) }
        if !missing.isEmpty {
            throw NSError(
                domain: "InsightKit",
                code: -4301,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "当前侧车版本缺少实时能力（\(missing.joined(separator: ", "))）。请在设置执行“一键测试服务”并重启应用。",
                ]
            )
        }
    }
}
