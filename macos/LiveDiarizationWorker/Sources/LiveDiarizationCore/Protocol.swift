import Foundation

public enum RequestID: Codable, Hashable, Sendable {
    case string(String)
    case integer(Int64)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        }
    }
}

public struct WorkerRequest: Decodable, Sendable {
    public let id: RequestID
    public let action: String
    public let sessionID: String
    public let wavPath: String?
    public let offsetMS: Int?
    public let variant: String?
    public let modelPath: String?

    enum CodingKeys: String, CodingKey {
        case id, action, variant
        case sessionID = "session_id", wavPath = "wav_path", offsetMS = "offset_ms"
        case modelPath = "model_path"
    }

    public init(
        id: RequestID, action: String, sessionID: String, wavPath: String? = nil,
        offsetMS: Int? = nil, variant: String? = nil, modelPath: String? = nil
    ) {
        self.id = id
        self.action = action
        self.sessionID = sessionID
        self.wavPath = wavPath
        self.offsetMS = offsetMS
        self.variant = variant
        self.modelPath = modelPath
    }
}

public struct SpeakerSpan: Codable, Equatable, Sendable {
    public let startMS: Int
    public let endMS: Int
    public let speaker: String

    enum CodingKeys: String, CodingKey {
        case startMS = "start_ms", endMS = "end_ms", speaker
    }

    public init(startMS: Int, endMS: Int, speaker: String) {
        self.startMS = startMS
        self.endMS = endMS
        self.speaker = speaker
    }
}

public struct WorkerFailure: Error, Codable, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
}

public struct WorkerResponse: Encodable, Sendable {
    public let id: RequestID?
    public let ok: Bool
    public let sessionID: String?
    public let sessionActive: Bool
    public let spans: [SpeakerSpan]
    public let receivedUntilMS: Int
    public let finalizedUntilMS: Int
    public let error: WorkerFailure?

    enum CodingKeys: String, CodingKey {
        case id, ok, spans, error
        case sessionID = "session_id", sessionActive = "session_active"
        case spansMode = "spans_mode", receivedUntilMS = "received_until_ms"
        case finalizedUntilMS = "finalized_until_ms"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(ok, forKey: .ok)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(sessionActive, forKey: .sessionActive)
        try container.encode(spans, forKey: .spans)
        try container.encode("cumulative", forKey: .spansMode)
        try container.encode(receivedUntilMS, forKey: .receivedUntilMS)
        try container.encode(finalizedUntilMS, forKey: .finalizedUntilMS)
        try container.encodeIfPresent(error, forKey: .error)
    }
}

/// Limits apply before model mutation. The process owns one continuous media clock.
public struct WorkerLimits: Sendable {
    public var maxChunkSamples = 30 * 16_000
    public var maxGapSamples = 120 * 16_000
    public var maxSessionSamples = 3_600 * 16_000
    public var processingBlockSamples = 8_000
    public var maxRequestsPerSession = 20_000
    public var maxSpans = 200_000

    public init() {}
}
