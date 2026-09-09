import Combine
import Foundation
import XCTest
@testable import InsightKitApp

final class BoundedLiveWorkQueueTests: XCTestCase {
    func testSpeakerQueueRunsInOrderAndRejectsOverflow() {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let values = LockedTestValue<[Int]>([])
        let finished = expectation(description: "accepted jobs finish")
        finished.expectedFulfillmentCount = 3
        let queue = BoundedLiveWorkQueue<Int, Int>(label: "test.speaker", maximumPending: 2,
            operation: { value in
                values.mutate { $0.append(value) }
                if value == 1 { started.signal(); _ = release.wait(timeout: .now() + 5) }
                return value
            }, completion: { _, _ in finished.fulfill() })

        XCTAssertTrue(queue.submit(1))
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(queue.submit(2))
        XCTAssertTrue(queue.submit(3))
        XCTAssertFalse(queue.submit(4))
        XCTAssertEqual(queue.pendingCount, 2)
        XCTAssertEqual(values.value, [1])
        release.signal()
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(values.value, [1, 2, 3])
    }

    func testSummaryQueueKeepsOnlyLatestPendingRequest() {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let values = LockedTestValue<[Int]>([])
        let finished = expectation(description: "first and latest finish")
        finished.expectedFulfillmentCount = 2
        let queue = BoundedLiveWorkQueue<Int, Int>(label: "test.summary", maximumPending: 1,
            coalescesPending: true, operation: { value in
                values.mutate { $0.append(value) }
                if value == 1 { started.signal(); _ = release.wait(timeout: .now() + 5) }
                return value
            }, completion: { _, _ in finished.fulfill() })

        queue.submit(1)
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        for value in 2...20 { XCTAssertTrue(queue.submit(value)) }
        XCTAssertEqual(queue.pendingCount, 1)
        release.signal()
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(values.value, [1, 20])
    }

    func testInvalidationDropsPendingWithoutWaitingForInFlightWork() {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let values = LockedTestValue<[Int]>([])
        let finished = expectation(description: "old in-flight and new work finish")
        finished.expectedFulfillmentCount = 2
        let queue = BoundedLiveWorkQueue<Int, Int>(label: "test.retire", maximumPending: 2,
            operation: { value in
                values.mutate { $0.append(value) }
                if value == 1 { started.signal(); _ = release.wait(timeout: .now() + 5) }
                return value
            }, completion: { _, _ in finished.fulfill() })

        queue.submit(1)
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        queue.submit(2)
        queue.invalidate()
        XCTAssertEqual(queue.pendingCount, 0)
        queue.submit(3)
        release.signal()
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(values.value, [1, 3])
    }
}

final class LiveSpeakerPatchTests: XCTestCase {
    func testShortInterruptionSplitsOnlyExactOriginalAndPreservesOverlappingRows() {
        let original = progressiveDelta("We ship Friday. No, Monday. Agreed.", start: 0, end: 3_000)
        let unrelated = TranscriptSegment(startMs: 700, endMs: 1_400, speaker: "Other",
                                          source: "system", text: "Overlapping system audio")
        let patch = LiveSpeakerUpdate(chunkID: "0", originalSegments: [original], segments: [
            progressiveDelta("We ship Friday.", start: 0, end: 1_000, speaker: "SPEAKER_00"),
            progressiveDelta("No, Monday.", start: 1_000, end: 1_500, speaker: "SPEAKER_01"),
            progressiveDelta("Agreed.", start: 1_500, end: 3_000, speaker: "SPEAKER_00"),
        ])
        let updated = LiveSpeakerPatch.apply([patch], to: [displayRow(original), unrelated])

        XCTAssertEqual(updated.count, 4)
        XCTAssertEqual(updated.first(where: { $0.text == "No, Monday." })?.speaker, "SPEAKER_01")
        XCTAssertTrue(updated.contains(where: { $0.id == unrelated.id }))
        XCTAssertFalse(updated.contains(where: { $0.text == original.text }))
        XCTAssertEqual(LiveSpeakerPatch.apply([patch], to: updated), updated, "Replayed patches must not duplicate rows")
    }

    func testMissingOneOriginalKeepsWholePatchUnchanged() {
        let first = progressiveDelta("First", start: 0, end: 1_000)
        let missing = progressiveDelta("Missing", start: 1_000, end: 2_000)
        let current = [displayRow(first)]
        let patch = LiveSpeakerUpdate(chunkID: "0", originalSegments: [first, missing], segments: [
            progressiveDelta("Replacement", start: 0, end: 2_000, speaker: "SPEAKER_01")
        ])
        XCTAssertEqual(LiveSpeakerPatch.apply([patch], to: current), current)
    }

    func testChangedTextSourceAndAmbiguousOriginalCannotDeleteRows() {
        let original = progressiveDelta("Original", start: 0, end: 1_000)
        let patch = LiveSpeakerUpdate(chunkID: "0", originalSegments: [original], segments: [
            progressiveDelta("Original", start: 0, end: 1_000, speaker: "SPEAKER_01")
        ])
        for current in [
            [displayRow(progressiveDelta("Edited", start: 0, end: 1_000))],
            [TranscriptSegment(startMs: 0, endMs: 1_000, speaker: "", source: "system", text: "Original")],
            [displayRow(original), displayRow(original)],
        ] {
            XCTAssertEqual(LiveSpeakerPatch.apply([patch], to: current), current)
        }
    }
}

@MainActor
final class LiveProgressivePipelineTests: XCTestCase {
    func testSlowSummaryDoesNotBlockLaterTranscriptOrEmptyChunkEnrichment() throws {
        let summaryStarted = expectation(description: "summary is waiting")
        let releaseSummary = DispatchSemaphore(value: 0)
        defer { releaseSummary.signal() }
        let thirdSpeaker = expectation(description: "empty chunk reaches speaker worker")
        let asr = RPCClientMock()
        asr.transcriptDeltaResult = 1
        asr.liveTranscribeHandler = { _, id, _, offset, source in
            if id == "2" { return [] }
            return [RPCSegmentDelta(startMs: offset, endMs: offset + 1_000, speaker: "", text: "Chunk \(id)", confidence: 1, source: source)]
        }
        asr.refreshLiveHandler = { _, _ in XCTFail("Summary used the transcription client"); return progressiveInsight("Wrong client") }
        let summary = RPCClientMock()
        summary.refreshLiveHandler = { _, _ in
            summaryStarted.fulfill()
            _ = releaseSummary.wait(timeout: .now() + 5)
            return progressiveInsight("Slow summary")
        }
        let speaker = RPCClientMock()
        speaker.liveEnrichHandler = { meeting, id in
            if id == "2" { thirdSpeaker.fulfill() }
            return LiveSpeakerEnrichmentResult(meetingID: meeting, updates: [], status: .pending, error: nil)
        }
        let vm = runningViewModel(asr: asr, summary: summary, speaker: speaker)
        let firstDisplayed = expectation(description: "first text appears")
        vm.pipelineQueue.async {
            _ = try? vm.processChunk(progressiveChunk(0), meetingID: "live-progressive-test")
            DispatchQueue.main.async {
                XCTAssertEqual(vm.transcriptSegments.map(\.text), ["Chunk 0"])
                firstDisplayed.fulfill()
            }
        }
        wait(for: [summaryStarted, firstDisplayed], timeout: 1)

        let nextDisplayed = expectation(description: "second text appears while summary is blocked")
        vm.pipelineQueue.async {
            _ = try? vm.processChunk(progressiveChunk(1), meetingID: "live-progressive-test")
            _ = try? vm.processChunk(progressiveChunk(2), meetingID: "live-progressive-test")
            DispatchQueue.main.async {
                XCTAssertEqual(vm.transcriptSegments.map(\.text), ["Chunk 0", "Chunk 1"])
                XCTAssertNil(vm.smartMinutesData)
                nextDisplayed.fulfill()
            }
        }
        wait(for: [nextDisplayed, thirdSpeaker], timeout: 1)
        vm.invalidateLiveBackgroundWork()
    }

    func testSpeakerOverflowIsVisibleAndDoesNotBlockTranscription() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let speaker = RPCClientMock()
        speaker.liveEnrichHandler = { meeting, id in
            if id == "0" { entered.signal(); _ = release.wait(timeout: .now() + 5) }
            return LiveSpeakerEnrichmentResult(meetingID: meeting, updates: [], status: .pending, error: nil)
        }
        let vm = runningViewModel(speaker: speaker)
        let first = expectation(description: "first silent chunk returns")
        vm.pipelineQueue.async {
            _ = try? vm.processChunk(progressiveChunk(0), meetingID: "live-progressive-test")
            first.fulfill()
        }
        wait(for: [first], timeout: 1)
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        let others = expectation(description: "all later silent chunks return")
        vm.pipelineQueue.async {
            for index in 1...9 { _ = try? vm.processChunk(progressiveChunk(index), meetingID: "live-progressive-test") }
            DispatchQueue.main.async { others.fulfill() }
        }
        wait(for: [others], timeout: 1)
        XCTAssertEqual(vm.metrics.chunkIndex, 10)
        XCTAssertEqual(vm.metrics.droppedSpeakerChunks, 1)
        XCTAssertEqual(vm.recordingStatusMessage, LiveAnalysisHealthHint.speakerBacklog)
        XCTAssertEqual(vm.liveSpeakerQueue?.pendingCount, 8)
        vm.invalidateLiveBackgroundWork()
    }

    func testQueuedOldResultsAreRejectedAfterRestartEvenWithSameMeetingID() throws {
        let vm = runningViewModel()
        let old = try XCTUnwrap(vm.stateQueue.sync { vm.liveBackgroundSession })
        let original = progressiveDelta("Old transcript", start: 0, end: 1_000)
        vm.transcriptSegments = [displayRow(original)]
        let queued = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            vm.applyLiveInsightOutcome(successOutcome("Old summary"), session: old)
            vm.applyLiveSpeakerResult(.success(speakerResult(original)), request: LiveSpeakerRequest(session: old, chunkID: "0"))
            queued.signal()
        }
        XCTAssertEqual(queued.wait(timeout: .now() + 1), .success)
        vm.beginLiveBackgroundWork(meetingID: old.meetingID)
        vm.transcriptSegments = [displayRow(progressiveDelta("New transcript", start: 0, end: 1_000))]
        vm.updateWorkbench(progressiveInsight("New summary"))
        let drained = expectation(description: "old main-queue callbacks drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
        XCTAssertEqual(vm.transcriptSegments.map(\.text), ["New transcript"])
        XCTAssertEqual(vm.workbench.sessionOverview, "New summary")
        vm.invalidateLiveBackgroundWork()
    }

    func testStopInvalidatesResultsBeforeFinalizationWork() throws {
        try withSyntheticUI {
            let vm = runningViewModel()
            let old = try XCTUnwrap(vm.stateQueue.sync { vm.liveBackgroundSession })
            vm.stopLiveSession()
            XCTAssertNil(vm.stateQueue.sync { vm.liveBackgroundSession })
            let state = vm.captureState
            vm.applyLiveInsightOutcome(successOutcome("Late summary"), session: old)
            XCTAssertNil(vm.smartMinutesData)
            XCTAssertEqual(vm.captureState, state)
        }
    }

    func testLateLiveResultsCannotOverwriteExplicitFinalMinutes() throws {
        try withSyntheticUI {
            let vm = runningViewModel()
            let old = try XCTUnwrap(vm.stateQueue.sync { vm.liveBackgroundSession })
            let original = progressiveDelta("Current transcript", start: 0, end: 1_000)
            vm.transcriptSegments = [displayRow(original)]
            vm.buildFinalInsight()
            let finalOverview = vm.workbench.sessionOverview
            vm.applyLiveInsightOutcome(successOutcome("Stale draft"), session: old)
            vm.applyLiveSpeakerResult(.success(speakerResult(original)), request: LiveSpeakerRequest(session: old, chunkID: "0"))
            XCTAssertNil(vm.stateQueue.sync { vm.liveBackgroundSession })
            XCTAssertEqual(vm.workbench.sessionOverview, finalOverview)
            XCTAssertEqual(vm.sessionPhase, .reviewing)
            XCTAssertEqual(vm.transcriptSegments.first?.speaker, "未标注")
        }
    }

    func testCurrentSummaryUpdatesOnlyAnalysisStateAndKeepsTranscriptMetrics() throws {
        let vm = runningViewModel()
        let session = try XCTUnwrap(vm.stateQueue.sync { vm.liveBackgroundSession })
        vm.metrics.chunkIndex = 12
        vm.metrics.firstSegmentMs = 123
        vm.metrics.latencyMs = 456
        vm.metrics.segmentsIngested = 30
        vm.captureState = .transcribing
        vm.applyLiveInsightOutcome(successOutcome("Current summary"), session: session)
        XCTAssertEqual(vm.workbench.sessionOverview, "Current summary")
        XCTAssertEqual(vm.metrics.chunkIndex, 12)
        XCTAssertEqual(vm.metrics.firstSegmentMs, 123)
        XCTAssertEqual(vm.metrics.latencyMs, 456)
        XCTAssertEqual(vm.metrics.segmentsIngested, 30)
        XCTAssertEqual(vm.captureState, .transcribing)
        vm.invalidateLiveBackgroundWork()
    }

    private func runningViewModel(asr: RPCClientMock = RPCClientMock(), summary: RPCClientMock = RPCClientMock(), speaker: RPCClientMock = RPCClientMock()) -> LiveSessionViewModel {
        var clients: [InsightRPCClientProtocol] = [summary, speaker]
        let vm = LiveSessionViewModel(rpcClient: asr, backgroundClientFactory: { clients.removeFirst() }, analyticsSubmit: { _ in })
        XCTAssertTrue(clients.isEmpty, "Both background workers need independently injected clients")
        vm.stateQueue.sync {
            vm._isRunningLock.lock()
            vm._isRunning = true
            vm._isRunningLock.unlock()
            vm._sessionState.activeMeetingID = "live-progressive-test"
        }
        vm.sessionHandle = SessionHandle(activeMeetingID: "live-progressive-test")
        vm.sessionPhase = .running
        vm.captureHealth.sessionStartedAt = Date()
        vm.beginLiveBackgroundWork(meetingID: "live-progressive-test")
        return vm
    }

    private func withSyntheticUI(_ body: () throws -> Void) rethrows {
        let original = ProcessInfo.processInfo.environment["INSIGHTKIT_UI_TEST_MODE"]
        setenv("INSIGHTKIT_UI_TEST_MODE", "1", 1)
        defer {
            if let original { setenv("INSIGHTKIT_UI_TEST_MODE", original, 1) }
            else { unsetenv("INSIGHTKIT_UI_TEST_MODE") }
        }
        try body()
    }
}

private final class LockedTestValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}

private func progressiveChunk(_ index: Int) -> AudioChunk {
    AudioChunk(index: index, url: URL(fileURLWithPath: "/tmp/progressive-\(index).wav"),
               startMs: index * 1_000, endMs: (index + 1) * 1_000, rms: 0.2)
}

private func progressiveDelta(_ text: String, start: Int, end: Int, speaker: String = "") -> RPCSegmentDelta {
    RPCSegmentDelta(startMs: start, endMs: end, speaker: speaker, text: text, confidence: 1, source: "mic")
}

private func displayRow(_ delta: RPCSegmentDelta) -> TranscriptSegment {
    TranscriptSegment(startMs: delta.startMs, endMs: delta.endMs,
                      speaker: delta.speaker.isEmpty ? "未标注" : delta.speaker, source: delta.source, text: delta.text)
}

private func progressiveInsight(_ overview: String) -> InsightRefreshResult {
    InsightRefreshResult(package: InsightPackageV1(
        sessionOverview: .init(title: "Test", overview: overview, topics: []),
        highlightInsights: [], speakerPerspectives: [], decisionLedger: [], actionTracks: [], timelineBeats: [], provenanceLinks: []),
        updatedAt: Date(), provider: "local", needsReviewCount: 0)
}

private func successOutcome(_ overview: String) -> LiveInsightRefreshOutcome {
    LiveInsightRefreshOutcome(result: progressiveInsight(overview), latencyMs: 200,
                              runtimeState: .ready, shouldSuspend: false, statusMessage: nil, errorMessage: nil)
}

private func speakerResult(_ original: RPCSegmentDelta) -> LiveSpeakerEnrichmentResult {
    LiveSpeakerEnrichmentResult(meetingID: "live-progressive-test", updates: [
        LiveSpeakerUpdate(chunkID: "0", originalSegments: [original], segments: [
            progressiveDelta(original.text, start: original.startMs, end: original.endMs, speaker: "SPEAKER_01")
        ])
    ], status: .updated, error: nil)
}
