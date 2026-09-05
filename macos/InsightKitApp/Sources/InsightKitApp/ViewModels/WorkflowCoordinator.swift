import AppKit
import Combine
import Foundation

final class WorkflowCoordinator: ObservableObject {
    @Published var route: WorkflowRoute = .home
    @Published var bottomPanelMode: BottomPanelMode = .collapsed
    @Published var appState = AppCoordinatorState()
    @Published var bannerMessage: BannerMessage?

    var liveViewModel: LiveSessionViewModel
    var transcriptionViewModel: TranscriptionSessionViewModel
    var importViewModel: ImportSessionViewModel
    var recordsService: RecordsIndexService
    var recordsNavigation: RecordsWorkspaceNavigation

    private let capabilityClient: InsightRPCClientProtocol
    private let settingsOpener: () -> Void
    private var capabilities: Set<String> = []
    private var cancellables: Set<AnyCancellable> = []
    private var didShutdown = false
    private var telemetryLiveStartedAt: TimeInterval?
    /// Dedicated GCD queue for blocking RPC I/O.
    private let rpcQueue = DispatchQueue(label: "InsightKit.WorkflowCoordinator.RPC", qos: .userInitiated)

    init(
        liveViewModel: LiveSessionViewModel = LiveSessionViewModel(),
        transcriptionViewModel: TranscriptionSessionViewModel = TranscriptionSessionViewModel(autoRefresh: false, autoPolling: false),
        importViewModel: ImportSessionViewModel = ImportSessionViewModel(),
        recordsService: RecordsIndexService = RecordsIndexService(),
        recordsNavigation: RecordsWorkspaceNavigation = RecordsWorkspaceNavigation(),
        capabilityClient: InsightRPCClientProtocol = InsightRPCClient(),
        settingsOpener: @escaping () -> Void = {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    ) {
        self.liveViewModel = liveViewModel
        self.transcriptionViewModel = transcriptionViewModel
        self.importViewModel = importViewModel
        self.recordsService = recordsService
        self.recordsNavigation = recordsNavigation
        self.capabilityClient = capabilityClient
        self.settingsOpener = settingsOpener
        if UITestLaunchOptions.isEnabled,
           ProcessInfo.processInfo.environment["INSIGHTKIT_UI_TEST_SEED_RECORDS"] != "0" {
            // RecordsIndexService resolves the run's isolated root without
            // persisting it as the operator's chosen Records directory.
            recordsService.prepareUITestSeed(recordID: "record-restart-proof")
        }
        // Phase 5: inject recordsService into child ViewModels
        liveViewModel.recordsService = recordsService
        transcriptionViewModel.recordsService = recordsService
        importViewModel.recordsService = recordsService
        bridgeChildObjectChanges()
        bindStates()
        refreshSidecarCapabilities()
        applyUITestRouteIfNeeded()
    }

    var canStartLive: Bool {
        liveViewModel.canStartSession && livePhase == .livePreparing && supportsLiveActions
    }

    var canStopLive: Bool {
        liveViewModel.canStopSession && supports("session.stop")
    }

    var canBuildLiveFinal: Bool {
        liveViewModel.canBuildFinal
            && livePhase == .livePostSession
            && supports("insight.build_final")
            && supports("asr.transcribe_media")
            && supports("transcript.replace")
    }

    var canBuildTranscriptionFinal: Bool {
        transcriptionViewModel.canBuildFinal && transcriptionPhase == .transcriptionFinalize && supports("insight.build_final")
    }

    var canExportLive: Bool {
        liveViewModel.canExportDocument && (liveViewModel.hasPersistedRecordForExport || supports("document.export"))
    }

    var canExportTranscription: Bool {
        transcriptionViewModel.canExportDocument && (transcriptionViewModel.hasPersistedRecordForExport || supports("document.export"))
    }

    var hasActiveSidecarWork: Bool {
        liveViewModel.isRunning
            || liveViewModel.isFinalizingRecording
            || liveViewModel.captureState == .refreshing
            || liveViewModel.sessionHandle.activeMeetingID != nil
            || importViewModel.sessionPhase == .processing
            || transcriptionViewModel.hasPendingSidecarMutation
            || transcriptionViewModel.watcherState.isRunning
            || transcriptionViewModel.jobs.contains(where: { $0.state == .running || $0.state == .queued })
    }

    var supportsSystemAudioPicker: Bool {
        supportsLiveActions
    }

    var supportsTranscriptionFlow: Bool {
        supports("transcription.status")
            && supports("transcription.import_file")
    }

    var livePhase: WorkspacePhase {
        if liveViewModel.isRunning {
            return .liveRunning
        }
        if liveViewModel.sessionHandle.activeMeetingID != nil || liveViewModel.sessionHandle.lastMeetingID != nil {
            return .livePostSession
        }
        return .livePreparing
    }

    var transcriptionPhase: WorkspacePhase {
        if transcriptionViewModel.jobs.contains(where: { $0.state == .running || $0.state == .queued }) {
            return .transcriptionProcessing
        }
        if transcriptionViewModel.currentMeetingID != nil {
            return .transcriptionFinalize
        }
        return .transcriptionIntake
    }

    var currentPhaseLabel: String {
        switch route {
        case .home, .records:
            return ""
        case .live:
            return livePhase.rawValue
        case .transcription, .importMedia:
            return transcriptionPhase.rawValue
        }
    }

    var bottomStatusPayload: BottomStatusPayload {
        switch route {
        case .home, .records:
            return BottomStatusPayload(routeTitle: route.rawValue, stateLabel: "待命")
        case .live:
            return BottomStatusPayload(
                routeTitle: "实时语音总结",
                stateLabel: liveViewModel.captureState.label,
                phaseLabel: livePhase.rawValue,
                lastRefreshAt: liveViewModel.metrics.lastRefreshAt,
                meetingID: liveViewModel.sessionHandle.buildTargetID ?? "",
                developer: BottomDebugPayload(
                    sidecarLabel: liveViewModel.sidecarLabel,
                    ready: liveViewModel.sidecarHealth.isReady,
                    chunkIndex: liveViewModel.metrics.chunkIndex,
                    segmentsIngested: liveViewModel.metrics.segmentsIngested,
                    latencyMs: liveViewModel.metrics.latencyMs,
                    queueDepth: liveViewModel.metrics.queueDepth,
                    droppedChunks: liveViewModel.metrics.droppedChunks,
                    warmReadyMs: liveViewModel.metrics.warmReadyMs,
                    firstSegmentMs: liveViewModel.metrics.firstSegmentMs,
                    provider: liveViewModel.metrics.provider,
                    needsReviewCount: liveViewModel.metrics.needsReviewCount,
                    analysisState: liveViewModel.analysisRuntimeState.userLabel,
                    warmState: liveViewModel.asrWarmStatus.state.rawValue,
                    warmAttempt: liveViewModel.asrWarmStatus.attempt,
                    warmError: liveViewModel.asrWarmStatus.lastError,
                    backendDevice: liveViewModel.asrBackendStatus.configuredDevice,
                    backendComputeType: liveViewModel.asrBackendStatus.configuredComputeType,
                    backendResolved: liveViewModel.asrBackendStatus.resolved,
                    lastChunkAt: liveViewModel.captureHealth.lastChunkAt,
                    lastTranscriptAt: liveViewModel.captureHealth.lastTranscriptAt,
                    inputLevelMic: liveViewModel.captureHealth.inputLevelMic,
                    inputLevelSystem: liveViewModel.captureHealth.inputLevelSystem
                )
            )
        case .transcription, .importMedia:
            let currentJobState = displayState(transcriptionViewModel.activeJob?.state)
            return BottomStatusPayload(
                routeTitle: "转写总结",
                stateLabel: currentJobState,
                phaseLabel: transcriptionPhase.rawValue,
                lastRefreshAt: transcriptionViewModel.metrics.lastRefreshAt,
                meetingID: transcriptionViewModel.currentMeetingID ?? "",
                developer: BottomDebugPayload(
                    sidecarLabel: transcriptionViewModel.sidecarLabel,
                    ready: transcriptionViewModel.sidecarHealth.isReady,
                    chunkIndex: 0,
                    segmentsIngested: transcriptionViewModel.metrics.segmentsIngested,
                    latencyMs: transcriptionViewModel.metrics.latencyMs,
                    queueDepth: 0,
                    droppedChunks: 0,
                    warmReadyMs: 0,
                    firstSegmentMs: 0,
                    provider: transcriptionViewModel.metrics.provider,
                    needsReviewCount: transcriptionViewModel.metrics.needsReviewCount,
                    analysisState: transcriptionViewModel.analysisRuntimeState.userLabel,
                    warmState: "",
                    warmAttempt: 0,
                    warmError: "",
                    backendDevice: "",
                    backendComputeType: "",
                    backendResolved: "",
                    lastChunkAt: nil,
                    lastTranscriptAt: nil,
                    inputLevelMic: 0,
                    inputLevelSystem: 0
                )
            )
        }
    }

    var primaryNavigationAction: WorkflowPrimaryNavigationAction {
        switch route {
        case .home:
            return .none
        case .records where recordsNavigation.isReviewingRecord:
            return .recordsList
        case .live, .transcription, .importMedia, .records:
            return .home
        }
    }

    func performPrimaryNavigationAction() {
        switch primaryNavigationAction {
        case .none:
            break
        case .home:
            openHome()
        case .recordsList:
            recordsNavigation.closeReview()
        }
    }

    func openHome() {
        transcriptionViewModel.endMonitoring()
        recordsNavigation.closeReview()
        route = .home
        appState.activeRoute = .home
        clearBanner()
    }

    func openLive() {
        transcriptionViewModel.endMonitoring()
        recordsNavigation.closeReview()
        liveViewModel.prepareForLiveEntry()
        route = .live
        appState.activeRoute = .live
        refreshSidecarCapabilities()
    }

    func openImport() {
        recordsNavigation.closeReview()
        route = .importMedia
        appState.activeRoute = .importMedia
        refreshSidecarCapabilities()
    }

    func openRecords() {
        recordsNavigation.closeReview()
        route = .records
        appState.activeRoute = .records
    }

    func openTranscription() {
        recordsNavigation.closeReview()
        route = .transcription
        appState.activeRoute = .transcription
        refreshSidecarCapabilities()
        if supportsTranscriptionFlow {
            transcriptionViewModel.beginMonitoring()
            clearBanner()
        } else {
            transcriptionViewModel.endMonitoring()
            publishCapabilityBanner(
                title: "当前侧车版本不支持转写流",
                message: "请在设置中执行“一键测试服务”，并重启后重试。",
                actionTitle: "打开设置",
                actionRoute: "open_settings"
            )
        }
    }

    func openSettings() {
        settingsOpener()
    }

    func handleIncomingURL(_ url: URL) {
        guard let action = AppURLHandler.action(from: url) else {
            publishCapabilityBanner(
                title: "无法处理 InsightKit 链接",
                message: "请确认链接格式为 insightkit://import?path=<本地音视频文件路径>。",
                actionTitle: "刷新能力",
                actionRoute: "refresh_capabilities"
            )
            return
        }

        switch action {
        case .importFile(let url):
            importFileFromExternalURL(url)
        }
    }

    private func importFileFromExternalURL(_ fileURL: URL) {
        switch SupportedMediaTypes.validateLocalMediaFileURL(from: fileURL.path) {
        case .success(let url):
            openImport()
            importViewModel.importFile(url: url)
            clearBanner()
        case .failure(let error):
            openImport()
            publishCapabilityBanner(
                title: "无法导入链接文件",
                message: error.userMessage,
                actionTitle: "刷新能力",
                actionRoute: "refresh_capabilities"
            )
        }
    }

    func startLiveSession() {
        refreshSidecarCapabilities()
        guard supportsLiveActions else {
            publishCapabilityBanner(
                title: "当前侧车版本不支持实时语音总结",
                message: "缺少实时链路能力，请在设置中执行“一键测试服务”后重试。",
                actionTitle: "打开设置",
                actionRoute: "open_settings"
            )
            return
        }
        let preemptedID = transcriptionViewModel.activeJob?.id
        appState.preemptionState = .preempting(jobID: preemptedID)
        transcriptionViewModel.preemptForLive()
        transcriptionViewModel.endMonitoring()
        if route != .live {
            liveViewModel.prepareForLiveEntry()
        }
        route = .live
        appState.activeRoute = .live
        liveViewModel.startLiveSession()
        appState.preemptionState = .liveActive
        clearBanner()
    }

    func stopLiveSession() {
        liveViewModel.stopLiveSession()
        appState.preemptionState = .idle
    }

    @discardableResult
    func resetLiveSession() -> Bool {
        guard liveViewModel.resetForNewSession() else { return false }
        appState.preemptionState = .idle
        return true
    }

    func shutdown() {
        guard !didShutdown else { return }
        didShutdown = true
        liveViewModel.shutdown()
        transcriptionViewModel.shutdown()
        importViewModel.shutdown()
    }

    func refreshSidecarCapabilities() {
        if UITestLaunchOptions.isEnabled {
            capabilities = Self.uiTestCapabilities
            return
        }

        rpcQueue.async { [weak self] in
            guard let self else { return }
            do {
                let version = try self.capabilityClient.sidecarVersion()
                let actions = (version["capabilities"] as? [String]) ?? []
                let set = Set(actions)
                DispatchQueue.main.async {
                    self.capabilities = set
                }
            } catch {
                // 能力未知时保守降级，仅保留已可确认的最小动作。
                DispatchQueue.main.async {
                    self.capabilities = []
                }
            }
        }
    }

    func performBannerAction(for actionRoute: String? = nil) {
        let route = actionRoute ?? bannerMessage?.actionRoute ?? ""
        switch route {
        case "open_settings":
            openSettings()
        case "open_mic":
            liveViewModel.openMicrophonePrivacySettings()
        case "open_screen":
            liveViewModel.openScreenRecordingSettings()
        case "refresh_capabilities":
            refreshSidecarCapabilities()
        default:
            break
        }
    }

    func publishInfoBanner(_ message: String) {
        bannerMessage = BannerMessage(level: .info, title: "提示", message: message)
    }

    func clearBanner() {
        bannerMessage = nil
    }

    private func bindStates() {
        liveViewModel.$captureState
            .sink { [weak self] state in
                self?.appState.liveState = state
                guard let self else { return }
                switch state {
                case .capturing where telemetryLiveStartedAt == nil:
                    telemetryLiveStartedAt = ProcessInfo.processInfo.systemUptime
                case .idle:
                    if let started = telemetryLiveStartedAt {
                        SentryDiagnosticsRuntime.shared.capturePerformance(
                            workflow: .live,
                            phase: .running,
                            milliseconds: max(0, Int((ProcessInfo.processInfo.systemUptime - started) * 1_000))
                        )
                        telemetryLiveStartedAt = nil
                    }
                case .error:
                    telemetryLiveStartedAt = nil
                default:
                    break
                }
            }
            .store(in: &cancellables)

        transcriptionViewModel.$jobs
            .sink { [weak self] jobs in
                self?.appState.transcriptionState = jobs.first(where: { $0.state == .running })?.state
            }
            .store(in: &cancellables)
    }

    private func bridgeChildObjectChanges() {
        liveViewModel.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        transcriptionViewModel.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        importViewModel.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        recordsService.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        recordsNavigation.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    private var supportsLiveActions: Bool {
        supports("session.start")
            && supports("session.stop")
            && supports("asr.transcribe_chunk")
            && supports("asr.transcribe_media")
            && supports("transcript.replace")
            && supports("insight.refresh_live")
    }

    private func supports(_ method: String) -> Bool {
        capabilities.isEmpty || capabilities.contains(method)
    }

    private static let uiTestCapabilities: Set<String> = [
        "session.start",
        "session.stop",
        "asr.transcribe_chunk",
        "asr.transcribe_media",
        "transcript.replace",
        "insight.refresh_live",
        "insight.build_final",
        "document.export",
        "transcription.status",
        "transcription.import_file",
    ]

    private func publishCapabilityBanner(title: String, message: String, actionTitle: String, actionRoute: String) {
        bannerMessage = BannerMessage(
            level: .warning,
            title: title,
            message: message,
            actionTitle: actionTitle,
            actionRoute: actionRoute
        )
    }

    private func displayState(_ state: TranscriptionJobState?) -> String {
        switch state {
        case .queued:
            return "排队中"
        case .running:
            return "处理中"
        case .completed:
            return "已完成"
        case .failed:
            return "失败"
        case .pausedByLive:
            return "已暂停（实时优先）"
        case .cancelled:
            return "已取消"
        case .none:
            return "待机"
        }
    }

    private func applyUITestRouteIfNeeded() {
        switch UITestLaunchOptions.routeOverride {
        case "live":
            liveViewModel.prepareForLiveEntry()
            route = .live
            appState.activeRoute = .live
        case "transcription":
            route = .transcription
            appState.activeRoute = .transcription
        case "import":
            route = .importMedia
            appState.activeRoute = .importMedia
        case "records":
            route = .records
            appState.activeRoute = .records
        default:
            break
        }
    }
}
