import Foundation

public struct DiarizationSnapshot {
    public let spans: [SpeakerSpan]
    public let finalizedUntilMS: Int

    public init(spans: [SpeakerSpan], finalizedUntilMS: Int) {
        self.spans = spans
        self.finalizedUntilMS = finalizedUntilMS
    }
}

public protocol DiarizationEngine: AnyObject {
    func append(_ samples: [Float]) throws
    func finish() throws
    func snapshot() throws -> DiarizationSnapshot
    func cleanup()
}

/// Calls are serialized by the JSONL loop; inference state never crosses sessions.
public final class SessionController {
    public typealias EngineFactory = (WorkerRequest) throws -> any DiarizationEngine

    private final class Session {
        let id: String
        let engine: any DiarizationEngine
        var requestIDs: Set<RequestID>
        var receivedSamples = 0
        var snapshot = DiarizationSnapshot(spans: [], finalizedUntilMS: 0)

        init(id: String, engine: any DiarizationEngine, requestID: RequestID) {
            self.id = id
            self.engine = engine
            self.requestIDs = [requestID]
        }
    }

    private let makeEngine: EngineFactory
    private let audioReader: any AudioReading
    private let limits: WorkerLimits
    private var active: Session?

    public init(
        limits: WorkerLimits = WorkerLimits(), audioReader: any AudioReading = WAVReader(),
        makeEngine: @escaping EngineFactory
    ) {
        self.limits = limits
        self.audioReader = audioReader
        self.makeEngine = makeEngine
    }

    deinit { active?.engine.cleanup() }

    public func close() {
        active?.engine.cleanup()
        active = nil
    }

    public func handle(line: Data) -> WorkerResponse {
        do {
            return handle(try JSONDecoder().decode(WorkerRequest.self, from: line))
        } catch {
            return protocolError("invalid_request", "Expected a JSON request with id, action and session_id")
        }
    }

    public func protocolError(_ code: String, _ message: String) -> WorkerResponse {
        response(request: nil, failure: WorkerFailure(code, message))
    }

    public func handle(_ request: WorkerRequest) -> WorkerResponse {
        do {
            guard !request.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                request.sessionID.utf8.count <= 128
            else { throw WorkerFailure("invalid_request", "session_id must contain 1 to 128 UTF-8 bytes") }
            if case .string(let id) = request.id, id.isEmpty || id.utf8.count > 256 {
                throw WorkerFailure("invalid_request", "String ids must contain 1 to 256 UTF-8 bytes")
            }
            switch request.action {
            case "start":
                if active?.id == request.sessionID {
                    throw WorkerFailure("session_exists", "This session is already active; feed it or reset it first")
                }
                close()
                let engine = try makeEngine(request)
                active = Session(id: request.sessionID, engine: engine, requestID: request.id)
                return response(request: request)
            case "feed":
                return try feed(request)
            case "finish":
                let session = try requireSession(request)
                do {
                    try session.engine.finish()
                    session.snapshot = try clipped(session.engine.snapshot(), receivedSamples: session.receivedSamples)
                    let result = response(request: request, session: session, sessionActive: false)
                    close()
                    return result
                } catch {
                    close()
                    throw inferenceFailure(error)
                }
            case "reset":
                _ = try requireSession(request)
                close()
                return response(request: request)
            default:
                throw WorkerFailure("unsupported_action", "action must be start, feed, finish or reset")
            }
        } catch let failure as WorkerFailure {
            return response(request: request, failure: failure)
        } catch {
            return response(request: request, failure: WorkerFailure("model_load_failed", String(error.localizedDescription.prefix(2_048))))
        }
    }

    private func requireSession(_ request: WorkerRequest) throws -> Session {
        guard let active, active.id == request.sessionID else {
            throw WorkerFailure("session_not_found", "Start this session before feeding, finishing or resetting it")
        }
        guard !active.requestIDs.contains(request.id) else {
            throw WorkerFailure("duplicate_request", "This request id was already accepted by the session")
        }
        return active
    }

    private func feed(_ request: WorkerRequest) throws -> WorkerResponse {
        let session = try requireSession(request)
        guard session.requestIDs.count < limits.maxRequestsPerSession else {
            throw WorkerFailure("session_limit", "Session request limit reached; finish or reset the session")
        }
        guard let path = request.wavPath else {
            throw WorkerFailure("invalid_request", "feed requires wav_path")
        }
        let requestedOffsetSamples: Int
        if let offset = request.offsetMS {
            guard offset >= 0, offset <= limits.maxSessionSamples / 16 else {
                throw WorkerFailure("invalid_offset", "offset_ms must lie within the session duration limit")
            }
            requestedOffsetSamples = offset * 16
        } else {
            requestedOffsetSamples = session.receivedSamples
        }
        // The wire clock is integer milliseconds, but WAV lengths need not be.
        // Accept only its sub-millisecond rounding loss and keep the exact sample
        // cursor; a full millisecond of overlap still represents older audio.
        guard requestedOffsetSamples >= session.receivedSamples
            || session.receivedSamples - requestedOffsetSamples < 16
        else {
            throw WorkerFailure("out_of_order", "Audio overlaps or precedes audio already accepted by the session")
        }
        let offsetSamples = max(requestedOffsetSamples, session.receivedSamples)
        let gap = offsetSamples - session.receivedSamples
        guard gap <= limits.maxGapSamples else {
            throw WorkerFailure("gap_limit", "Audio gap exceeds the session gap limit")
        }
        let samples = try audioReader.read(path: path, maxSamples: limits.maxChunkSamples)
        guard !samples.isEmpty, samples.count <= limits.maxChunkSamples,
            samples.allSatisfy({ $0.isFinite && abs($0) <= 1 })
        else { throw WorkerFailure("invalid_audio", "Audio must contain bounded, finite, normalized samples") }
        guard samples.count <= limits.maxSessionSamples - offsetSamples else {
            throw WorkerFailure("session_limit", "Audio exceeds the session duration limit")
        }

        // No model mutation occurs until path, audio, offsets and limits are all valid.
        // Once inference begins, any failure invalidates the whole session; partial retry is unsafe.
        do {
            let blockSize = max(1, limits.processingBlockSamples)
            var remainingGap = gap
            while remainingGap > 0 {
                let count = min(blockSize, remainingGap)
                try session.engine.append(Array(repeating: 0, count: count))
                remainingGap -= count
            }
            for offset in stride(from: 0, to: samples.count, by: blockSize) {
                let end = min(offset + blockSize, samples.count)
                try session.engine.append(Array(samples[offset..<end]))
            }
            let receivedSamples = offsetSamples + samples.count
            session.snapshot = try clipped(session.engine.snapshot(), receivedSamples: receivedSamples)
            session.receivedSamples = receivedSamples
            session.requestIDs.insert(request.id)
            return response(request: request)
        } catch {
            close()
            throw inferenceFailure(error)
        }
    }

    private func clipped(_ snapshot: DiarizationSnapshot, receivedSamples: Int) throws -> DiarizationSnapshot {
        guard snapshot.finalizedUntilMS >= 0, snapshot.spans.count <= limits.maxSpans else {
            throw WorkerFailure("invalid_model_output", "Model returned an invalid or oversized timeline")
        }
        let finalizedUntil = min(snapshot.finalizedUntilMS, receivedSamples / 16)
        var spans: [SpeakerSpan] = []
        spans.reserveCapacity(snapshot.spans.count)
        for span in snapshot.spans {
            guard span.startMS >= 0, span.endMS >= span.startMS,
                !span.speaker.isEmpty, span.speaker.utf8.count <= 64
            else { throw WorkerFailure("invalid_model_output", "Model returned an invalid speaker span") }
            let end = min(span.endMS, finalizedUntil)
            if end > span.startMS {
                spans.append(SpeakerSpan(startMS: span.startMS, endMS: end, speaker: span.speaker))
            }
        }
        spans.sort {
            if $0.startMS != $1.startMS { return $0.startMS < $1.startMS }
            if $0.endMS != $1.endMS { return $0.endMS < $1.endMS }
            return $0.speaker < $1.speaker
        }
        return DiarizationSnapshot(spans: spans, finalizedUntilMS: finalizedUntil)
    }

    private func inferenceFailure(_ error: Error) -> WorkerFailure {
        let message = (error as? WorkerFailure)?.message ?? error.localizedDescription
        return WorkerFailure("inference_failed", "Session released after inference failure: \(message.prefix(2_048))")
    }

    private func response(
        request: WorkerRequest?, session: Session? = nil, sessionActive: Bool? = nil,
        failure: WorkerFailure? = nil
    ) -> WorkerResponse {
        let matching = session ?? (active?.id == request?.sessionID ? active : nil)
        return WorkerResponse(
            id: request?.id, ok: failure == nil, sessionID: request?.sessionID,
            sessionActive: sessionActive ?? (matching != nil),
            spans: matching?.snapshot.spans ?? [], receivedUntilMS: (matching?.receivedSamples ?? 0) / 16,
            finalizedUntilMS: matching?.snapshot.finalizedUntilMS ?? 0, error: failure
        )
    }
}
