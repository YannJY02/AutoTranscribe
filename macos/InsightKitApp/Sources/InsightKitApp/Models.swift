import Foundation

struct TranscriptSegment: Identifiable, Hashable {
    let id = UUID()
    let startMs: Int
    let endMs: Int
    let speaker: String
    let source: String
    let text: String

    var timeLabel: String {
        let seconds = max(0, startMs / 1000)
        let min = seconds / 60
        let sec = seconds % 60
        return String(format: "%02d:%02d", min, sec)
    }

    func overlaps(_ range: EvidenceRange?) -> Bool {
        guard let range else { return false }
        return !(endMs < range.startMs || startMs > range.endMs)
    }
}

struct EvidenceRange: Hashable, Codable {
    let startMs: Int
    let endMs: Int

    var label: String {
        "\(timeLabel(from: startMs))-\(timeLabel(from: endMs))"
    }

    private func timeLabel(from ms: Int) -> String {
        let sec = max(0, ms / 1000)
        return String(format: "%02d:%02d", sec / 60, sec % 60)
    }
}

struct WorkbenchItem: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let body: String
    let meta: String
    let evidence: EvidenceRange?
}

struct ActionItem: Identifiable, Hashable {
    let id = UUID()
    var task: String
    var owner: String
    var status: String
    var dueAt: String
    var priority: String
    var needsReview: Bool
    var evidence: EvidenceRange?
}

struct InsightWorkbenchState {
    var sessionOverview: String
    var highlightInsights: [WorkbenchItem]
    var speakerPerspectives: [WorkbenchItem]
    var decisionLedger: [WorkbenchItem]
    var actionTracks: [WorkbenchItem]
    var timelineBeats: [WorkbenchItem]

    static let empty = InsightWorkbenchState(
        sessionOverview: "尚未生成洞察内容。",
        highlightInsights: [],
        speakerPerspectives: [],
        decisionLedger: [],
        actionTracks: [],
        timelineBeats: []
    )
}

enum InsightTab: String, CaseIterable, Identifiable {
    case sessionOverview = "会话总览"
    case highlightInsights = "高光洞察"
    case speakerMap = "观点图谱"
    case decisionLedger = "决策账本"
    case actionTracks = "执行清单"
    case timelineBeats = "时间脉络"

    var id: String { rawValue }
}

enum AudioInputMode: String, CaseIterable, Identifiable {
    case microphone = "麦克风"
    case systemAudio = "系统音频"
    case mixed = "混音"

    var id: String { rawValue }

    var requiresSystemAudioSource: Bool {
        switch self {
        case .microphone:
            return false
        case .systemAudio, .mixed:
            return true
        }
    }
}

enum CaptureState: Equatable {
    case idle
    case preparingRuntime
    case warmingModel
    case capturing
    case transcribing
    case refreshing
    case recoveringPermission
    case error(String)

    var label: String {
        switch self {
        case .idle:
            return "待机"
        case .preparingRuntime:
            return "准备运行时"
        case .warmingModel:
            return "预热模型"
        case .capturing:
            return "可转写"
        case .transcribing:
            return "转写中"
        case .refreshing:
            return "刷新洞察"
        case .recoveringPermission:
            return "等待权限恢复"
        case .error(let message):
            return "错误: \(message)"
        }
    }
}

enum PermissionState: Equatable {
    case unknown
    case granted
    case denied
}

enum WorkflowRoute: String, CaseIterable, Identifiable {
    case home = "首页"
    case live = "实时语音总结"
    case transcription = "转写总结"

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

enum TranscriptionJobState: String, CaseIterable, Identifiable {
    case queued
    case running
    case completed
    case failed
    case pausedByLive = "paused_by_live"
    case cancelled

    var id: String { rawValue }
}

struct TranscriptionJob: Identifiable, Hashable {
    let id: String
    var meetingID: String
    var sourcePath: String
    var title: String
    var state: TranscriptionJobState
    var progress: Int
    var stage: String
    var error: String
    var reason: String
    var startedAt: Date?
    var endedAt: Date?
}

struct TranscriptionWatcherState: Equatable {
    var isRunning: Bool = false
    var dirs: [String] = []
    var queueSize: Int = 0
    var activeJobID: String?
}

struct AppCoordinatorState: Equatable {
    var activeRoute: WorkflowRoute = .home
    var liveState: CaptureState = .idle
    var transcriptionState: TranscriptionJobState? = nil
    var preemptionState: PreemptionState = .idle
}

struct SidecarHealth: Equatable {
    var running: Bool
    var pid: Int?
    var socketPath: String
    var uptimeSec: Int
    var isReady: Bool
    var lastErrorCode: String
    var lastLatencyMs: Int

    static let unknown = SidecarHealth(
        running: false,
        pid: nil,
        socketPath: "",
        uptimeSec: 0,
        isReady: false,
        lastErrorCode: "",
        lastLatencyMs: 0
    )
}

struct SidecarHealthSnapshot: Equatable {
    var lastErrorCode: String
    var lastLatencyMs: Int
}

enum TranscriptionPollingMode: String, Equatable {
    case idle
    case active
    case degraded
}

enum AnalysisRuntimeState: String, Equatable {
    case ready
    case pausedTimeout
    case pausedAuthFailed
    case missingConfig

    var userLabel: String {
        switch self {
        case .ready:
            return "分析可用"
        case .pausedTimeout:
            return "分析超时已暂停"
        case .pausedAuthFailed:
            return "分析鉴权失败已暂停"
        case .missingConfig:
            return "分析配置缺失"
        }
    }
}

struct CaptureHealthSnapshot: Equatable {
    var sessionStartedAt: Date?
    var lastChunkAt: Date?
    var lastTranscriptAt: Date?
    var inputLevelMic: Float
    var inputLevelSystem: Float

    static let empty = CaptureHealthSnapshot(
        sessionStartedAt: nil,
        lastChunkAt: nil,
        lastTranscriptAt: nil,
        inputLevelMic: 0,
        inputLevelSystem: 0
    )
}

struct SessionHandle: Equatable {
    var activeMeetingID: String?
    var lastMeetingID: String?

    var buildTargetID: String? {
        activeMeetingID ?? lastMeetingID
    }
}

struct LiveSessionMetrics {
    var chunkIndex: Int = 0
    var latencyMs: Int = 0
    var segmentsIngested: Int = 0
    var lastRefreshAt: Date?
    var provider: String = ""
    var needsReviewCount: Int = 0
    var queueDepth: Int = 0
    var droppedChunks: Int = 0
    var warmReadyMs: Int = 0
    var firstSegmentMs: Int = 0
}

struct InsightRefreshResult {
    let package: InsightPackageV1
    let updatedAt: Date?
    let provider: String
    let needsReviewCount: Int
}

struct DocumentExportResult {
    let path: String
    let format: String
}

struct TranscriptionImportResult {
    let jobID: String
    let meetingID: String
    let state: TranscriptionJobState
}

struct TranscriptionWatchResult {
    let isRunning: Bool
    let dirs: [String]
}

struct TranscriptionCancelResult {
    let jobID: String
    let state: TranscriptionJobState
}

struct TranscriptionLastCompleted {
    let job: TranscriptionJob
    let meetingID: String
    let segmentsCount: Int
    let updatedAt: Date?
}

struct TranscriptionStatusResult {
    let watcher: TranscriptionWatcherState
    let queue: [TranscriptionJob]
    let activeJob: TranscriptionJob?
    let lastCompleted: TranscriptionLastCompleted?
    let jobs: [TranscriptionJob]
}

struct BottomStatusPayload {
    var routeTitle: String = ""
    var stateLabel: String = ""
    var phaseLabel: String = ""
    var lastRefreshAt: Date?
    var meetingID: String = ""

    var developer = BottomDebugPayload()
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

enum ProviderVendor: String, CaseIterable, Codable, Identifiable {
    case openai
    case gemini
    case deepseek
    case qwen
    case doubao

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openai:
            return "OpenAI"
        case .gemini:
            return "Gemini"
        case .deepseek:
            return "DeepSeek"
        case .qwen:
            return "Qwen"
        case .doubao:
            return "豆包 (Ark)"
        }
    }
}

struct ProviderProfile: Codable, Equatable {
    var vendor: ProviderVendor
    var baseURL: String
    var modelID: String
    var apiKeyRef: String
    var extraHeaders: [String: String]
}

enum LocalASREngine: String, Codable, CaseIterable, Identifiable {
    case whisper
    case funasr

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisper:
            return "Whisper"
        case .funasr:
            return "FunASR"
        }
    }

    var userLabel: String {
        switch self {
        case .whisper:
            return "Whisper（通用）"
        case .funasr:
            return "FunASR（中文优先）"
        }
    }
}

struct RuntimeConfigV2: Codable, Equatable {
    struct ASRProfile: Codable, Equatable {
        var model: String
    }

    struct ASR: Codable, Equatable {
        enum CodingKeys: String, CodingKey {
            case engine
            case model
            case modelDir
            case vadEnabled
            case diarizationEnabled
            case whisperProfile
            case funasrProfile
        }

        var engine: LocalASREngine
        var model: String
        var modelDir: String
        var vadEnabled: Bool
        var diarizationEnabled: Bool
        var whisperProfile: ASRProfile
        var funasrProfile: ASRProfile

        init(
            engine: LocalASREngine,
            model: String,
            modelDir: String,
            vadEnabled: Bool,
            diarizationEnabled: Bool,
            whisperProfile: ASRProfile,
            funasrProfile: ASRProfile
        ) {
            self.engine = engine
            self.model = model
            self.modelDir = modelDir
            self.vadEnabled = vadEnabled
            self.diarizationEnabled = diarizationEnabled
            self.whisperProfile = whisperProfile
            self.funasrProfile = funasrProfile
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            engine = try container.decodeIfPresent(LocalASREngine.self, forKey: .engine) ?? .whisper
            model = try container.decodeIfPresent(String.self, forKey: .model) ?? "large-v3"
            modelDir = try container.decode(String.self, forKey: .modelDir)
            vadEnabled = try container.decode(Bool.self, forKey: .vadEnabled)
            diarizationEnabled = try container.decode(Bool.self, forKey: .diarizationEnabled)
            whisperProfile = try container.decodeIfPresent(ASRProfile.self, forKey: .whisperProfile)
                ?? ASRProfile(model: model)
            funasrProfile = try container.decodeIfPresent(ASRProfile.self, forKey: .funasrProfile)
                ?? ASRProfile(model: "iic/speech_paraformer-large-vad-punc_asr_nat-zh-cn-16k-common-vocab8404-pytorch")
        }
    }

    struct Analysis: Codable, Equatable {
        var selectedVendor: ProviderVendor
        var providers: [ProviderProfile]
    }

    struct Strict: Codable, Equatable {
        var strictMode: Bool
    }

    struct Download: Codable, Equatable {
        var autoBootstrapEnabled: Bool
    }

    var asr: ASR
    var analysis: Analysis
    var strict: Strict
    var download: Download
}

typealias RuntimeConfigV1 = RuntimeConfigV2

struct ASRBackendStatus: Equatable {
    let configuredDevice: String
    let configuredComputeType: String
    let device: String
    let computeType: String
    let resolved: String
    let supportedComputeTypes: [String]
}

enum ASRWarmState: String, Equatable {
    case idle
    case loading
    case warming
    case ready
    case failed

    var isInProgress: Bool {
        switch self {
        case .loading, .warming:
            return true
        case .idle, .ready, .failed:
            return false
        }
    }
}

struct ASRWarmStatus: Equatable {
    let ready: Bool
    let state: ASRWarmState
    let inProgress: Bool
    let attempt: Int
    let lastWarmMs: Int
    let lastError: String
}

struct ASRRuntimeStatus: Equatable {
    let ready: Bool
    let pythonExecutable: String
    let pythonVersion: String
    let engine: String
    let engineOptions: [String]
    let activeProfile: String
    let modelName: String
    let modelPath: String
    let modelExists: Bool
    let vadReady: Bool
    let diarizationReady: Bool
    let diarizationDegraded: Bool
    let diarizationReason: String
    let readyByEngine: [String: Bool]
    let backend: ASRBackendStatus
    let warm: ASRWarmStatus
}

struct ASRBootstrapResult: Equatable {
    struct Step: Equatable {
        let name: String
        let ok: Bool
        let detail: String
    }

    let ok: Bool
    let steps: [Step]
    let status: ASRRuntimeStatus
}

struct ASRPrewarmResult: Equatable {
    let ok: Bool
    let engine: String
    let model: String
    let state: ASRWarmState
    let started: Bool
    let inProgress: Bool
    let attempt: Int
    let watchdogSec: Int
    let warmMs: Int
    let backend: ASRBackendStatus
    let warm: ASRWarmStatus
    let error: String
}

struct LiveWarmupSnapshot: Equatable {
    var state: ASRWarmState = .idle
    var attempt: Int = 0
    var bufferedChunks: Int = 0
    var bufferedAudioMs: Int = 0
    var automaticRetryCount: Int = 0
    var isRetryScheduled: Bool = false
    var lastError: String = ""

    static let empty = LiveWarmupSnapshot()
}

enum ProviderProbeErrorCode: String, Codable, Equatable {
    case ok
    case missingConfiguration = "missing_configuration"
    case missingKey = "missing_key"
    case authFailed = "auth_failed"
    case modelNotFound = "model_not_found"
    case unsupportedVendor = "unsupported_vendor"
    case rateLimited = "rate_limited"
    case providerUnavailable = "provider_unavailable"
    case emptyResponse = "empty_response"
    case unknown
}

struct ProviderProbeResult: Equatable {
    let ok: Bool
    let vendor: ProviderVendor
    let model: String
    let baseURL: String
    let code: ProviderProbeErrorCode
    let message: String
    let hint: String
}

struct AnalysisProvidersStatus: Equatable {
    struct Vendor: Equatable, Identifiable {
        let vendor: ProviderVendor
        let baseURL: String
        let modelID: String
        let configured: Bool
        let hasAPIKey: Bool
        let modelReady: Bool

        var id: String { vendor.rawValue }
    }

    let selectedVendor: ProviderVendor
    let activeReady: Bool
    let activeProbeOK: Bool?
    let activeProbeErrorCode: ProviderProbeErrorCode?
    let activeProbeMessage: String
    let vendors: [Vendor]
}

struct RPCSegmentDelta: Codable, Hashable {
    let startMs: Int
    let endMs: Int
    let speaker: String
    let text: String
    let confidence: Double
    let source: String

    enum CodingKeys: String, CodingKey {
        case startMs = "start_ms"
        case endMs = "end_ms"
        case speaker
        case text
        case confidence
        case source
    }
}

struct SystemAudioSourceItem: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case display
        case window
        case application
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
}

struct InsightPackageV1: Codable {
    struct EvidenceSpan: Codable {
        let startMs: Int
        let endMs: Int

        enum CodingKeys: String, CodingKey {
            case startMs = "start_ms"
            case endMs = "end_ms"
        }
    }

    struct SessionOverview: Codable {
        let title: String
        let overview: String
        let topics: [String]
    }

    struct Highlight: Codable {
        let quote: String
        let reason: String
        let speaker: String
        let evidenceSpan: EvidenceSpan

        enum CodingKeys: String, CodingKey {
            case quote
            case reason
            case speaker
            case evidenceSpan = "evidence_span"
        }
    }

    struct SpeakerPerspective: Codable {
        let speaker: String
        let viewpoints: [String]
        let evidenceSpans: [EvidenceSpan]

        enum CodingKeys: String, CodingKey {
            case speaker
            case viewpoints
            case evidenceSpans = "evidence_spans"
        }
    }

    struct Decision: Codable {
        let problem: String
        let options: [String]
        let decision: String
        let rationale: String
        let owner: String
        let needsReview: Bool?
        let evidenceSpan: EvidenceSpan

        enum CodingKeys: String, CodingKey {
            case problem
            case options
            case decision
            case rationale
            case owner
            case needsReview = "needs_review"
            case evidenceSpan = "evidence_span"
        }
    }

    struct ActionTrack: Codable {
        let task: String
        let owner: String
        let dueAt: String
        let priority: String
        let status: String
        let needsReview: Bool?
        let evidenceSpan: EvidenceSpan

        enum CodingKeys: String, CodingKey {
            case task
            case owner
            case dueAt = "due_at"
            case priority
            case status
            case needsReview = "needs_review"
            case evidenceSpan = "evidence_span"
        }
    }

    struct TimelineBeat: Codable {
        let timestamp: String
        let title: String
        let summary: String
    }

    struct ProvenanceLink: Codable {
        let label: String
        let url: String
    }

    let sessionOverview: SessionOverview
    let highlightInsights: [Highlight]
    let speakerPerspectives: [SpeakerPerspective]
    let decisionLedger: [Decision]
    let actionTracks: [ActionTrack]
    let timelineBeats: [TimelineBeat]
    let provenanceLinks: [ProvenanceLink]

    enum CodingKeys: String, CodingKey {
        case sessionOverview = "session_overview"
        case highlightInsights = "highlight_insights"
        case speakerPerspectives = "speaker_perspectives"
        case decisionLedger = "decision_ledger"
        case actionTracks = "action_tracks"
        case timelineBeats = "timeline_beats"
        case provenanceLinks = "provenance_links"
    }
}

extension InsightPackageV1.EvidenceSpan {
    var range: EvidenceRange {
        EvidenceRange(startMs: startMs, endMs: endMs)
    }
}

extension TranscriptionJobState {
    init(apiValue: String) {
        self = TranscriptionJobState(rawValue: apiValue) ?? .queued
    }
}
