import Foundation

enum LocalASREngine: String, Codable, CaseIterable, Identifiable {
    case whisper
    case funasr
    case qwenmlx = "qwen-mlx"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisper:
            return "Whisper"
        case .funasr:
            return "FunASR"
        case .qwenmlx:
            return "Qwen3-ASR MLX"
        }
    }

    var userLabel: String {
        switch self {
        case .whisper:
            return "Whisper（通用）"
        case .funasr:
            return "FunASR（中文优先）"
        case .qwenmlx:
            return "Qwen3-ASR MLX（能力上限）"
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
            case qwenProfile
        }

        var engine: LocalASREngine
        var model: String
        var modelDir: String
        var vadEnabled: Bool
        var diarizationEnabled: Bool
        var whisperProfile: ASRProfile
        var funasrProfile: ASRProfile
        var qwenProfile: ASRProfile

        init(
            engine: LocalASREngine,
            model: String,
            modelDir: String,
            vadEnabled: Bool,
            diarizationEnabled: Bool,
            whisperProfile: ASRProfile,
            funasrProfile: ASRProfile,
            qwenProfile: ASRProfile
        ) {
            self.engine = engine
            self.model = model
            self.modelDir = modelDir
            self.vadEnabled = vadEnabled
            self.diarizationEnabled = diarizationEnabled
            self.whisperProfile = whisperProfile
            self.funasrProfile = funasrProfile
            self.qwenProfile = qwenProfile
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
            qwenProfile = try container.decodeIfPresent(ASRProfile.self, forKey: .qwenProfile)
                ?? ASRProfile(model: "Qwen3-ASR-1.7B-MLX-4bit")
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

extension ASRRuntimeStatus {
    var userVisibleReadinessMessage: String? {
        if ready {
            return nil
        }

        let model = modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? activeProfile : modelName
        if !modelExists {
            let path = modelPath.trimmingCharacters(in: .whitespacesAndNewlines)
            let location = path.isEmpty ? "" : " 当前查找路径：\(path)。"
            return "ASR 模型文件缺失：\(model)。请在设置中点击“一键修复语音识别”下载或修复模型。\(location)"
        }

        let warmError = warm.lastError.trimmingCharacters(in: .whitespacesAndNewlines)
        if !warmError.isEmpty {
            return "ASR 模型未就绪：\(warmError)。请在设置中点击“一键修复语音识别”后重试。"
        }

        return "ASR 模型未就绪：\(engine) / \(model)。请在设置中点击“一键修复语音识别”后重试。"
    }

    var userVisibleReadinessAccessibilityIdentifier: String? {
        guard !ready else { return nil }
        return modelExists ? "settings_asr_runtime_warning_status" : "settings_asr_model_missing_status"
    }
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
