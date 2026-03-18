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

    private let capabilityClient: InsightRPCClientProtocol
    private var capabilities: Set<String> = []
    private var cancellables: Set<AnyCancellable> = []
    /// Dedicated GCD queue for blocking RPC I/O.
    private let rpcQueue = DispatchQueue(label: "InsightKit.WorkflowCoordinator.RPC", qos: .userInitiated)

    init(
        liveViewModel: LiveSessionViewModel = LiveSessionViewModel(),
        transcriptionViewModel: TranscriptionSessionViewModel = TranscriptionSessionViewModel(autoRefresh: false, autoPolling: false),
        importViewModel: ImportSessionViewModel = ImportSessionViewModel(),
        recordsService: RecordsIndexService = RecordsIndexService(),
        capabilityClient: InsightRPCClientProtocol = InsightRPCClient()
    ) {
        self.liveViewModel = liveViewModel
        self.transcriptionViewModel = transcriptionViewModel
        self.importViewModel = importViewModel
        self.recordsService = recordsService
        self.capabilityClient = capabilityClient
        // Phase 5: inject recordsService into child ViewModels
        liveViewModel.recordsService = recordsService
        importViewModel.recordsService = recordsService
        bridgeChildObjectChanges()
        bindStates()
        refreshSidecarCapabilities()
    }

    var canStartLive: Bool {
        liveViewModel.canStartSession && livePhase == .livePreparing && supportsLiveActions
    }

    var canStopLive: Bool {
        liveViewModel.canStopSession && supports("session.stop")
    }

    var canBuildLiveFinal: Bool {
        liveViewModel.canBuildFinal && livePhase == .livePostSession && supports("insight.build_final")
    }

    var canBuildTranscriptionFinal: Bool {
        transcriptionViewModel.canBuildFinal && transcriptionPhase == .transcriptionFinalize && supports("insight.build_final")
    }

    var canExportLive: Bool {
        liveViewModel.canExportDocument && supports("document.export")
    }

    var canExportTranscription: Bool {
        transcriptionViewModel.canExportDocument && supports("document.export")
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
        if liveViewModel.sessionHandle.lastMeetingID != nil {
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

    func openHome() {
        transcriptionViewModel.endMonitoring()
        route = .home
        appState.activeRoute = .home
        clearBanner()
    }

    func openLive() {
        transcriptionViewModel.endMonitoring()
        liveViewModel.prepareForLiveEntry()
        route = .live
        appState.activeRoute = .live
        refreshSidecarCapabilities()
    }

    func openImport() {
        route = .importMedia
        appState.activeRoute = .importMedia
        refreshSidecarCapabilities()
    }

    func openRecords() {
        route = .records
        appState.activeRoute = .records
    }

    func openTranscription() {
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

    func resetLiveSession() {
        liveViewModel.resetForNewSession()
        appState.preemptionState = .idle
    }

    func refreshSidecarCapabilities() {
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

    func performBannerAction() {
        guard let bannerMessage else { return }
        switch bannerMessage.actionRoute {
        case "open_settings":
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
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
    }

    private var supportsLiveActions: Bool {
        supports("session.start")
            && supports("session.stop")
            && supports("asr.transcribe_chunk")
            && supports("insight.refresh_live")
    }

    private func supports(_ method: String) -> Bool {
        capabilities.isEmpty || capabilities.contains(method)
    }

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
}
