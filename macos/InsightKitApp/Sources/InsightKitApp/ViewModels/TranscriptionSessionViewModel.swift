import Foundation

final class TranscriptionSessionViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var selectedTab: InsightTab = .sessionOverview
    @Published var readingMode = true
    @Published var focusMode = false
    @Published var isExecutionPanelVisible = false

    @Published var transcriptSegments: [TranscriptSegment] = []
    @Published var workbench: InsightWorkbenchState = .empty
    @Published var actionItems: [ActionItem] = []
    @Published var selectedEvidence: EvidenceRange?

    @Published var jobs: [TranscriptionJob] = []
    @Published var watcherState = TranscriptionWatcherState()
    @Published var currentMeetingID: String?
    @Published var lastExportPath: String = ""

    @Published var metrics = LiveSessionMetrics()
    @Published var errorMessage: String?
    @Published var inlineError: InlineErrorState?
    @Published var sidecarLabel = "sidecar: unknown"
    @Published var sidecarHealth = SidecarHealth.unknown
    @Published var sidecarSnapshot = SidecarHealthSnapshot(lastErrorCode: "", lastLatencyMs: 0)
    @Published var pollingMode: TranscriptionPollingMode = .idle
    @Published var analysisRuntimeState: AnalysisRuntimeState = .ready
    @Published private(set) var isBuildingFinalInsight = false
    @Published private(set) var hasPendingSidecarMutation = false

    private let rpcClient: InsightRPCClientProtocol
    private let sidecarManager: SidecarManager
    private let bootstrapSidecar: Bool
    private let analyticsSubmit: (@escaping (ProductAnalytics) -> Void) -> Void
    var recordsService: RecordsIndexService?

    private var pollTask: Task<Void, Never>?
    private var knownCompletedJobIDs: Set<String> = []
    private var analyticsContextsByJobID: [String: ProductAnalyticsAttemptContext] = [:]
    private var analyticsTerminalJobIDs: Set<String> = []
    private var currentAnalyticsContext: ProductAnalyticsAttemptContext?
    private var watcherAnalyticsPath: ProductAnalyticsPath = .unavailable
    private var watcherAnalyticsStartedAt: Date?
    private var retireWatcherAnalyticsAfterRefresh = false
    private var pollFailureStreak = 0
    private var pollIntervalSec: UInt64 = 2
    private var sidecarReadyInSession = false
    private var lastInlineErrorMessage = ""
    private var lastInlineErrorAt: Date?
    private let fetchLock = NSLock()
    private var fetchInFlight = false
    private var pendingSidecarMutationCount = 0
    private var buildingFinalMeetingID: String?
    private var pendingArtifactMeetingIDs: [String] = []
    /// Dedicated GCD queue for blocking RPC I/O – avoids exhausting Swift's
    /// cooperative thread pool which would stall all async/SwiftUI work.
    private let rpcQueue = DispatchQueue(label: "InsightKit.TranscriptionSession.RPC", qos: .userInitiated)

    init(
        rpcClient: InsightRPCClientProtocol = InsightRPCClient(),
        sidecarManager: SidecarManager = SidecarManager(),
        autoRefresh: Bool = true,
        autoPolling: Bool = true,
        bootstrapSidecar: Bool = true,
        analyticsSubmit: @escaping (@escaping (ProductAnalytics) -> Void) -> Void = ProductAnalytics.submit
    ) {
        self.rpcClient = rpcClient
        self.sidecarManager = sidecarManager
        self.bootstrapSidecar = bootstrapSidecar
        self.analyticsSubmit = analyticsSubmit
        if autoRefresh {
            refreshStatus()
        }
        if autoPolling { startPolling() }
    }

    deinit {
        shutdown()
    }

    func shutdown() {
        endMonitoring()
        sidecarManager.stop()
    }

    var canBuildFinal: Bool {
        currentMeetingID != nil
    }

    var canExportDocument: Bool {
        currentMeetingID != nil
    }

    var hasPersistedRecordForExport: Bool {
        RecordDocumentExporter.hasPersistedRecord(meetingID: currentMeetingID, recordsService: recordsService)
    }

    var activeJob: TranscriptionJob? {
        jobs.first(where: { $0.state == .running })
    }

    func refreshStatus() {
        guard beginFetchIfNeeded() else { return }
        rpcQueue.async { [weak self] in
            guard let self else { return }
            self.fetchStatusSync(isPolling: false)
        }
    }

    func importFile(path: String, title: String = "") {
        let analyticsContext = ProductAnalyticsAttemptContext(workflow: "import")
        analyticsSubmit { $0.beginWorkflow(analyticsContext, provisionalPath: .unavailable) }
        beginSidecarMutation()
        rpcQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.ensureSidecarReady()
                try self.ensureRuntimeReady(requireASR: true, requireProvider: false, allowProviderProbeFailure: true)
                let analyticsPath = self.refreshProviderStateNonBlocking()
                let result = try self.rpcClient.transcriptionImport(filePath: path, title: title)
                self.analyticsSubmit { $0.resolveWorkflow(analyticsContext, path: analyticsPath) }
                DispatchQueue.main.async {
                    self.analyticsContextsByJobID[result.jobID] = analyticsContext
                    self.currentAnalyticsContext = analyticsContext
                    self.currentMeetingID = result.meetingID
                }
                let status = try self.rpcClient.transcriptionStatus(limit: 100)
                let sidecar = try? self.rpcClient.sidecarStatus()
                DispatchQueue.main.async {
                    _ = self.applyStatusSync(status, sidecar: sidecar)
                    self.endSidecarMutation()
                }
            } catch {
                self.analyticsSubmit {
                    $0.workflowFailed(
                        analyticsContext,
                        phase: "preparing",
                        errorCode: "runtime-unavailable",
                        recoveryAction: "retry"
                    )
                }
                DispatchQueue.main.async {
                    self.publishErrorSync(error)
                    self.endSidecarMutation()
                }
            }
        }
    }

    func transcriptAnalyticsContext(fallbackKey: String) -> ProductAnalyticsContext {
        let path = ProductAnalyticsPath(provider: metrics.provider)
        guard let currentAnalyticsContext else {
            return ProductAnalyticsContext(workflow: "import", path: path, key: fallbackKey)
        }
        return ProductAnalyticsContext(attempt: currentAnalyticsContext, path: path)
    }

    func startWatcher(dirs: [String]) {
        beginSidecarMutation()
        rpcQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.ensureSidecarReady()
                try self.ensureRuntimeReady(requireASR: true, requireProvider: false, allowProviderProbeFailure: true)
                let analyticsPath = self.refreshProviderStateNonBlocking()
                let analyticsStartedAt = Date()
                _ = try self.rpcClient.transcriptionWatchStart(dirs: dirs)
                DispatchQueue.main.async {
                    self.watcherAnalyticsPath = analyticsPath
                    self.watcherAnalyticsStartedAt = analyticsStartedAt
                    self.retireWatcherAnalyticsAfterRefresh = false
                }
                let status = try self.rpcClient.transcriptionStatus(limit: 100)
                let sidecar = try? self.rpcClient.sidecarStatus()
                DispatchQueue.main.async {
                    _ = self.applyStatusSync(status, sidecar: sidecar)
                    self.endSidecarMutation()
                }
            } catch {
                DispatchQueue.main.async {
                    self.publishErrorSync(error)
                    self.endSidecarMutation()
                }
            }
        }
    }

    func stopWatcher() {
        beginSidecarMutation()
        rpcQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.ensureSidecarReady()
                _ = try self.rpcClient.transcriptionWatchStop()
                DispatchQueue.main.async { self.retireWatcherAnalyticsAfterRefresh = true }
                let status = try self.rpcClient.transcriptionStatus(limit: 100)
                let sidecar = try? self.rpcClient.sidecarStatus()
                DispatchQueue.main.async {
                    _ = self.applyStatusSync(status, sidecar: sidecar)
                    self.endSidecarMutation()
                }
            } catch {
                DispatchQueue.main.async {
                    self.publishErrorSync(error)
                    self.endSidecarMutation()
                }
            }
        }
    }

    func cancelJob(jobID: String, reason: String = "cancelled_by_user") {
        let analyticsContext = analyticsContextsByJobID[jobID]
        beginSidecarMutation()
        rpcQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.ensureSidecarReady()
                let result = try self.rpcClient.transcriptionCancel(jobID: jobID, reason: reason)
                if let analyticsContext, result.state == .cancelled || result.state == .pausedByLive {
                    ProductAnalytics.submit { $0.workflowCancelled(analyticsContext) }
                    DispatchQueue.main.async { self.analyticsTerminalJobIDs.insert(jobID) }
                }
                let status = try self.rpcClient.transcriptionStatus(limit: 100)
                let sidecar = try? self.rpcClient.sidecarStatus()
                DispatchQueue.main.async {
                    _ = self.applyStatusSync(status, sidecar: sidecar)
                    self.endSidecarMutation()
                }
            } catch {
                DispatchQueue.main.async {
                    self.publishErrorSync(error)
                    self.endSidecarMutation()
                }
            }
        }
    }

    func preemptForLive() {
        if watcherState.isRunning {
            stopWatcher()
        }

        if let running = activeJob {
            cancelJob(jobID: running.id, reason: "preempted_by_live")
            return
        }

        if let queued = jobs.first(where: { $0.state == .queued }) {
            cancelJob(jobID: queued.id, reason: "preempted_by_live")
        }
    }

    func buildFinalInsight() {
        guard let meetingID = currentMeetingID else {
            let msg = "当前没有可定稿的转写会话。"
            errorMessage = msg
            inlineError = InlineErrorState(message: msg, occurredAt: Date())
            return
        }
        guard !isBuildingFinalInsight else { return }
        isBuildingFinalInsight = true
        buildingFinalMeetingID = meetingID
        beginSidecarMutation()

        let analyticsContext = currentAnalyticsContext
        rpcQueue.async { [weak self] in
            guard let self else { return }
            if let analyticsContext {
                ProductAnalytics.submit { $0.recoveryAttempted(analyticsContext, phase: "analysis") }
            }
            let analysisStartedAt = DispatchTime.now().uptimeNanoseconds
            do {
                try self.ensureSidecarReady()
                try self.ensureRuntimeReady(requireASR: false, requireProvider: false, allowProviderProbeFailure: false)
                let result = try self.rpcClient.buildFinal(meetingID: meetingID)
                let analysisLatencyMS = Int((DispatchTime.now().uptimeNanoseconds - analysisStartedAt) / 1_000_000)
                let transcripts = try self.rpcClient.transcriptList(meetingID: meetingID, limit: 1200)
                DispatchQueue.main.async {
                    self.updateArtifactsSync(result: result, transcript: transcripts)
                    self.finishFinalInsightBuild()
                }
                if let analyticsContext {
                    ProductAnalytics.submit { analytics in
                        analytics.resolveWorkflow(
                            analyticsContext,
                            path: ProductAnalyticsPath(provider: result.provider),
                            analysisLatencyMilliseconds: analysisLatencyMS
                        )
                        analytics.recordSaved(analyticsContext)
                        analytics.reviewOpened(analyticsContext)
                        analytics.recoveryCompleted(analyticsContext, phase: "analysis", succeeded: true)
                    }
                }
            } catch {
                let analysisLatencyMS = Int((DispatchTime.now().uptimeNanoseconds - analysisStartedAt) / 1_000_000)
                if let analyticsContext {
                    ProductAnalytics.submit {
                        $0.workflowFailed(
                            analyticsContext,
                            phase: "analysis",
                            errorCode: "unknown",
                            recoveryAction: "retry",
                            analysisLatencyMilliseconds: analysisLatencyMS
                        )
                    }
                }
                DispatchQueue.main.async {
                    self.publishErrorSync(error)
                    self.finishFinalInsightBuild()
                }
            }
        }
    }

    func exportDocument(format: String = "markdown") {
        guard let meetingID = currentMeetingID else {
            let msg = "当前没有可导出的转写会话。"
            errorMessage = msg
            inlineError = InlineErrorState(message: msg, occurredAt: Date())
            return
        }

        let analyticsContext = currentAnalyticsContext
        let duration = Double(transcriptSegments.map(\.endMs).max() ?? 0) / 1_000
        let recordPath = recordsService?.recordFolderURL(for: meetingID)
        let hasBlockingError = errorMessage != nil
        if let analyticsContext {
            ProductAnalytics.submit { $0.exportAttempted(analyticsContext) }
        }
        rpcQueue.async { [weak self] in
            guard let self else { return }
            do {
                if let url = try RecordDocumentExporter.exportIfPersistedRecordExists(
                    format: format,
                    meetingID: meetingID,
                    recordsService: self.recordsService
                ) {
                    if let analyticsContext {
                        ProductAnalytics.submit { analytics in
                            analytics.exportCompleted(analyticsContext)
                            analytics.workflowCompleted(
                                analyticsContext,
                                evaluation: .evaluate(
                                    recordPath: recordPath,
                                    duration: duration,
                                    exportCompleted: true,
                                    hasBlockingError: hasBlockingError
                                )
                            )
                        }
                    }
                    DispatchQueue.main.async {
                        self.lastExportPath = url.path
                    }
                    return
                }
                try self.ensureSidecarReady()
                try self.ensureRuntimeReady(requireASR: false, requireProvider: false, allowProviderProbeFailure: false)
                let result = try self.rpcClient.documentExport(meetingID: meetingID, format: format, outputDir: "")
                if let analyticsContext {
                    ProductAnalytics.submit { analytics in
                        analytics.exportCompleted(analyticsContext)
                        analytics.workflowCompleted(
                            analyticsContext,
                            evaluation: .evaluate(
                                recordPath: recordPath,
                                duration: duration,
                                exportCompleted: true,
                                hasBlockingError: hasBlockingError
                            )
                        )
                    }
                }
                DispatchQueue.main.async {
                    self.lastExportPath = result.path
                }
            } catch {
                if let analyticsContext {
                    ProductAnalytics.submit {
                        $0.workflowFailed(
                            analyticsContext,
                            phase: "exporting",
                            errorCode: "unknown",
                            recoveryAction: "retry"
                        )
                    }
                }
                DispatchQueue.main.async { self.publishErrorSync(error) }
            }
        }
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

    func selectEvidence(_ range: EvidenceRange?) {
        selectedEvidence = range
    }

    func clearError() {
        errorMessage = nil
        inlineError = nil
    }

    func beginMonitoring() {
        pollFailureStreak = 0
        pollingMode = .idle
        pollIntervalSec = 10
        if pollTask == nil {
            startPolling()
        }
        refreshStatus()
    }

    func endMonitoring() {
        pollTask?.cancel()
        pollTask = nil
        sidecarReadyInSession = false
        pollingMode = .idle
    }

    /// Synchronous version called from rpcQueue – never on the cooperative thread pool.
    private func fetchStatusSync(isPolling: Bool) {
        // For polling path, beginFetchIfNeeded is checked here.
        // For refreshStatus path, it’s already checked before dispatch.
        if isPolling && !beginFetchIfNeeded() {
            return
        }
        defer { endFetch() }

        do {
            let allowRebootstrap = !isPolling || pollFailureStreak >= 3
            try ensureSidecarReady(allowRebootstrap: allowRebootstrap)
            let status = try rpcClient.transcriptionStatus(limit: 100)
            let sidecar = try? rpcClient.sidecarStatus()
            DispatchQueue.main.async {
                let hasActiveWork = self.applyStatusSync(status, sidecar: sidecar)
                self.markPollSuccessSync(hasActiveWork: hasActiveWork)
            }
        } catch {
            DispatchQueue.main.async {
                self.markPollFailureSync()
                self.publishErrorSync(error)
            }
        }
    }

    private func ensureSidecarReady(allowRebootstrap: Bool = true) throws {
        if !bootstrapSidecar {
            return
        }
        let ensureReadyProbe = { [weak self] in
            guard let self else { return }
            _ = try self.rpcClient.ensureReady(timeoutSec: 6)
        }

        if !sidecarReadyInSession {
            try sidecarManager.startIfNeeded(ensureReady: ensureReadyProbe)
            sidecarReadyInSession = true
        } else {
            _ = try rpcClient.ensureReady(timeoutSec: 2)
        }

        do {
            let version = try rpcClient.sidecarVersion()
            if let actions = version["capabilities"] as? [String],
               !actions.isEmpty,
               !actions.contains("transcription.status") {
                throw NSError(
                    domain: "InsightKit",
                    code: -5301,
                    userInfo: [NSLocalizedDescriptionKey: "当前侧车版本不支持转写总结流，请在设置执行“一键测试服务”并重启应用。"]
                )
            }
        } catch {
            // 兼容旧版 sidecar 不支持 sidecar.version 的情况。
            if error.localizedDescription.lowercased().contains("method not found: sidecar.version") {
                // no-op
            } else {
                throw error
            }
        }

        do {
            _ = try rpcClient.transcriptionStatus(limit: 1)
        } catch {
            if isMissingTranscriptionStatus(error), allowRebootstrap {
                try sidecarManager.rebootstrap(ensureReady: ensureReadyProbe)
                sidecarReadyInSession = true
                _ = try rpcClient.transcriptionStatus(limit: 1)
                return
            }
            throw error
        }
    }

    private func isMissingTranscriptionStatus(_ error: Error) -> Bool {
        error.localizedDescription.lowercased().contains("method not found: transcription.status")
    }

    private func ensureRuntimeReady(requireASR: Bool, requireProvider: Bool, allowProviderProbeFailure: Bool) throws {
        func restartAndRetry() throws {
            let ensureReadyProbe = { [weak self] in
                guard let self else { return }
                _ = try self.rpcClient.ensureReady(timeoutSec: 6)
            }
            try sidecarManager.rebootstrap(ensureReady: ensureReadyProbe)
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
            if !asr.ready {
                if AppConfigStore.shared.config.download.autoBootstrapEnabled {
                    _ = try rpcClient.asrRuntimeBootstrap(model: selectedModel, engine: selectedEngine)
                    let retried = try rpcClient.asrRuntimeStatus(engine: selectedEngine)
                    if retried.ready {
                        return
                    }
                }
                throw NSError(
                    domain: "InsightKit",
                    code: -5201,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "本地语音识别未就绪（\(selectedEngine.displayName) / \(asr.modelName)）。请在设置里执行“一键修复语音识别”。",
                    ]
                )
            }
        }
        if requireProvider {
            let configStore = AppConfigStore.shared
            if configStore.config.analysis.mode == .local {
                DispatchQueue.main.async { self.analysisRuntimeState = .ready }
                return
            }
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
                    publishProviderSoftFailure("智能分析探测超时，转写继续、洞察已暂停。")
                    return
                } else {
                    throw error
                }
            }
            if !providers.activeReady {
                DispatchQueue.main.async {
                    self.analysisRuntimeState = .missingConfig
                }
                throw NSError(
                    domain: "InsightKit",
                    code: -5202,
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
                    publishProviderSoftFailure("智能分析探测超时，转写继续、洞察已暂停。")
                    return
                } else {
                    throw error
                }
            }
            if !probe.ok {
                if allowProviderProbeFailure {
                    publishProviderSoftFailure("智能分析暂不可用，转写继续、洞察已暂停。")
                    DispatchQueue.main.async {
                        self.analysisRuntimeState = probe.code == .authFailed ? .pausedAuthFailed : .pausedTimeout
                    }
                    return
                }
                var msg = probe.message
                if !probe.hint.isEmpty {
                    msg += " \(probe.hint)"
                }
                throw NSError(
                    domain: "InsightKit",
                    code: -5203,
                    userInfo: [NSLocalizedDescriptionKey: msg]
                )
            }
            DispatchQueue.main.async {
                self.analysisRuntimeState = .ready
            }
        }
    }

    private func isProviderProbeTimeout(_ error: Error) -> Bool {
        let lower = error.localizedDescription.lowercased()
        return lower.contains("调用超时: analysis.provider.probe")
            || lower.contains("调用超时: analysis.providers.status")
            || lower.contains("probe_timeout")
    }

    func refreshProviderStateNonBlocking(
        analysisMode: AnalysisMode = AppConfigStore.shared.config.analysis.mode
    ) -> ProductAnalyticsPath {
        if analysisMode == .local {
            DispatchQueue.main.async {
                self.analysisRuntimeState = .ready
                self.inlineError = nil
            }
            return .local
        }
        do {
            let providers = try rpcClient.providersStatus(probeActive: false)
            if providers.activeReady {
                DispatchQueue.main.async {
                    self.analysisRuntimeState = .ready
                }
                return ProductAnalyticsPath(providers: providers)
            }
            DispatchQueue.main.async {
                self.analysisRuntimeState = .missingConfig
                self.inlineError = InlineErrorState(
                    message: "智能分析未配置，转写继续，定稿将使用本地提取草稿。",
                    occurredAt: Date()
                )
            }
            return .unavailable
        } catch {
            if isProviderProbeTimeout(error) {
                publishProviderSoftFailure("智能分析探测超时，转写继续、洞察已暂停。")
            }
            return .unavailable
        }
    }

    private func publishProviderSoftFailure(_ message: String) {
        DispatchQueue.main.async {
            self.inlineError = InlineErrorState(message: message, occurredAt: Date())
            if message.contains("超时") {
                self.analysisRuntimeState = .pausedTimeout
            }
        }
    }

    private func startPolling() {
        pollTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.rpcQueue.async {
                    self.fetchStatusSync(isPolling: true)
                }
                try? await Task.sleep(nanoseconds: self.pollIntervalSec * 1_000_000_000)
            }
        }
    }

    private func beginFetchIfNeeded() -> Bool {
        fetchLock.lock()
        defer { fetchLock.unlock() }
        if fetchInFlight {
            return false
        }
        fetchInFlight = true
        return true
    }

    private func endFetch() {
        fetchLock.lock()
        fetchInFlight = false
        fetchLock.unlock()
    }

    /// Called from DispatchQueue.main – no @MainActor needed.
    private func markPollSuccessSync(hasActiveWork: Bool) {
        pollFailureStreak = 0
        pollingMode = hasActiveWork ? .active : .idle
        pollIntervalSec = hasActiveWork ? 2 : 10
    }

    /// Called from DispatchQueue.main – no @MainActor needed.
    private func markPollFailureSync() {
        pollFailureStreak += 1
        if pollFailureStreak >= 4 {
            pollingMode = .degraded
            pollIntervalSec = 15
            return
        }
        pollingMode = .idle
        let ladder = [4, 8, 15]
        let idx = min(max(0, pollFailureStreak - 1), ladder.count - 1)
        pollIntervalSec = UInt64(ladder[idx])
    }

    /// Called from DispatchQueue.main – no @MainActor needed.
    private func applyStatusSync(_ status: TranscriptionStatusResult, sidecar: [String: Any]?) -> Bool {
        jobs = status.jobs
        watcherState = status.watcher
        watcherState.queueSize = status.queue.count
        watcherState.activeJobID = status.activeJob?.id

        var observedJobs = status.jobs
        if let active = status.activeJob, !observedJobs.contains(where: { $0.id == active.id }) {
            observedJobs.append(active)
        }
        if let completed = status.lastCompleted?.job, !observedJobs.contains(where: { $0.id == completed.id }) {
            observedJobs.append(completed)
        }
        for job in observedJobs where analyticsContextsByJobID[job.id] == nil {
            let isActive = job.state == .queued || job.state == .running
            let isCurrentWatcherJob = watcherAnalyticsStartedAt.map { watcherStartedAt in
                job.startedAt.map { $0 >= watcherStartedAt } ?? true
            } ?? false
            if isActive || isCurrentWatcherJob {
                let context = ProductAnalyticsAttemptContext(workflow: "import")
                analyticsContextsByJobID[job.id] = context
                let provisionalPath = watcherAnalyticsPath
                ProductAnalytics.submit { $0.beginWorkflow(context, provisionalPath: provisionalPath) }
            }
        }
        for job in observedJobs where !analyticsTerminalJobIDs.contains(job.id) {
            guard let context = analyticsContextsByJobID[job.id] else { continue }
            switch job.state {
            case .failed:
                analyticsTerminalJobIDs.insert(job.id)
                ProductAnalytics.submit {
                    $0.workflowFailed(
                        context,
                        phase: "running",
                        errorCode: "runtime-unavailable",
                        recoveryAction: "retry"
                    )
                }
            case .cancelled, .pausedByLive:
                analyticsTerminalJobIDs.insert(job.id)
                ProductAnalytics.submit { $0.workflowCancelled(context) }
            default:
                break
            }
        }

        if let sidecar {
            let running = (sidecar["running"] as? Bool) ?? false
            let pid = (sidecar["pid"] as? Int) ?? 0
            let socketPath = (sidecar["socket_path"] as? String) ?? ""
            let uptime = (sidecar["uptime_sec"] as? Int) ?? 0
            let ready = (sidecar["ready"] as? Bool) ?? running
            let pyVersion = (sidecar["python_version"] as? String) ?? ""
            sidecarHealth = SidecarHealth(
                running: running,
                pid: pid == 0 ? nil : pid,
                socketPath: socketPath,
                uptimeSec: uptime,
                isReady: ready,
                lastErrorCode: (sidecar["last_error_code"] as? String) ?? "",
                lastLatencyMs: (sidecar["last_latency_ms"] as? Int) ?? 0
            )
            sidecarSnapshot = SidecarHealthSnapshot(
                lastErrorCode: (sidecar["last_error_code"] as? String) ?? "",
                lastLatencyMs: (sidecar["last_latency_ms"] as? Int) ?? 0
            )
            if running {
                sidecarLabel = pyVersion.isEmpty
                    ? "sidecar: running (pid \(pid))"
                    : "sidecar: running (pid \(pid), py \(pyVersion))"
            } else {
                sidecarLabel = "sidecar: down"
            }
        }

        let newCompletion = status.lastCompleted.flatMap {
            knownCompletedJobIDs.contains($0.job.id) ? nil : $0
        }
        let selectedJob = newCompletion?.job
            ?? currentMeetingID.flatMap { meetingID in observedJobs.first { $0.meetingID == meetingID } }
            ?? status.activeJob
            ?? status.lastCompleted?.job
        if let selectedJob {
            currentMeetingID = selectedJob.meetingID
            currentAnalyticsContext = analyticsContextsByJobID[selectedJob.id]
        }
        if let lastCompleted = status.lastCompleted {
            if newCompletion != nil {
                knownCompletedJobIDs.insert(lastCompleted.job.id)
                metrics.lastRefreshAt = lastCompleted.updatedAt
                currentMeetingID = lastCompleted.meetingID
                loadArtifactsForMeeting(
                    lastCompleted.meetingID,
                    analyticsContext: analyticsContextsByJobID[lastCompleted.job.id]
                )
            }
        }

        if let active = status.activeJob {
            metrics.chunkIndex = max(metrics.chunkIndex, 0)
            metrics.latencyMs = max(metrics.latencyMs, 0)
            metrics.provider = ""
            metrics.needsReviewCount = 0
            metrics.segmentsIngested = active.progress
        }

        let hasActiveWork = watcherState.isRunning || jobs.contains(where: { $0.state == .running || $0.state == .queued })
        if retireWatcherAnalyticsAfterRefresh, !watcherState.isRunning {
            watcherAnalyticsStartedAt = nil
            retireWatcherAnalyticsAfterRefresh = false
        }
        return hasActiveWork
    }

    func loadArtifactsForMeeting(
        _ meetingID: String,
        analyticsContext: ProductAnalyticsAttemptContext? = nil
    ) {
        if isBuildingFinalInsight {
            if buildingFinalMeetingID != meetingID, !pendingArtifactMeetingIDs.contains(meetingID) {
                pendingArtifactMeetingIDs.append(meetingID)
            }
            return
        }
        isBuildingFinalInsight = true
        buildingFinalMeetingID = meetingID
        beginSidecarMutation()
        rpcQueue.async { [weak self] in
            guard let self else { return }
            if let analyticsContext {
                ProductAnalytics.submit { $0.recoveryAttempted(analyticsContext, phase: "analysis") }
            }
            let analysisStartedAt = DispatchTime.now().uptimeNanoseconds
            do {
                try self.ensureSidecarReady()
                let result = try self.rpcClient.buildFinal(meetingID: meetingID)
                let analysisLatencyMS = Int((DispatchTime.now().uptimeNanoseconds - analysisStartedAt) / 1_000_000)
                let transcript = try self.rpcClient.transcriptList(meetingID: meetingID, limit: 1200)
                DispatchQueue.main.async {
                    self.updateArtifactsSync(result: result, transcript: transcript)
                    self.finishFinalInsightBuild()
                }
                if let analyticsContext {
                    ProductAnalytics.submit { analytics in
                        analytics.resolveWorkflow(
                            analyticsContext,
                            path: ProductAnalyticsPath(provider: result.provider),
                            analysisLatencyMilliseconds: analysisLatencyMS
                        )
                        analytics.recordSaved(analyticsContext)
                        analytics.reviewOpened(analyticsContext)
                        analytics.recoveryCompleted(analyticsContext, phase: "analysis", succeeded: true)
                    }
                }
            } catch {
                let analysisLatencyMS = Int((DispatchTime.now().uptimeNanoseconds - analysisStartedAt) / 1_000_000)
                if let analyticsContext {
                    ProductAnalytics.submit {
                        $0.workflowFailed(
                            analyticsContext,
                            phase: "analysis",
                            errorCode: "unknown",
                            recoveryAction: "retry",
                            analysisLatencyMilliseconds: analysisLatencyMS
                        )
                    }
                }
                DispatchQueue.main.async {
                    self.publishErrorSync(error)
                    self.finishFinalInsightBuild()
                }
            }
        }
    }

    private func beginSidecarMutation() {
        pendingSidecarMutationCount += 1
        hasPendingSidecarMutation = true
    }

    private func endSidecarMutation() {
        pendingSidecarMutationCount = max(0, pendingSidecarMutationCount - 1)
        hasPendingSidecarMutation = pendingSidecarMutationCount > 0
    }

    private func finishFinalInsightBuild() {
        let nextMeetingID = pendingArtifactMeetingIDs.isEmpty ? nil : pendingArtifactMeetingIDs.removeFirst()
        isBuildingFinalInsight = false
        buildingFinalMeetingID = nil
        if let nextMeetingID {
            loadArtifactsForMeeting(nextMeetingID)
        }
        endSidecarMutation()
    }

    /// Called from DispatchQueue.main – no @MainActor needed.
    private func updateArtifactsSync(result: InsightRefreshResult, transcript: [TranscriptSegment]) {
        updateWorkbenchSync(result)
        transcriptSegments = transcript.sorted(by: { $0.startMs < $1.startMs })
        metrics.provider = result.provider
        metrics.needsReviewCount = result.needsReviewCount
        metrics.lastRefreshAt = result.updatedAt ?? Date()
        metrics.segmentsIngested = transcript.count
    }

    /// Called from DispatchQueue.main – no @MainActor needed.
    private func publishErrorSync(_ error: Error) {
        let raw = error.localizedDescription
        let lower = raw.lowercased()
        let message: String
        if lower.contains("method not found")
            || lower.contains("circuit-open")
            || lower.contains("sidecar.ensure_ready") {
            message = "本地服务版本或状态异常，请打开设置执行“一键测试服务”并重启应用。"
        } else if lower.contains("traceback") {
            message = "转写服务执行失败，请稍后重试；若持续失败，请在设置执行“一键修复语音识别”。"
        } else {
            message = raw
        }
        errorMessage = message

        let now = Date()
        if lastInlineErrorMessage == message, let lastAt = lastInlineErrorAt, now.timeIntervalSince(lastAt) < 10 {
            return
        }
        inlineError = InlineErrorState(message: message, occurredAt: now)
        lastInlineErrorMessage = message
        lastInlineErrorAt = now
    }

    /// Called from DispatchQueue.main – no @MainActor needed.
    private func updateWorkbenchSync(_ result: InsightRefreshResult) {
        let package = result.package
        workbench = InsightWorkbenchState(
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

        actionItems = package.actionTracks.map {
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
}
