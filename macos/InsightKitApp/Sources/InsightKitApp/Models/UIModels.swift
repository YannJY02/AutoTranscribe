import Foundation

enum WorkflowRoute: String, CaseIterable, Identifiable {
    case home = "首页"
    case live = "实时语音总结"
    case transcription = "转写总结"
    case importMedia = "导入转写"
    case records = "转写记录"

    var id: String { rawValue }
}

enum BottomPanelMode: String, CaseIterable, Identifiable {
    case collapsed = "collapsed"
    case expandedDebug = "expanded_debug"

    var id: String { rawValue }
}

enum WorkspacePhase: String, Equatable {
    case livePreparing = "准备中"
    case liveRunning = "进行中"
    case livePostSession = "会后定稿"
    case transcriptionIntake = "导入/监听"
    case transcriptionProcessing = "处理中"
    case transcriptionFinalize = "定稿/导出"

    var route: WorkflowRoute {
        switch self {
        case .livePreparing, .liveRunning, .livePostSession:
            return .live
        case .transcriptionIntake, .transcriptionProcessing, .transcriptionFinalize:
            return .transcription
        }
    }
}

enum BannerLevel: String, Equatable {
    case info
    case warning
    case error
}

struct BannerMessage: Equatable, Identifiable {
    let id = UUID()
    var level: BannerLevel
    var title: String
    var message: String
    var actionTitle: String = ""
    var actionRoute: String = ""
}

enum PreemptionState: Equatable {
    case idle
    case preempting(jobID: String?)
    case liveActive
}

struct AppCoordinatorState: Equatable {
    var activeRoute: WorkflowRoute = .home
    var liveState: CaptureState = .idle
    var transcriptionState: TranscriptionJobState? = nil
    var preemptionState: PreemptionState = .idle
}

struct DocumentExportResult {
    let path: String
    let format: String
}

struct BottomStatusPayload {
    var routeTitle: String = ""
    var stateLabel: String = ""
    var phaseLabel: String = ""
    var lastRefreshAt: Date?
    var meetingID: String = ""
    var actions: [BottomStatusAction] = [.settings]

    var developer = BottomDebugPayload()
}

struct BottomStatusAction: Equatable, Identifiable {
    var id: String { route }
    var title: String
    var systemImage: String
    var accessibilityID: String
    var route: String

    static let settings = BottomStatusAction(
        title: "设置",
        systemImage: "gearshape",
        accessibilityID: "bottom_status_open_settings",
        route: "open_settings"
    )
}

struct BottomDebugPayload: Equatable {
    var sidecarLabel: String = ""
    var ready: Bool = false
    var chunkIndex: Int = 0
    var segmentsIngested: Int = 0
    var latencyMs: Int = 0
    var queueDepth: Int = 0
    var droppedChunks: Int = 0
    var warmReadyMs: Int = 0
    var firstSegmentMs: Int = 0
    var provider: String = ""
    var needsReviewCount: Int = 0
    var analysisState: String = ""
    var warmState: String = ""
    var warmAttempt: Int = 0
    var warmError: String = ""
    var backendDevice: String = ""
    var backendComputeType: String = ""
    var backendResolved: String = ""
    var lastChunkAt: Date?
    var lastTranscriptAt: Date?
    var inputLevelMic: Float = 0
    var inputLevelSystem: Float = 0
}

struct InlineErrorState: Equatable {
    let message: String
    let occurredAt: Date
}

enum DiagnosticCheckStatus: String, Codable, Equatable {
    case pass
    case warn
    case fail
}

struct DiagnosticCheck: Equatable, Identifiable {
    let id: String
    let title: String
    let status: DiagnosticCheckStatus
    let actionHint: String
    let details: String
    let timedOut: Bool
}

struct DiagnosticReport: Equatable {
    let overall: DiagnosticCheckStatus
    let checks: [DiagnosticCheck]
}
