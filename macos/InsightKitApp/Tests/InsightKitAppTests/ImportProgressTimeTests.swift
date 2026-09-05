import Combine
import XCTest
@testable import InsightKitApp

final class ImportProgressTimeTests: XCTestCase {
    private var subscriptions = Set<AnyCancellable>()

    override func tearDown() {
        subscriptions.removeAll()
        super.tearDown()
    }

    func testElapsedCanExceedMediaDurationWithoutBecomingTranscriptPosition() {
        let view = TranscriptionProgressView(progress: 0.82, elapsedTime: 361, sourceMediaDuration: 300)
        XCTAssertEqual(view.elapsedTimeText, "已用时 6:01")
        XCTAssertEqual(view.mediaDurationText, "媒体时长 5:00")
    }

    func testMediaDurationRoundsFractionalSecondsWithoutRoundingElapsed() {
        let view = TranscriptionProgressView(progress: 0.82, elapsedTime: 299.932, sourceMediaDuration: 299.932)
        XCTAssertEqual(view.elapsedTimeText, "已用时 4:59")
        XCTAssertEqual(view.mediaDurationText, "媒体时长 5:00")
    }

    func testMediaDurationRoundsAcrossMinuteBoundary() {
        for (seconds, elapsed, media) in [
            (59.49, "0:59", "0:59"),
            (59.5, "0:59", "1:00"),
            (60.001, "1:00", "1:00"),
        ] {
            let view = TranscriptionProgressView(progress: 0, elapsedTime: seconds, sourceMediaDuration: seconds)
            XCTAssertEqual(view.elapsedTimeText, "已用时 \(elapsed)", "seconds=\(seconds)")
            XCTAssertEqual(view.mediaDurationText, "媒体时长 \(media)", "seconds=\(seconds)")
        }
    }

    func testUnknownAndInvalidDurationAreExplicitlyUnknown() {
        for duration: Double? in [nil, 0, -1, .nan, .infinity, -.infinity] {
            let view = TranscriptionProgressView(progress: 0, elapsedTime: 0, sourceMediaDuration: duration)
            XCTAssertEqual(view.elapsedTimeText, "已用时 0:00")
            XCTAssertEqual(view.mediaDurationText, "媒体时长 未知")
        }
    }

    func testProbeDoesNotBlockSubmissionAndPublishesWhileProcessing() {
        let inspector = ControlledImportMediaInspector()
        let queue = DispatchQueue(label: "ImportProgressTimeTests.probe")
        let model = makeModel(inspector: inspector, queue: queue)
        defer { model.shutdown() }
        let submitted = expectation(description: "import submitted while probe is blocked")
        model.$currentJobID.compactMap { $0 }.prefix(1).sink { _ in submitted.fulfill() }
            .store(in: &subscriptions)

        model.importFile(url: mediaURL("first"))
        XCTAssertNil(model.sourceMediaDuration)
        wait(for: [inspector.started, submitted], timeout: 2)
        XCTAssertEqual(model.sessionPhase, .processing)
        XCTAssertNil(model.sourceMediaDuration)
        inspector.release(with: 300)
        drain(queue)

        XCTAssertEqual(model.sourceMediaDuration, 300)
        XCTAssertEqual(model.recordingDuration, 0)
        XCTAssertEqual(model.sessionPhase, .processing)
    }

    func testFailedAndInvalidProbesRemainUnknown() {
        for duration: Double? in [nil, 0, -1, .nan, .infinity, -.infinity] {
            let inspector = ControlledImportMediaInspector()
            let queue = DispatchQueue(label: "ImportProgressTimeTests.invalid")
            let model = makeModel(inspector: inspector, queue: queue)
            model.importFile(url: mediaURL("invalid"))
            wait(for: [inspector.started], timeout: 2)
            inspector.release(with: duration)
            drain(queue)
            XCTAssertNil(model.sourceMediaDuration)
            XCTAssertEqual(model.recordingDuration, 0)
            model.shutdown()
        }
    }

    func testResetDiscardsPendingProbe() {
        assertPendingProbeIsDiscarded { $0.resetToSelecting() }
    }

    func testCancelDiscardsPendingProbe() {
        let inspector = ControlledImportMediaInspector()
        let queue = DispatchQueue(label: "ImportProgressTimeTests.cancel")
        let model = makeModel(inspector: inspector, queue: queue)
        defer { model.shutdown() }
        let submitted = expectation(description: "import submitted")
        model.$currentJobID.compactMap { $0 }.prefix(1).sink { _ in submitted.fulfill() }
            .store(in: &subscriptions)
        model.importFile(url: mediaURL("cancel"))
        wait(for: [inspector.started, submitted], timeout: 2)

        let cancelled = expectation(description: "cancellation confirmed")
        model.$sessionPhase.filter { $0 == .selecting }.prefix(1)
            .sink { _ in cancelled.fulfill() }.store(in: &subscriptions)
        model.cancelImport()
        wait(for: [cancelled], timeout: 2)
        inspector.release(with: 300)
        drain(queue)
        XCTAssertNil(model.sourceMediaDuration)
    }

    func testFailedCancellationPreservesKnownAndPendingSourceDuration() {
        for completeProbeBeforeCancel in [true, false] {
            let inspector = ControlledImportMediaInspector()
            let queue = DispatchQueue(label: "ImportProgressTimeTests.cancelFailure")
            let rpcClient = RPCClientMock()
            rpcClient.transcriptionCancelError = NSError(domain: "ImportProgressTimeTests", code: 1)
            let model = makeModel(inspector: inspector, queue: queue, rpcClient: rpcClient)
            let submitted = expectation(description: "import submitted")
            model.$currentJobID.compactMap { $0 }.prefix(1).sink { _ in submitted.fulfill() }
                .store(in: &subscriptions)
            model.importFile(url: mediaURL("cancel-failure"))
            wait(for: [inspector.started, submitted], timeout: 2)
            if completeProbeBeforeCancel {
                inspector.release(with: 300)
                drain(queue)
                XCTAssertEqual(model.sourceMediaDuration, 300)
            }

            let failed = expectation(description: "cancellation failed")
            model.$importStatusMessage.filter { $0 == "取消失败，转写任务可能仍在运行。" }.prefix(1)
                .sink { _ in failed.fulfill() }.store(in: &subscriptions)
            model.cancelImport()
            wait(for: [failed], timeout: 2)
            if !completeProbeBeforeCancel {
                inspector.release(with: 300)
                drain(queue)
            }

            XCTAssertEqual(model.sessionPhase, .processing)
            XCTAssertEqual(model.sourceMediaDuration, 300)
            model.shutdown()
        }
    }

    func testReplacementImportDiscardsOldProbeEvenForSameFile() {
        for replacement in ["first", "second"] {
            let inspector = ControlledImportMediaInspector()
            let queue = DispatchQueue(label: "ImportProgressTimeTests.replace", attributes: .concurrent)
            let model = makeModel(inspector: inspector, queue: queue)
            model.importFile(url: mediaURL("first"))
            wait(for: [inspector.started], timeout: 2)
            model.resetToSelecting()
            model.importFile(url: mediaURL(replacement))
            let secondRead = expectation(description: "replacement duration")
            model.$sourceMediaDuration.compactMap { $0 }.filter { $0 == 120 }.prefix(1)
                .sink { _ in secondRead.fulfill() }.store(in: &subscriptions)
            wait(for: [secondRead], timeout: 2)
            inspector.release(with: 300)
            drain(queue)
            XCTAssertEqual(model.sourceMediaDuration, 120)
            model.shutdown()
        }
    }

    func testCompletedMetadataKeepsItsOwnDurationAndDoesNotSupplyUnknownSourceDuration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let record = root.appendingPathComponent("duration-record")
        try FileManager.default.createDirectory(at: record, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = RecordMetadata(
            id: "duration-record", createdAt: Date(), duration: 298, mediaType: .audio,
            source: .imported, userTags: [], autoTags: [], summaryPreview: ""
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: record.appendingPathComponent("metadata.json"))
        let suite = "ImportProgressTimeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let records = RecordsIndexService(defaults: defaults, environment: [:])
        records.rootDirectory = root

        for duration: Double? in [300, nil] {
            let inspector = ControlledImportMediaInspector()
            let queue = DispatchQueue(label: "ImportProgressTimeTests.metadata")
            let model = makeModel(inspector: inspector, queue: queue)
            model.importFile(url: mediaURL("first"))
            wait(for: [inspector.started], timeout: 2)
            inspector.release(with: duration)
            drain(queue)
            model.recordsService = records
            XCTAssertTrue(model.loadPersistedArtifactsForCompletedImport(meetingID: "duration-record"))
            XCTAssertEqual(model.recordingDuration, 298)
            XCTAssertEqual(model.sourceMediaDuration, duration)
            let view = TranscriptionProgressView(progress: 1, elapsedTime: 361, sourceMediaDuration: model.sourceMediaDuration)
            XCTAssertEqual(view.mediaDurationText, duration == nil ? "媒体时长 未知" : "媒体时长 5:00")
            model.shutdown()
        }
    }

    private func assertPendingProbeIsDiscarded(_ invalidate: (ImportSessionViewModel) -> Void) {
        let inspector = ControlledImportMediaInspector()
        let queue = DispatchQueue(label: "ImportProgressTimeTests.invalidate")
        let model = makeModel(inspector: inspector, queue: queue)
        model.importFile(url: mediaURL("first"))
        wait(for: [inspector.started], timeout: 2)
        invalidate(model)
        inspector.release(with: 300)
        drain(queue)
        XCTAssertNil(model.sourceMediaDuration)
        model.shutdown()
    }

    private func makeModel(
        inspector: MediaAssetInspecting,
        queue: DispatchQueue,
        rpcClient: RPCClientMock = RPCClientMock()
    ) -> ImportSessionViewModel {
        ImportSessionViewModel(
            rpcClient: rpcClient, mediaAssetInspector: inspector,
            sourceDurationQueue: queue, prepareRuntime: {}, analyticsSubmit: { _ in }
        )
    }

    private func mediaURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(name).m4a")
    }

    // Barrier waits for the controlled synchronous inspector to return, then the
    // main-queue marker runs after all resulting publication callbacks. No sleeps.
    private func drain(_ queue: DispatchQueue) {
        queue.sync(flags: .barrier) {}
        let delivered = expectation(description: "probe callbacks delivered")
        DispatchQueue.main.async { delivered.fulfill() }
        wait(for: [delivered], timeout: 2)
    }
}

private final class ControlledImportMediaInspector: MediaAssetInspecting {
    let started = XCTestExpectation(description: "first probe started")
    private let condition = NSCondition()
    private var calls = 0
    private var released = false
    private var result: Double?

    func hasAudioTrack(url: URL) -> Bool { true }

    func durationSec(url: URL) -> Double? {
        condition.lock()
        defer { condition.unlock() }
        calls += 1
        guard calls == 1 else { return 120 }
        started.fulfill()
        let deadline = Date().addingTimeInterval(5)
        while !released {
            guard condition.wait(until: deadline) else {
                XCTFail("Duration probe was not released before its deadline")
                return nil
            }
        }
        return result
    }

    func release(with duration: Double?) {
        condition.lock()
        result = duration
        released = true
        condition.broadcast()
        condition.unlock()
    }
}
