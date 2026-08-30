import Foundation

protocol LiveTranscriptProcessing {
    func reset()
    func process(chunk: AudioChunk, context: LiveTranscriptPipelineContext) throws -> LiveTranscriptPipelineOutcome
}

protocol LiveTranscriptPipelineRuntime {
    func transcribe(chunk: AudioChunk, source: String) throws -> [RPCSegmentDelta]
    func appendTranscriptDelta(meetingID: String, segments: [RPCSegmentDelta]) throws -> Int
    func refreshLiveInsight(meetingID: String, windowSec: Int) throws -> InsightRefreshResult
}

struct InsightRPCLiveTranscriptPipelineRuntime: LiveTranscriptPipelineRuntime {
    let rpcClient: InsightRPCClientProtocol

    func transcribe(chunk: AudioChunk, source: String) throws -> [RPCSegmentDelta] {
        try rpcClient.asrTranscribeChunk(
            wavPath: chunk.url.path,
            offsetMs: chunk.startMs,
            source: source
        )
    }

    func appendTranscriptDelta(meetingID: String, segments: [RPCSegmentDelta]) throws -> Int {
        try rpcClient.transcriptDelta(meetingID: meetingID, segments: segments)
    }

    func refreshLiveInsight(meetingID: String, windowSec: Int) throws -> InsightRefreshResult {
        try rpcClient.refreshLive(meetingID: meetingID, windowSec: windowSec)
    }
}

struct LiveTranscriptPipelineContext {
    let meetingID: String
    let source: String
    let sessionStartedAt: Date?
    let warmReady: Bool
    let hasTranscript: Bool
    let isInsightRefreshSuspended: Bool
}

enum LiveTranscriptPipelineRefresh {
    case none
    case success(InsightRefreshResult)
    case paused(LiveTranscriptPipelinePauseReason)
}

enum LiveTranscriptPipelinePauseReason {
    case alreadySuspended
    case authFailed
    case timeout
    case invalidProviderResponse
}

struct LiveTranscriptPipelineOutcome {
    let chunkIndex: Int
    let latencyMs: Int
    let analysisLatencyMs: Int?
    let ingestedCount: Int
    let transcriptSegments: [TranscriptSegment]
    let captureState: CaptureState
    let firstSegmentMs: Int?
    let lastTranscriptAt: Date?
    let refresh: LiveTranscriptPipelineRefresh
    let providerMetric: String?
    let analysisRuntimeState: AnalysisRuntimeState?
    let errorMessage: String?

    init(
        chunkIndex: Int,
        latencyMs: Int,
        analysisLatencyMs: Int? = nil,
        ingestedCount: Int,
        transcriptSegments: [TranscriptSegment],
        captureState: CaptureState,
        firstSegmentMs: Int?,
        lastTranscriptAt: Date?,
        refresh: LiveTranscriptPipelineRefresh,
        providerMetric: String?,
        analysisRuntimeState: AnalysisRuntimeState?,
        errorMessage: String?
    ) {
        self.chunkIndex = chunkIndex
        self.latencyMs = latencyMs
        self.analysisLatencyMs = analysisLatencyMs
        self.ingestedCount = ingestedCount
        self.transcriptSegments = transcriptSegments
        self.captureState = captureState
        self.firstSegmentMs = firstSegmentMs
        self.lastTranscriptAt = lastTranscriptAt
        self.refresh = refresh
        self.providerMetric = providerMetric
        self.analysisRuntimeState = analysisRuntimeState
        self.errorMessage = errorMessage
    }
}

struct LiveTranscriptPipelineErrorClassifier {
    let isProviderAuthFailure: (Error) -> Bool
    let isProviderProbeTimeout: (Error) -> Bool
    let isLiveRefreshTimeout: (Error) -> Bool
    let isProviderInvalidResponse: (Error) -> Bool

    init(
        isProviderAuthFailure: @escaping (Error) -> Bool,
        isProviderProbeTimeout: @escaping (Error) -> Bool,
        isLiveRefreshTimeout: @escaping (Error) -> Bool = { _ in false },
        isProviderInvalidResponse: @escaping (Error) -> Bool = { _ in false }
    ) {
        self.isProviderAuthFailure = isProviderAuthFailure
        self.isProviderProbeTimeout = isProviderProbeTimeout
        self.isLiveRefreshTimeout = isLiveRefreshTimeout
        self.isProviderInvalidResponse = isProviderInvalidResponse
    }

    static let localizedDescription = LiveTranscriptPipelineErrorClassifier(
        isProviderAuthFailure: { error in
            let lower = error.localizedDescription.lowercased()
            if lower.contains("鉴权失败") || lower.contains("authentication fails") {
                return true
            }
            return lower.contains("http 401") || lower.contains("governor")
        },
        isProviderProbeTimeout: { error in
            let lower = error.localizedDescription.lowercased()
            return lower.contains("调用超时: analysis.provider.probe")
                || lower.contains("调用超时: analysis.providers.status")
                || lower.contains("probe_timeout")
        },
        isLiveRefreshTimeout: { error in
            let lower = error.localizedDescription.lowercased()
            return lower.contains("调用超时: insight.refresh_live")
                || (lower.contains("insight.refresh_live") && (lower.contains("timeout") || lower.contains("超时")))
        },
        isProviderInvalidResponse: { error in
            AnalysisProviderErrorPresentation.isInvalidResponse(error)
        }
    )
}

final class LiveTranscriptPipeline: LiveTranscriptProcessing {
    private let runtime: LiveTranscriptPipelineRuntime
    private let errorClassifier: LiveTranscriptPipelineErrorClassifier
    private let clock: () -> Date
    private var coordinator: LiveInsightCoordinator
    private var recentFingerprints: [String]

    init(
        runtime: LiveTranscriptPipelineRuntime,
        coordinator: LiveInsightCoordinator = LiveInsightCoordinator(),
        recentFingerprints: [String] = [],
        errorClassifier: LiveTranscriptPipelineErrorClassifier = .localizedDescription,
        clock: @escaping () -> Date = Date.init
    ) {
        self.runtime = runtime
        self.coordinator = coordinator
        self.recentFingerprints = recentFingerprints
        self.errorClassifier = errorClassifier
        self.clock = clock
    }

    func reset() {
        coordinator.reset()
        recentFingerprints.removeAll(keepingCapacity: true)
    }

    func process(chunk: AudioChunk, context: LiveTranscriptPipelineContext) throws -> LiveTranscriptPipelineOutcome {
        let startedProcessingAt = clock()
        var deltas = try runtime.transcribe(chunk: chunk, source: context.source)
        deltas = deduplicate(deltas)
        let chunkIndex = chunk.index + 1

        guard !deltas.isEmpty else {
            return LiveTranscriptPipelineOutcome(
                chunkIndex: chunkIndex,
                latencyMs: 0,
                analysisLatencyMs: nil,
                ingestedCount: 0,
                transcriptSegments: [],
                captureState: captureState(context: context, hasNewTranscript: false),
                firstSegmentMs: nil,
                lastTranscriptAt: nil,
                refresh: .none,
                providerMetric: nil,
                analysisRuntimeState: nil,
                errorMessage: nil
            )
        }

        let ingested = try runtime.appendTranscriptDelta(meetingID: context.meetingID, segments: deltas)
        let processedAt = clock()
        let transcriptSegments = deltas.map {
            TranscriptSegment(
                startMs: $0.startMs,
                endMs: $0.endMs,
                speaker: $0.speaker.isEmpty ? "未标注" : $0.speaker,
                source: $0.source,
                text: $0.text
            )
        }
        let latencyMs = Int(processedAt.timeIntervalSince(startedProcessingAt) * 1000)
        let firstSegmentMs = firstSegmentMs(context: context, processedAt: processedAt)
        let shouldRefresh = coordinator.registerIngested(ingested, now: processedAt)

        guard shouldRefresh else {
            return outcome(
                context: context,
                chunkIndex: chunkIndex,
                latencyMs: latencyMs,
                ingested: ingested,
                transcriptSegments: transcriptSegments,
                processedAt: processedAt,
                firstSegmentMs: firstSegmentMs,
                refresh: .none
            )
        }

        if context.isInsightRefreshSuspended {
            return outcome(
                context: context,
                chunkIndex: chunkIndex,
                latencyMs: latencyMs,
                ingested: ingested,
                transcriptSegments: transcriptSegments,
                processedAt: processedAt,
                firstSegmentMs: firstSegmentMs,
                refresh: .paused(.alreadySuspended),
                providerMetric: "analysis-paused"
            )
        }

        do {
            let analysisStartedAt = clock()
            let result = try runtime.refreshLiveInsight(meetingID: context.meetingID, windowSec: 120)
            let analysisLatencyMs = max(0, Int(clock().timeIntervalSince(analysisStartedAt) * 1_000))
            coordinator.markRefreshed(at: processedAt)
            return outcome(
                context: context,
                chunkIndex: chunkIndex,
                latencyMs: latencyMs,
                ingested: ingested,
                transcriptSegments: transcriptSegments,
                processedAt: processedAt,
                firstSegmentMs: firstSegmentMs,
                refresh: .success(result),
                analysisLatencyMs: analysisLatencyMs
            )
        } catch {
            if errorClassifier.isProviderAuthFailure(error) {
                coordinator.markRefreshed(at: processedAt)
                return outcome(
                    context: context,
                    chunkIndex: chunkIndex,
                    latencyMs: latencyMs,
                    ingested: ingested,
                    transcriptSegments: transcriptSegments,
                    processedAt: processedAt,
                    firstSegmentMs: firstSegmentMs,
                    refresh: .paused(.authFailed),
                    providerMetric: "analysis-paused",
                    analysisRuntimeState: .pausedAuthFailed,
                    errorMessage: "智能分析服务鉴权失败，转写继续、洞察已暂停。请打开设置修复 API 配置后重新开始直播洞察。"
                )
            }
            if errorClassifier.isProviderProbeTimeout(error) {
                coordinator.markRefreshed(at: processedAt)
                return outcome(
                    context: context,
                    chunkIndex: chunkIndex,
                    latencyMs: latencyMs,
                    ingested: ingested,
                    transcriptSegments: transcriptSegments,
                    processedAt: processedAt,
                    firstSegmentMs: firstSegmentMs,
                    refresh: .paused(.timeout),
                    providerMetric: "analysis-paused",
                    analysisRuntimeState: .pausedTimeout,
                    errorMessage: "智能分析探测超时，转写继续、洞察已暂停。请稍后重试或检查网络。"
                )
            }
            if errorClassifier.isLiveRefreshTimeout(error) {
                coordinator.markRefreshed(at: processedAt)
                return outcome(
                    context: context,
                    chunkIndex: chunkIndex,
                    latencyMs: latencyMs,
                    ingested: ingested,
                    transcriptSegments: transcriptSegments,
                    processedAt: processedAt,
                    firstSegmentMs: firstSegmentMs,
                    refresh: .paused(.timeout),
                    providerMetric: "analysis-refresh-timeout",
                    analysisRuntimeState: .ready,
                    errorMessage: nil
                )
            }
            if errorClassifier.isProviderInvalidResponse(error) {
                coordinator.markRefreshed(at: processedAt)
                return outcome(
                    context: context,
                    chunkIndex: chunkIndex,
                    latencyMs: latencyMs,
                    ingested: ingested,
                    transcriptSegments: transcriptSegments,
                    processedAt: processedAt,
                    firstSegmentMs: firstSegmentMs,
                    refresh: .paused(.invalidProviderResponse),
                    providerMetric: "analysis-invalid-response",
                    analysisRuntimeState: .pausedInvalidResponse,
                    errorMessage: AnalysisProviderErrorPresentation.invalidResponseMessage
                )
            }
            throw error
        }
    }

    private func captureState(context: LiveTranscriptPipelineContext, hasNewTranscript: Bool) -> CaptureState {
        LiveCaptureStateMapper.captureState(
            warmReady: context.warmReady,
            hasTranscript: context.hasTranscript || hasNewTranscript
        )
    }

    private func firstSegmentMs(context: LiveTranscriptPipelineContext, processedAt: Date) -> Int? {
        guard !context.hasTranscript, let sessionStartedAt = context.sessionStartedAt else {
            return nil
        }
        return max(1, Int(processedAt.timeIntervalSince(sessionStartedAt) * 1000))
    }

    private func outcome(
        context: LiveTranscriptPipelineContext,
        chunkIndex: Int,
        latencyMs: Int,
        ingested: Int,
        transcriptSegments: [TranscriptSegment],
        processedAt: Date,
        firstSegmentMs: Int?,
        refresh: LiveTranscriptPipelineRefresh,
        analysisLatencyMs: Int? = nil,
        providerMetric: String? = nil,
        analysisRuntimeState: AnalysisRuntimeState? = nil,
        errorMessage: String? = nil
    ) -> LiveTranscriptPipelineOutcome {
        LiveTranscriptPipelineOutcome(
            chunkIndex: chunkIndex,
            latencyMs: latencyMs,
            analysisLatencyMs: analysisLatencyMs,
            ingestedCount: ingested,
            transcriptSegments: transcriptSegments,
            captureState: captureState(context: context, hasNewTranscript: !transcriptSegments.isEmpty),
            firstSegmentMs: firstSegmentMs,
            lastTranscriptAt: processedAt,
            refresh: refresh,
            providerMetric: providerMetric,
            analysisRuntimeState: analysisRuntimeState,
            errorMessage: errorMessage
        )
    }

    private func deduplicate(_ segments: [RPCSegmentDelta]) -> [RPCSegmentDelta] {
        var result: [RPCSegmentDelta] = []

        for segment in segments {
            let normalizedText = segment.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if normalizedText.isEmpty {
                continue
            }
            let key = "\(segment.startMs / 500)-\(normalizedText)"
            if recentFingerprints.contains(key) {
                continue
            }
            recentFingerprints.append(key)
            if recentFingerprints.count > 40 {
                recentFingerprints.removeFirst(recentFingerprints.count - 40)
            }
            result.append(segment)
        }

        return result
    }
}
