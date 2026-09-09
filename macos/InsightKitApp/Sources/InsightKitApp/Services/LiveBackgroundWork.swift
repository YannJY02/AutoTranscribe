import Foundation

struct LiveBackgroundSession: Equatable {
    let meetingID: String
    let generation: UUID
}

struct LiveSpeakerRequest {
    let session: LiveBackgroundSession
    let chunkID: String
}

struct LiveSpeakerUpdate {
    let chunkID: String
    let originalSegments: [RPCSegmentDelta]
    let segments: [RPCSegmentDelta]
}

struct LiveSpeakerEnrichmentResult {
    enum Status: String {
        case updated, pending, unavailable, stopped
    }

    let meetingID: String
    let updates: [LiveSpeakerUpdate]
    let status: Status
    let error: String?
}

/// One blocking operation and a bounded pending list. Invalidating never waits
/// for I/O; the owner rejects an in-flight result using its session generation.
/// Mutable queue state is locked, and operation/completion run on the worker.
final class BoundedLiveWorkQueue<Request, Output>: @unchecked Sendable {
    private let lock = NSLock()
    private let worker: DispatchQueue
    private let maximumPending: Int
    private let coalescesPending: Bool
    private let operation: (Request) throws -> Output
    private let completion: (Request, Result<Output, Error>) -> Void
    private var pending: [Request] = []
    private var running = false

    init(
        label: String,
        maximumPending: Int,
        coalescesPending: Bool = false,
        operation: @escaping (Request) throws -> Output,
        completion: @escaping (Request, Result<Output, Error>) -> Void
    ) {
        worker = DispatchQueue(label: label, qos: .utility)
        self.maximumPending = max(1, maximumPending)
        self.coalescesPending = coalescesPending
        self.operation = operation
        self.completion = completion
    }

    @discardableResult
    func submit(_ request: Request) -> Bool {
        lock.lock()
        if coalescesPending {
            pending = [request]
        } else {
            guard pending.count < maximumPending else {
                lock.unlock()
                return false
            }
            pending.append(request)
        }
        let shouldStart = !running
        running = true
        lock.unlock()
        if shouldStart { worker.async { [self] in drain() } }
        return true
    }

    func invalidate() {
        lock.withLock { pending.removeAll(keepingCapacity: false) }
    }

    var pendingCount: Int { lock.withLock { pending.count } }

    private func next() -> Request? {
        lock.withLock {
            guard !pending.isEmpty else {
                running = false
                return nil
            }
            return pending.removeFirst()
        }
    }

    private func drain() {
        while let request = next() {
            let result = Result { try operation(request) }
            completion(request, result)
        }
    }
}

enum LiveSpeakerPatch {
    /// Replace only the original rows, never every row within their time span.
    /// A missing or ambiguous original leaves that update untouched.
    static func apply(_ updates: [LiveSpeakerUpdate], to current: [TranscriptSegment]) -> [TranscriptSegment] {
        var rows = current
        for update in updates {
            guard !update.originalSegments.isEmpty, !update.segments.isEmpty else { continue }
            var indices: [Int] = []
            for original in update.originalSegments {
                let matches = rows.indices.filter { index in
                    let row = rows[index]
                    return row.startMs == original.startMs && row.endMs == original.endMs
                        && row.text == original.text && row.source == original.source
                }
                guard matches.count == 1, !indices.contains(matches[0]) else {
                    indices.removeAll()
                    break
                }
                indices.append(matches[0])
            }
            guard indices.count == update.originalSegments.count else { continue }
            let sources = Set(update.originalSegments.map(\.source))
            guard update.segments.allSatisfy({
                $0.endMs > $0.startMs && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && sources.contains($0.source)
            }) else { continue }
            for index in indices.sorted(by: >) { rows.remove(at: index) }
            rows.append(contentsOf: update.segments.map {
                TranscriptSegment(startMs: $0.startMs, endMs: $0.endMs,
                                  speaker: $0.speaker.isEmpty ? "未标注" : $0.speaker,
                                  source: $0.source, text: $0.text)
            })
        }
        return rows.sorted { $0.startMs < $1.startMs }
    }
}

struct LiveInsightRefreshOutcome {
    let result: InsightRefreshResult?
    let latencyMs: Int
    let runtimeState: AnalysisRuntimeState
    let shouldSuspend: Bool
    let statusMessage: String?
    let errorMessage: String?

    static func run(
        client: InsightRPCClientProtocol,
        meetingID: String,
        classifier: LiveTranscriptPipelineErrorClassifier = .localizedDescription
    ) -> LiveInsightRefreshOutcome {
        let start = ProcessInfo.processInfo.systemUptime
        do {
            let result = try client.refreshLive(meetingID: meetingID, windowSec: 120)
            return LiveInsightRefreshOutcome(result: result,
                latencyMs: Int((ProcessInfo.processInfo.systemUptime - start) * 1_000),
                runtimeState: .ready, shouldSuspend: false, statusMessage: nil, errorMessage: nil)
        } catch {
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - start) * 1_000)
            if classifier.isProviderAuthFailure(error) {
                return LiveInsightRefreshOutcome(result: nil, latencyMs: elapsed,
                    runtimeState: .pausedAuthFailed, shouldSuspend: true, statusMessage: nil,
                    errorMessage: "智能分析服务鉴权失败，转写继续、洞察已暂停。请打开设置修复 API 配置后重新开始直播洞察。")
            }
            if classifier.isProviderInvalidResponse(error) {
                return LiveInsightRefreshOutcome(result: nil, latencyMs: elapsed,
                    runtimeState: .pausedInvalidResponse, shouldSuspend: true, statusMessage: nil,
                    errorMessage: AnalysisProviderErrorPresentation.invalidResponseMessage)
            }
            if classifier.isProviderProbeTimeout(error) {
                return LiveInsightRefreshOutcome(result: nil, latencyMs: elapsed,
                    runtimeState: .pausedTimeout, shouldSuspend: true, statusMessage: nil,
                    errorMessage: "智能分析探测超时，转写继续、洞察已暂停。请稍后重试或检查网络。")
            }
            let busy = error.localizedDescription.contains("live_insight_busy")
            let message = busy ? LiveAnalysisHealthHint.refreshBusy
                : classifier.isLiveRefreshTimeout(error) ? LiveAnalysisHealthHint.refreshTimeout
                : LiveAnalysisHealthHint.refreshUnavailable
            return LiveInsightRefreshOutcome(result: nil, latencyMs: elapsed,
                runtimeState: .ready, shouldSuspend: false, statusMessage: message, errorMessage: nil)
        }
    }
}
