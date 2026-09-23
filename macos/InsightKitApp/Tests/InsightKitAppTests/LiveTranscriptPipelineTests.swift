import Foundation
import XCTest
@testable import InsightKitApp

final class LiveTranscriptPipelineTests: XCTestCase {
    func testTranscriptReturnsBeforeSlowSummaryCompletes() throws {
        let runtime = LiveTranscriptPipelineRuntimeMock()
        runtime.transcribeResult = [makeDelta(text: "Show this before the summary.")]
        runtime.transcriptDeltaResult = 1
        runtime.refreshDelaySec = 0.4
        let pipeline = LiveTranscriptPipeline(runtime: runtime)
        let started = ProcessInfo.processInfo.systemUptime

        let outcome = try pipeline.process(
            chunk: makeChunk(index: 0),
            context: makeContext(warmReady: true, hasTranscript: false)
        )

        XCTAssertEqual(outcome.transcriptSegments.map(\.text), ["Show this before the summary."])
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.2,
                          "A slow analysis provider must not hold the transcript result.")
    }

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

    func testRefreshNeededReturnsRequestWithoutCallingProvider() throws {
        let runtime = LiveTranscriptPipelineRuntimeMock()
        runtime.transcribeResult = [makeDelta(text: "Refresh this live transcript delta.")]
        runtime.transcriptDeltaResult = 1
        let pipeline = LiveTranscriptPipeline(runtime: runtime, clock: fixedClock())

        let outcome = try pipeline.process(
            chunk: makeChunk(index: 0),
            context: makeContext(warmReady: true, hasTranscript: true)
        )

        XCTAssertTrue(runtime.refreshCalls.isEmpty)
        guard case .requested = outcome.refresh else { return XCTFail("Expected a background refresh request") }
        XCTAssertNil(outcome.analysisLatencyMs)
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

}

final class LiveInsightRefreshOutcomeTests: XCTestCase {
    func testProviderAuthFailurePausesOnlyAnalysis() {
        let result = failure("HTTP 401 authentication fails")
        XCTAssertNil(result.result)
        XCTAssertTrue(result.shouldSuspend)
        XCTAssertEqual(result.runtimeState, .pausedAuthFailed)
        XCTAssertTrue(result.errorMessage?.contains("鉴权失败") == true)
    }

    func testProviderProbeTimeoutPausesOnlyAnalysis() {
        let result = failure("probe_timeout")
        XCTAssertTrue(result.shouldSuspend)
        XCTAssertEqual(result.runtimeState, .pausedTimeout)
    }

    func testLiveTimeoutAndBusyRemainRecoverable() {
        for message in ["调用超时: insight.refresh_live", "live_insight_busy"] {
            let result = failure(message)
            XCTAssertFalse(result.shouldSuspend)
            XCTAssertEqual(result.runtimeState, .ready)
            XCTAssertNotNil(result.statusMessage)
            XCTAssertNil(result.errorMessage)
        }
    }

    func testInvalidProviderResponseHasSanitizedError() {
        let result = failure("provider returned non-JSON payload: private provider response")
        XCTAssertTrue(result.shouldSuspend)
        XCTAssertEqual(result.runtimeState, .pausedInvalidResponse)
        XCTAssertEqual(result.errorMessage, AnalysisProviderErrorPresentation.invalidResponseMessage)
        XCTAssertFalse(result.errorMessage?.contains("private provider") ?? true)
    }

    private func failure(_ message: String) -> LiveInsightRefreshOutcome {
        let client = RPCClientMock()
        client.refreshLiveHandler = { _, _ in
            throw NSError(domain: "InsightKitTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return LiveInsightRefreshOutcome.run(client: client, meetingID: "meeting-1")
    }
}

private final class LiveTranscriptPipelineRuntimeMock: LiveTranscriptPipelineRuntime {
    var transcribeResult: [RPCSegmentDelta] = []
    var transcriptDeltaResult = 0
    var refreshResult = makeRefreshResult()
    var refreshError: Error?
    var refreshDelaySec: TimeInterval = 0

    private(set) var transcribeCalls: [(chunk: AudioChunk, source: String)] = []
    private(set) var transcriptDeltaCalls: [(meetingID: String, segments: [RPCSegmentDelta])] = []
    private(set) var refreshCalls: [(meetingID: String, windowSec: Int)] = []

    func transcribe(chunk: AudioChunk, meetingID: String, source: String) throws -> [RPCSegmentDelta] {
        transcribeCalls.append((chunk: chunk, source: source))
        return transcribeResult
    }

    func appendTranscriptDelta(meetingID: String, segments: [RPCSegmentDelta]) throws -> Int {
        transcriptDeltaCalls.append((meetingID: meetingID, segments: segments))
        return transcriptDeltaResult
    }

    func refreshLiveInsight(meetingID: String, windowSec: Int) throws -> InsightRefreshResult {
        refreshCalls.append((meetingID: meetingID, windowSec: windowSec))
        if refreshDelaySec > 0 { Thread.sleep(forTimeInterval: refreshDelaySec) }
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
