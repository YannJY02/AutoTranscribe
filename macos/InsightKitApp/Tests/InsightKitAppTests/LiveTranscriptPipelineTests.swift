import Foundation
import XCTest
@testable import InsightKitApp

final class LiveTranscriptPipelineTests: XCTestCase {
    func testEmptyASROutputReturnsNoSegmentsAndCapturingState() throws {
        let runtime = LiveTranscriptPipelineRuntimeMock()
        runtime.transcribeResult = []
        let pipeline = LiveTranscriptPipeline(runtime: runtime, clock: fixedClock())

        let outcome = try pipeline.process(
            chunk: makeChunk(index: 0),
            context: makeContext(warmReady: true, hasTranscript: false)
        )

        XCTAssertEqual(runtime.transcribeCalls.count, 1)
        XCTAssertTrue(runtime.transcriptDeltaCalls.isEmpty)
        XCTAssertTrue(runtime.refreshCalls.isEmpty)
        XCTAssertTrue(outcome.transcriptSegments.isEmpty)
        XCTAssertEqual(outcome.captureState, .capturing)
        XCTAssertEqual(outcome.chunkIndex, 1)
        XCTAssertEqual(outcome.ingestedCount, 0)
    }

    func testSuccessfulChunkIngestionCanReturnWithoutRefresh() throws {
        let runtime = LiveTranscriptPipelineRuntimeMock()
        runtime.transcribeResult = [makeDelta(text: "First live transcript delta.")]
        runtime.transcriptDeltaResult = 1
        var coordinator = LiveInsightCoordinator(minRefreshInterval: 15, minSegmentsBeforeRefresh: 2)
        coordinator.markRefreshed(at: Date(timeIntervalSince1970: 1_000))
        let pipeline = LiveTranscriptPipeline(runtime: runtime, coordinator: coordinator, clock: fixedClock(1_003))

        let outcome = try pipeline.process(
            chunk: makeChunk(index: 2),
            context: makeContext(startedAt: Date(timeIntervalSince1970: 1_000), warmReady: true, hasTranscript: false)
        )

        XCTAssertEqual(runtime.transcriptDeltaCalls.count, 1)
        XCTAssertTrue(runtime.refreshCalls.isEmpty)
        XCTAssertEqual(outcome.transcriptSegments.map(\.text), ["First live transcript delta."])
        XCTAssertEqual(outcome.captureState, .transcribing)
        XCTAssertEqual(outcome.chunkIndex, 3)
        XCTAssertEqual(outcome.firstSegmentMs, 3_000)
        guard case .none = outcome.refresh else {
            return XCTFail("Expected no refresh")
        }
    }

    func testRefreshNeededReturnsRefreshResult() throws {
        let runtime = LiveTranscriptPipelineRuntimeMock()
        runtime.transcribeResult = [makeDelta(text: "Refresh this live transcript delta.")]
        runtime.transcriptDeltaResult = 1
        runtime.refreshResult = makeRefreshResult(provider: "openai:gpt-4o-mini")
        let pipeline = LiveTranscriptPipeline(
            runtime: runtime,
            clock: sequenceClock([1_000, 1_000.2, 1_000.3, 1_002.8])
        )

        let outcome = try pipeline.process(
            chunk: makeChunk(index: 0),
            context: makeContext(warmReady: true, hasTranscript: true)
        )

        XCTAssertEqual(runtime.refreshCalls.map(\.meetingID), ["meeting-1"])
        XCTAssertEqual(runtime.refreshCalls.map(\.windowSec), [120])
        guard case .success(let result) = outcome.refresh else {
            return XCTFail("Expected refresh success")
        }
        XCTAssertEqual(result.provider, "openai:gpt-4o-mini")
        XCTAssertEqual(outcome.analysisLatencyMs, 2_500)
        XCTAssertNil(outcome.analysisRuntimeState)
    }

    func testRefreshPausedDoesNotCallRuntimeRefresh() throws {
        let runtime = LiveTranscriptPipelineRuntimeMock()
        runtime.transcribeResult = [makeDelta(text: "Keep transcription moving.")]
        runtime.transcriptDeltaResult = 1
        let pipeline = LiveTranscriptPipeline(runtime: runtime, clock: fixedClock())

        let outcome = try pipeline.process(
            chunk: makeChunk(index: 1),
            context: makeContext(warmReady: true, hasTranscript: true, isInsightRefreshSuspended: true)
        )

        XCTAssertTrue(runtime.refreshCalls.isEmpty)
        XCTAssertEqual(outcome.providerMetric, "analysis-paused")
        guard case .paused(.alreadySuspended) = outcome.refresh else {
            return XCTFail("Expected already-suspended refresh pause")
        }
    }

    func testProviderAuthFailureDegradesInsightRefreshWhileKeepingTranscript() throws {
        let runtime = LiveTranscriptPipelineRuntimeMock()
        runtime.transcribeResult = [makeDelta(text: "Transcript survives auth failure.")]
        runtime.transcriptDeltaResult = 1
        runtime.refreshError = NSError(
            domain: "InsightKitTests",
            code: 401,
            userInfo: [NSLocalizedDescriptionKey: "HTTP 401 authentication fails"]
        )
        let pipeline = LiveTranscriptPipeline(
            runtime: runtime,
            errorClassifier: LiveTranscriptPipelineErrorClassifier(
                isProviderAuthFailure: { _ in true },
                isProviderProbeTimeout: { _ in false }
            ),
            clock: fixedClock()
        )

        let outcome = try pipeline.process(
            chunk: makeChunk(index: 0),
            context: makeContext(warmReady: true, hasTranscript: true)
        )

        XCTAssertEqual(outcome.transcriptSegments.map(\.text), ["Transcript survives auth failure."])
        XCTAssertEqual(runtime.refreshCalls.count, 1)
        XCTAssertEqual(outcome.providerMetric, "analysis-paused")
        XCTAssertEqual(outcome.analysisRuntimeState, .pausedAuthFailed)
        XCTAssertTrue(outcome.errorMessage?.contains("鉴权失败") == true)
        guard case .paused(.authFailed) = outcome.refresh else {
            return XCTFail("Expected auth failure pause")
        }
    }

    func testProviderProbeTimeoutDegradesInsightRefreshWhileKeepingTranscript() throws {
        let runtime = LiveTranscriptPipelineRuntimeMock()
        runtime.transcribeResult = [makeDelta(text: "Transcript survives provider timeout.")]
        runtime.transcriptDeltaResult = 1
        runtime.refreshError = NSError(
            domain: "InsightKitTests",
            code: 408,
            userInfo: [NSLocalizedDescriptionKey: "probe_timeout"]
        )
        let pipeline = LiveTranscriptPipeline(
            runtime: runtime,
            errorClassifier: LiveTranscriptPipelineErrorClassifier(
                isProviderAuthFailure: { _ in false },
                isProviderProbeTimeout: { _ in true }
            ),
            clock: fixedClock()
        )

        let outcome = try pipeline.process(
            chunk: makeChunk(index: 0),
            context: makeContext(warmReady: true, hasTranscript: true)
        )

        XCTAssertEqual(outcome.transcriptSegments.map(\.text), ["Transcript survives provider timeout."])
        XCTAssertEqual(runtime.refreshCalls.count, 1)
        XCTAssertEqual(outcome.providerMetric, "analysis-paused")
        XCTAssertEqual(outcome.analysisRuntimeState, .pausedTimeout)
        XCTAssertTrue(outcome.errorMessage?.contains("探测超时") == true)
        guard case .paused(.timeout) = outcome.refresh else {
            return XCTFail("Expected timeout pause")
        }
    }

    func testLiveRefreshTimeoutDegradesWithoutThrowingWhileKeepingTranscript() throws {
        let runtime = LiveTranscriptPipelineRuntimeMock()
        runtime.transcribeResult = [makeDelta(text: "Transcript survives live refresh timeout.")]
        runtime.transcriptDeltaResult = 1
        runtime.refreshError = NSError(
            domain: "InsightKitTests",
            code: 408,
            userInfo: [NSLocalizedDescriptionKey: "调用超时: insight.refresh_live"]
        )
        let pipeline = LiveTranscriptPipeline(runtime: runtime, clock: fixedClock())

        let outcome = try pipeline.process(
            chunk: makeChunk(index: 0),
            context: makeContext(warmReady: true, hasTranscript: true)
        )

        XCTAssertEqual(outcome.transcriptSegments.map(\.text), ["Transcript survives live refresh timeout."])
        XCTAssertEqual(runtime.refreshCalls.count, 1)
        XCTAssertEqual(outcome.providerMetric, "analysis-refresh-timeout")
        XCTAssertEqual(outcome.analysisRuntimeState, .ready)
        XCTAssertNil(outcome.errorMessage)
        XCTAssertEqual(outcome.captureState, .transcribing)
        guard case .paused(.timeout) = outcome.refresh else {
            return XCTFail("Expected recoverable timeout pause")
        }
    }

    func testProviderNonJSONPayloadDegradesWithSanitizedMessageWhileKeepingTranscript() throws {
        let runtime = LiveTranscriptPipelineRuntimeMock()
        runtime.transcribeResult = [makeDelta(text: "Transcript survives invalid provider response.")]
        runtime.transcriptDeltaResult = 1
        runtime.refreshError = NSError(
            domain: "InsightKitTests",
            code: -10,
            userInfo: [
                NSLocalizedDescriptionKey: "Insight 侧车错误: provider returned non-JSON payload: Expecting ',' delimiter: line 42 column 32 (char 1169)"
            ]
        )
        let pipeline = LiveTranscriptPipeline(runtime: runtime, clock: fixedClock())

        let outcome = try pipeline.process(
            chunk: makeChunk(index: 0),
            context: makeContext(warmReady: true, hasTranscript: true)
        )

        XCTAssertEqual(outcome.transcriptSegments.map(\.text), ["Transcript survives invalid provider response."])
        XCTAssertEqual(runtime.refreshCalls.count, 1)
        XCTAssertEqual(outcome.providerMetric, "analysis-invalid-response")
        XCTAssertTrue(outcome.errorMessage?.contains("分析服务返回格式异常") == true)
        XCTAssertFalse(outcome.errorMessage?.contains("line 42") == true)
        XCTAssertFalse(outcome.errorMessage?.contains("char 1169") == true)
        XCTAssertEqual(outcome.captureState, .transcribing)
        guard case .paused = outcome.refresh else {
            return XCTFail("Expected invalid provider response pause")
        }
    }
}

private final class LiveTranscriptPipelineRuntimeMock: LiveTranscriptPipelineRuntime {
    var transcribeResult: [RPCSegmentDelta] = []
    var transcriptDeltaResult = 0
    var refreshResult = makeRefreshResult()
    var refreshError: Error?

    private(set) var transcribeCalls: [(chunk: AudioChunk, source: String)] = []
    private(set) var transcriptDeltaCalls: [(meetingID: String, segments: [RPCSegmentDelta])] = []
    private(set) var refreshCalls: [(meetingID: String, windowSec: Int)] = []

    func transcribe(chunk: AudioChunk, source: String) throws -> [RPCSegmentDelta] {
        transcribeCalls.append((chunk: chunk, source: source))
        return transcribeResult
    }

    func appendTranscriptDelta(meetingID: String, segments: [RPCSegmentDelta]) throws -> Int {
        transcriptDeltaCalls.append((meetingID: meetingID, segments: segments))
        return transcriptDeltaResult
    }

    func refreshLiveInsight(meetingID: String, windowSec: Int) throws -> InsightRefreshResult {
        refreshCalls.append((meetingID: meetingID, windowSec: windowSec))
        if let refreshError {
            throw refreshError
        }
        return refreshResult
    }
}

private func makeContext(
    startedAt: Date = Date(timeIntervalSince1970: 1_000),
    warmReady: Bool,
    hasTranscript: Bool,
    isInsightRefreshSuspended: Bool = false
) -> LiveTranscriptPipelineContext {
    LiveTranscriptPipelineContext(
        meetingID: "meeting-1",
        source: "mic",
        sessionStartedAt: startedAt,
        warmReady: warmReady,
        hasTranscript: hasTranscript,
        isInsightRefreshSuspended: isInsightRefreshSuspended
    )
}

private func makeChunk(index: Int) -> AudioChunk {
    AudioChunk(
        index: index,
        url: URL(fileURLWithPath: "/tmp/chunk-\(index).wav"),
        startMs: index * 1_000,
        endMs: (index + 1) * 1_000,
        rms: 0.2
    )
}

private func makeDelta(
    text: String,
    startMs: Int = 0,
    endMs: Int = 1_000,
    speaker: String = "",
    source: String = "mic"
) -> RPCSegmentDelta {
    RPCSegmentDelta(
        startMs: startMs,
        endMs: endMs,
        speaker: speaker,
        text: text,
        confidence: 0.9,
        source: source
    )
}

private func fixedClock(_ timestamp: TimeInterval = 1_001) -> () -> Date {
    { Date(timeIntervalSince1970: timestamp) }
}

private func sequenceClock(_ timestamps: [TimeInterval]) -> () -> Date {
    var values = timestamps.makeIterator()
    return {
        Date(timeIntervalSince1970: values.next()!)
    }
}

private func makeRefreshResult(provider: String = "openai:gpt-4o-mini") -> InsightRefreshResult {
    InsightRefreshResult(
        package: InsightPackageV1(
            sessionOverview: .init(title: "Live", overview: "Live transcript insight.", topics: ["Live"]),
            highlightInsights: [],
            speakerPerspectives: [],
            decisionLedger: [],
            actionTracks: [],
            timelineBeats: [],
            provenanceLinks: []
        ),
        updatedAt: Date(timeIntervalSince1970: 1_001),
        provider: provider,
        needsReviewCount: 0
    )
}
