import Foundation

enum RuntimeActionName: String, CaseIterable {
    case recordSave = "record.save"
    case transcriptRecover = "transcript.recover"
    case finalMediaTranscription = "media.transcribe_final"
    case runtimeTranscriptReplace = "runtime.transcript.replace"
    case smartMinutesGenerate = "smart_minutes.generate"

    var capabilityAliases: [String] {
        switch self {
        case .recordSave:
            return ["records.save"]
        case .transcriptRecover, .finalMediaTranscription:
            return ["asr.transcribe_media"]
        case .runtimeTranscriptReplace:
            return ["transcript.replace"]
        case .smartMinutesGenerate:
            return ["insight.build_final"]
        }
    }
}

enum RuntimeActionAvailabilityState: String, Equatable {
    case available
    case unavailable
    case degraded
    case unsupported
    case busy
}

struct RuntimeActionAvailability: Equatable {
    let action: RuntimeActionName
    let state: RuntimeActionAvailabilityState
    let reason: String

    var canAttempt: Bool {
        state == .available || state == .degraded
    }

    static func available(_ action: RuntimeActionName, reason: String = "") -> RuntimeActionAvailability {
        RuntimeActionAvailability(action: action, state: .available, reason: reason)
    }
}

enum RuntimeActionFailure: Error, Equatable, LocalizedError {
    case unavailableCapability(String)
    case retryableFailure(String)
    case incompleteInput(String)
    case technicalFailure(String)

    var errorDescription: String? {
        switch self {
        case .unavailableCapability(let message),
             .retryableFailure(let message),
             .incompleteInput(let message),
             .technicalFailure(let message):
            return message
        }
    }
}

enum RuntimeActionOutcome<Value> {
    case success(Value)
    case unavailable(RuntimeActionAvailability)
    case retryableFailure(String)
    case incompleteInput(String)
    case technicalFailure(String)

    var failure: RuntimeActionFailure? {
        switch self {
        case .success:
            return nil
        case .unavailable(let availability):
            return .unavailableCapability(availability.reason)
        case .retryableFailure(let message):
            return .retryableFailure(message)
        case .incompleteInput(let message):
            return .incompleteInput(message)
        case .technicalFailure(let message):
            return .technicalFailure(message)
        }
    }

    func get() throws -> Value {
        switch self {
        case .success(let value):
            return value
        case .unavailable(let availability):
            throw RuntimeActionFailure.unavailableCapability(availability.reason)
        case .retryableFailure(let message):
            throw RuntimeActionFailure.retryableFailure(message)
        case .incompleteInput(let message):
            throw RuntimeActionFailure.incompleteInput(message)
        case .technicalFailure(let message):
            throw RuntimeActionFailure.technicalFailure(message)
        }
    }
}

protocol RuntimeActionCapabilityProviding {
    func availability(for action: RuntimeActionName) -> RuntimeActionAvailability
}

struct StaticRuntimeActionCapabilityProvider: RuntimeActionCapabilityProviding {
    let availabilityByAction: [RuntimeActionName: RuntimeActionAvailability]
    let defaultAvailability: RuntimeActionAvailabilityState

    init(
        availabilityByAction: [RuntimeActionName: RuntimeActionAvailability] = [:],
        defaultAvailability: RuntimeActionAvailabilityState = .available
    ) {
        self.availabilityByAction = availabilityByAction
        self.defaultAvailability = defaultAvailability
    }

    func availability(for action: RuntimeActionName) -> RuntimeActionAvailability {
        availabilityByAction[action] ?? RuntimeActionAvailability(
            action: action,
            state: defaultAvailability,
            reason: ""
        )
    }
}

final class SidecarVersionRuntimeActionCapabilityProvider: RuntimeActionCapabilityProviding {
    private let rpcClient: InsightRPCClientProtocol

    init(rpcClient: InsightRPCClientProtocol) {
        self.rpcClient = rpcClient
    }

    func availability(for action: RuntimeActionName) -> RuntimeActionAvailability {
        do {
            let version = try rpcClient.sidecarVersion()
            if let registryAvailability = availabilityFromActionRegistry(version, action: action) {
                return registryAvailability
            }
            let capabilities = Set((version["capabilities"] as? [String]) ?? [])
            guard !capabilities.isEmpty else {
                return RuntimeActionAvailability(
                    action: action,
                    state: .degraded,
                    reason: "Runtime did not publish capability details; attempting legacy action."
                )
            }
            let acceptedNames = Set([action.rawValue] + action.capabilityAliases)
            if !capabilities.isDisjoint(with: acceptedNames) {
                return .available(action)
            }
            return RuntimeActionAvailability(
                action: action,
                state: .unsupported,
                reason: "Runtime does not advertise \(action.rawValue)."
            )
        } catch {
            return RuntimeActionAvailability(
                action: action,
                state: .degraded,
                reason: "Runtime capability check failed; attempting \(action.rawValue)."
            )
        }
    }

    private func availabilityFromActionRegistry(
        _ version: [String: Any],
        action: RuntimeActionName
    ) -> RuntimeActionAvailability? {
        guard let registry = version["action_registry"] as? [String: Any],
              let entries = registry["actions"] as? [[String: Any]],
              !entries.isEmpty
        else { return nil }

        guard let entry = entries.first(where: { ($0["name"] as? String) == action.rawValue }) else {
            return RuntimeActionAvailability(
                action: action,
                state: .unsupported,
                reason: "Runtime action registry does not include \(action.rawValue)."
            )
        }
        let stateRaw = (entry["state"] as? String) ?? RuntimeActionAvailabilityState.unavailable.rawValue
        let state = RuntimeActionAvailabilityState(rawValue: stateRaw) ?? .unavailable
        return RuntimeActionAvailability(
            action: action,
            state: state,
            reason: (entry["reason"] as? String) ?? ""
        )
    }
}

protocol RuntimeActionRPCAdapting {
    func availability(for action: RuntimeActionName) -> RuntimeActionAvailability
    func recordsSave(_ request: RecordSaveActionRequest) throws -> String
    func asrTranscribeMedia(mediaPath: String, source: String) throws -> [RPCSegmentDelta]
    func transcriptReplace(meetingID: String, segments: [RPCSegmentDelta]) throws -> Int
    func buildFinal(meetingID: String) throws -> InsightRefreshResult
}

final class InsightRuntimeActionRPCAdapter: RuntimeActionRPCAdapting {
    private let rpcClient: InsightRPCClientProtocol
    private let capabilityProvider: RuntimeActionCapabilityProviding

    init(
        rpcClient: InsightRPCClientProtocol,
        capabilityProvider: RuntimeActionCapabilityProviding? = nil
    ) {
        self.rpcClient = rpcClient
        self.capabilityProvider = capabilityProvider ?? SidecarVersionRuntimeActionCapabilityProvider(rpcClient: rpcClient)
    }

    func availability(for action: RuntimeActionName) -> RuntimeActionAvailability {
        capabilityProvider.availability(for: action)
    }

    func recordsSave(_ request: RecordSaveActionRequest) throws -> String {
        try rpcClient.recordsSave(
            meetingID: request.meetingID,
            title: request.title,
            sourcePath: request.sourcePath,
            segments: request.segments,
            insightPackage: request.insightPackage,
            mediaType: request.mediaType,
            recordSource: request.recordSource,
            durationSec: request.durationSec,
            analysisMeta: request.analysisMeta,
            notesMD: request.notesMD
        )
    }

    func asrTranscribeMedia(mediaPath: String, source: String) throws -> [RPCSegmentDelta] {
        try rpcClient.asrTranscribeMedia(mediaPath: mediaPath, source: source)
    }

    func transcriptReplace(meetingID: String, segments: [RPCSegmentDelta]) throws -> Int {
        try rpcClient.transcriptReplace(meetingID: meetingID, segments: segments)
    }

    func buildFinal(meetingID: String) throws -> InsightRefreshResult {
        try rpcClient.buildFinal(meetingID: meetingID)
    }
}

struct RecordSaveActionRequest {
    let meetingID: String
    let title: String
    let sourcePath: String
    let segments: [[String: Any]]
    let insightPackage: [String: Any]?
    let mediaType: String
    let recordSource: String
    let durationSec: Double
    let analysisMeta: [String: Any]?
    let notesMD: String
}

struct RecordSaveActionResult: Equatable {
    let recordPath: String
}

protocol RecordSaveActioning {
    func saveRecord(_ request: RecordSaveActionRequest) -> RuntimeActionOutcome<RecordSaveActionResult>
}

final class RecordSaveAction: RecordSaveActioning {
    private let adapter: RuntimeActionRPCAdapting

    init(adapter: RuntimeActionRPCAdapting) {
        self.adapter = adapter
    }

    func saveRecord(_ request: RecordSaveActionRequest) -> RuntimeActionOutcome<RecordSaveActionResult> {
        guard !request.meetingID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .incompleteInput("Record Save requires a meeting ID.")
        }
        let hasMediaSource = !request.sourcePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasMediaSource || !request.segments.isEmpty else {
            return .incompleteInput("Record Save requires a media source path or transcript segments.")
        }
        guard request.durationSec.isFinite, request.durationSec >= 0 else {
            return .incompleteInput("Record Save requires a valid duration.")
        }

        let availability = adapter.availability(for: .recordSave)
        guard availability.canAttempt else { return .unavailable(availability) }

        do {
            let path = try adapter.recordsSave(request)
            guard !path.isEmpty else {
                return .technicalFailure("Record Save returned no record path.")
            }
            return .success(RecordSaveActionResult(recordPath: path))
        } catch {
            return RuntimeActionErrorMapper.map(error, action: .recordSave)
        }
    }
}

struct TranscriptRecoveryActionRequest {
    let mediaPath: String
    let source: String
}

protocol TranscriptRecoveryActioning {
    func recoverTranscript(_ request: TranscriptRecoveryActionRequest) -> RuntimeActionOutcome<[TranscriptSegment]>
}

final class TranscriptRecoveryAction: TranscriptRecoveryActioning {
    private let adapter: RuntimeActionRPCAdapting

    init(adapter: RuntimeActionRPCAdapting) {
        self.adapter = adapter
    }

    func recoverTranscript(_ request: TranscriptRecoveryActionRequest) -> RuntimeActionOutcome<[TranscriptSegment]> {
        guard !request.mediaPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .incompleteInput("Transcript Recovery requires saved media.")
        }

        let availability = adapter.availability(for: .transcriptRecover)
        guard availability.canAttempt else { return .unavailable(availability) }

        do {
            let segments = try adapter.asrTranscribeMedia(mediaPath: request.mediaPath, source: request.source)
            return .success(segments.map(Self.transcriptSegment))
        } catch {
            return RuntimeActionErrorMapper.map(error, action: .transcriptRecover)
        }
    }

    private static func transcriptSegment(from delta: RPCSegmentDelta) -> TranscriptSegment {
        TranscriptSegment(
            startMs: delta.startMs,
            endMs: delta.endMs,
            speaker: delta.speaker.isEmpty ? "未标注" : delta.speaker,
            source: delta.source,
            text: delta.text
        )
    }
}

struct FinalMediaTranscriptionActionRequest {
    let mediaPath: String
    let source: String
}

protocol FinalMediaTranscriptionActioning {
    func transcribeFinalMedia(_ request: FinalMediaTranscriptionActionRequest) -> RuntimeActionOutcome<[TranscriptSegment]>
}

final class FinalMediaTranscriptionAction: FinalMediaTranscriptionActioning {
    private let adapter: RuntimeActionRPCAdapting
    private let appleSpeechService: AppleSpeechTranscriptionService
    private let appleSpeechPrototypeEnabled: () -> Bool

    init(
        adapter: RuntimeActionRPCAdapting,
        appleSpeechService: AppleSpeechTranscriptionService = AppleSpeechTranscriptionService(),
        appleSpeechPrototypeEnabled: @escaping () -> Bool = { false }
    ) {
        self.adapter = adapter
        self.appleSpeechService = appleSpeechService
        self.appleSpeechPrototypeEnabled = appleSpeechPrototypeEnabled
    }

    func transcribeFinalMedia(_ request: FinalMediaTranscriptionActionRequest) -> RuntimeActionOutcome<[TranscriptSegment]> {
        guard !request.mediaPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .incompleteInput("Final Media Transcription requires a media path.")
        }

        let availability = adapter.availability(for: .finalMediaTranscription)
        guard availability.canAttempt else { return .unavailable(availability) }

        do {
            if appleSpeechPrototypeEnabled(),
               FinalMediaTranscriptionRouter.isAppleSpeechAudioCandidate(mediaPath: request.mediaPath) {
                return .success(try transcribeWithAppleSpeech(mediaPath: request.mediaPath))
            }
            let segments = try adapter.asrTranscribeMedia(mediaPath: request.mediaPath, source: request.source)
            return .success(segments.map(Self.transcriptSegment))
        } catch {
            return RuntimeActionErrorMapper.map(error, action: .finalMediaTranscription)
        }
    }

    private static func transcriptSegment(from delta: RPCSegmentDelta) -> TranscriptSegment {
        TranscriptSegment(
            startMs: delta.startMs,
            endMs: delta.endMs,
            speaker: delta.speaker.isEmpty ? "未标注" : delta.speaker,
            source: delta.source,
            text: delta.text
        )
    }

    private func transcribeWithAppleSpeech(mediaPath: String) throws -> [TranscriptSegment] {
        let mediaURL = URL(fileURLWithPath: mediaPath)
        let outcomeBox = FinalMediaTranscriptionOutcomeBox()

        Task.detached { [appleSpeechService] in
            let result: Result<[TranscriptSegment], Error>
            do {
                result = .success(try await appleSpeechService.transcribeAudioFile(mediaURL))
            } catch {
                result = .failure(error)
            }
            outcomeBox.complete(result)
        }

        return try outcomeBox.wait().get()
    }
}

struct RuntimeTranscriptReplacementActionRequest {
    let meetingID: String
    let segments: [RPCSegmentDelta]
}

struct RuntimeTranscriptReplacementActionResult: Equatable {
    let replacedCount: Int
}

protocol RuntimeTranscriptReplacementActioning {
    func replaceRuntimeTranscript(
        _ request: RuntimeTranscriptReplacementActionRequest
    ) -> RuntimeActionOutcome<RuntimeTranscriptReplacementActionResult>
}

final class RuntimeTranscriptReplacementAction: RuntimeTranscriptReplacementActioning {
    private let adapter: RuntimeActionRPCAdapting

    init(adapter: RuntimeActionRPCAdapting) {
        self.adapter = adapter
    }

    func replaceRuntimeTranscript(
        _ request: RuntimeTranscriptReplacementActionRequest
    ) -> RuntimeActionOutcome<RuntimeTranscriptReplacementActionResult> {
        guard !request.meetingID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .incompleteInput("Runtime Transcript Replacement requires a meeting ID.")
        }

        let availability = adapter.availability(for: .runtimeTranscriptReplace)
        guard availability.canAttempt else { return .unavailable(availability) }

        do {
            let count = try adapter.transcriptReplace(meetingID: request.meetingID, segments: request.segments)
            return .success(RuntimeTranscriptReplacementActionResult(replacedCount: count))
        } catch {
            return RuntimeActionErrorMapper.map(error, action: .runtimeTranscriptReplace)
        }
    }
}

struct SmartMinutesGenerationActionRequest {
    let meetingID: String
}

protocol SmartMinutesGenerationActioning {
    func generateSmartMinutes(_ request: SmartMinutesGenerationActionRequest) -> RuntimeActionOutcome<InsightRefreshResult>
}

final class SmartMinutesGenerationAction: SmartMinutesGenerationActioning {
    private let adapter: RuntimeActionRPCAdapting

    init(adapter: RuntimeActionRPCAdapting) {
        self.adapter = adapter
    }

    func generateSmartMinutes(_ request: SmartMinutesGenerationActionRequest) -> RuntimeActionOutcome<InsightRefreshResult> {
        guard !request.meetingID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .incompleteInput("Smart Minutes Generation requires a meeting ID.")
        }

        let availability = adapter.availability(for: .smartMinutesGenerate)
        guard availability.canAttempt else { return .unavailable(availability) }

        do {
            return .success(try adapter.buildFinal(meetingID: request.meetingID))
        } catch {
            return RuntimeActionErrorMapper.map(error, action: .smartMinutesGenerate)
        }
    }
}

enum RuntimeActionErrorMapper {
    static func map<Value>(_ error: Error, action: RuntimeActionName) -> RuntimeActionOutcome<Value> {
        if let rpcError = error as? InsightRPCClient.RPCError {
            switch rpcError {
            case .timeout,
                 .connectFailed,
                 .sendFailed,
                 .receiveFailed,
                 .persistentNotConnected,
                 .handshakeFailed:
                return .retryableFailure(rpcError.localizedDescription)
            case .remoteError(let message):
                if message.localizedCaseInsensitiveContains("method not found") {
                    return .unavailable(RuntimeActionAvailability(
                        action: action,
                        state: .unsupported,
                        reason: message
                    ))
                }
                return .technicalFailure(message)
            case .invalidResponse,
                 .socketCreateFailed,
                 .socketPathTooLong:
                return .technicalFailure(rpcError.localizedDescription)
            }
        }

        return .technicalFailure(error.localizedDescription)
    }
}

private final class FinalMediaTranscriptionOutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var outcome: Result<[TranscriptSegment], Error>?

    func complete(_ result: Result<[TranscriptSegment], Error>) {
        lock.lock()
        outcome = result
        lock.unlock()
        semaphore.signal()
    }

    func wait() -> Result<[TranscriptSegment], Error> {
        semaphore.wait()
        lock.lock()
        let result = outcome
        lock.unlock()
        return result ?? .success([])
    }
}
