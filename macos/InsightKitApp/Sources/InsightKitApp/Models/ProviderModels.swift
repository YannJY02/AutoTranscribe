import Foundation

enum AnalysisMode: String, CaseIterable, Codable, Identifiable {
    case local
    case cloud

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local: return "本地（离线）"
        case .cloud: return "云端"
        }
    }
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

enum AnalysisRuntimeState: String, Equatable {
    case ready
    case pausedTimeout
    case pausedAuthFailed
    case pausedInvalidResponse
    case missingConfig

    var userLabel: String {
        switch self {
        case .ready:
            return "分析可用"
        case .pausedTimeout:
            return "分析超时已暂停"
        case .pausedAuthFailed:
            return "分析鉴权失败已暂停"
        case .pausedInvalidResponse:
            return "分析返回格式异常"
        case .missingConfig:
            return "分析配置缺失"
        }
    }
}

enum AnalysisProviderErrorPresentation {
    static let invalidResponseMessage = "分析服务返回格式异常，转写和已有纪要已保留。请稍后重试，或打开设置检查 Provider 配置。"

    static func isInvalidResponse(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        return lower.contains("provider returned non-json payload")
            || lower.contains("non-json payload")
            || lower.contains("expecting ',' delimiter")
            || lower.contains("expecting value")
    }

    static func isInvalidResponse(_ error: Error) -> Bool {
        isInvalidResponse(error.localizedDescription)
    }

    static func sanitizedMessage(for raw: String) -> String? {
        isInvalidResponse(raw) ? invalidResponseMessage : nil
    }
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
