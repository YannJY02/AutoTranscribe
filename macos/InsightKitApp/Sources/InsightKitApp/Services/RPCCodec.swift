import Foundation

// MARK: - Request/Response Envelope

struct RPCRequest<P: Encodable>: Encodable {
    let id: Int
    let method: String
    let params: P
}

struct EmptyParams: Codable {}

struct RPCRawResponse: Decodable {
    let id: Int?
    let result: AnyCodableValue?
    let error: RPCErrorPayload?
}

struct RPCErrorPayload: Decodable {
    let code: Int
    let message: String
}

struct RPCEventEnvelope {
    let name: String
    let data: [String: Any]
}

// MARK: - Codec

enum RPCCodec {
    private static let snakeCaseDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try snakeCaseDecoder.decode(type, from: data)
    }

    static func decodeEvent(from data: Data) throws -> RPCEventEnvelope {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = obj["event"] as? String else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not an event"))
        }
        let eventData = obj["data"] as? [String: Any] ?? [:]
        return RPCEventEnvelope(name: event, data: eventData)
    }
}

// MARK: - Typed Response Models

struct SidecarStatusResponse: Decodable {
    let running: Bool
    let pid: Int
    let version: String
    let build: String
    let socketPath: String
    let uptimeSec: Int
    let liveSessions: Int
    let ready: Bool
    let pythonExecutable: String
    let pythonVersion: String
    let lastErrorCode: String
    let lastLatencyMs: Int
}

// MARK: - Push Event Models

struct TranscriptionProgressEvent: Decodable {
    let jobId: String
    let progress: Int
    let stage: String
}

struct TranscriptionCompletedEvent: Decodable {
    let jobId: String
    let meetingId: String
    let state: String
}

// MARK: - AnyCodableValue for raw JSON

enum AnyCodableValue: Decodable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case dictionary([String: AnyCodableValue])
    case array([AnyCodableValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let v = try? container.decode(Bool.self) { self = .bool(v); return }
        if let v = try? container.decode(Int.self) { self = .int(v); return }
        if let v = try? container.decode(Double.self) { self = .double(v); return }
        if let v = try? container.decode(String.self) { self = .string(v); return }
        if let v = try? container.decode([String: AnyCodableValue].self) { self = .dictionary(v); return }
        if let v = try? container.decode([AnyCodableValue].self) { self = .array(v); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type")
    }
}
