import Foundation

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
