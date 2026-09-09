import Foundation
import XCTest
@testable import LiveDiarizationCore

final class SessionControllerTests: XCTestCase {
    private final class Engine: DiarizationEngine {
        var samples: [Float] = []
        var blocks: [Int] = []
        var cleanupCount = 0
        var finishCount = 0
        var failAfterBlocks: Int?
        var output: DiarizationSnapshot?

        func append(_ samples: [Float]) throws {
            self.samples.append(contentsOf: samples)
            blocks.append(samples.count)
            if let failAfterBlocks, blocks.count >= failAfterBlocks {
                throw WorkerFailure("test_failure", "Inference interrupted after partial mutation")
            }
        }
        func finish() throws { finishCount += 1 }
        func snapshot() throws -> DiarizationSnapshot {
            output ?? DiarizationSnapshot(spans: [], finalizedUntilMS: max(0, samples.count / 16 - 100))
        }
        func cleanup() { cleanupCount += 1 }
    }

    private struct Audio: AudioReading {
        var count = 1_600
        var failure: WorkerFailure?
        func read(path: String, maxSamples: Int) throws -> [Float] {
            if let failure { throw failure }
            return Array(repeating: 0.5, count: count)
        }
    }

    private func request(_ id: Int64, _ action: String, session: String = "a", offset: Int? = nil) -> WorkerRequest {
        WorkerRequest(id: .integer(id), action: action, sessionID: session, wavPath: "/chunk.wav", offsetMS: offset)
    }

    func testFeedsReuseEngineAndPadGapsOnAbsoluteMediaClock() {
        let engine = Engine()
        var loads = 0
        var limits = WorkerLimits()
        limits.processingBlockSamples = 800
        let controller = SessionController(limits: limits, audioReader: Audio()) { _ in
            loads += 1
            return engine
        }
        XCTAssertTrue(controller.handle(request(1, "start")).ok)
        XCTAssertTrue(controller.handle(request(2, "feed", offset: 0)).ok)
        let response = controller.handle(request(3, "feed", offset: 150))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(response.receivedUntilMS, 250)
        XCTAssertEqual(response.finalizedUntilMS, 150)
        XCTAssertEqual(engine.blocks, [800, 800, 800, 800, 800])
        XCTAssertEqual(Array(engine.samples[1_600..<2_400]), Array(repeating: 0, count: 800))
        XCTAssertEqual(engine.samples.suffix(1_600), Array(repeating: Float(0.5), count: 1_600)[...])
        controller.close()
        XCTAssertEqual(engine.cleanupCount, 1)
    }

    func testDuplicateAndRewoundAudioDoNotMutateSession() {
        let engine = Engine()
        let controller = SessionController(audioReader: Audio()) { _ in engine }
        XCTAssertTrue(controller.handle(request(1, "start")).ok)
        XCTAssertTrue(controller.handle(request(2, "feed", offset: 0)).ok)
        XCTAssertEqual(controller.handle(request(2, "feed", offset: 100)).error?.code, "duplicate_request")
        let rewind = controller.handle(request(3, "feed", offset: 0))
        XCTAssertEqual(rewind.error?.code, "out_of_order")
        XCTAssertTrue(rewind.sessionActive)
        XCTAssertEqual(rewind.receivedUntilMS, 100)
        XCTAssertEqual(engine.samples.count, 1_600)
        XCTAssertEqual(controller.handle(request(4, "start")).error?.code, "session_exists")
        XCTAssertEqual(engine.cleanupCount, 0)
    }

    func testIntegerMillisecondOffsetsPreserveSubmillisecondSamples() {
        for sampleCount in [16_001, 16_015] {
            let engine = Engine()
            let controller = SessionController(audioReader: Audio(count: sampleCount)) { _ in engine }
            XCTAssertTrue(controller.handle(request(1, "start")).ok)
            for index in 0..<3 {
                let response = controller.handle(request(Int64(index + 2), "feed", offset: index * sampleCount / 16))
                XCTAssertTrue(response.ok)
                XCTAssertEqual(response.receivedUntilMS, (index + 1) * sampleCount / 16)
                XCTAssertEqual(engine.samples.count, (index + 1) * sampleCount)
            }
            XCTAssertTrue(engine.samples.allSatisfy { $0 == 0.5 })
            XCTAssertEqual(controller.handle(request(4, "feed", offset: 3 * sampleCount / 16)).error?.code, "duplicate_request")
        }
    }

    func testOneMillisecondOverlapIsRejectedWithoutMutation() {
        let engine = Engine()
        let controller = SessionController(audioReader: Audio(count: 16_016)) { _ in engine }
        XCTAssertTrue(controller.handle(request(1, "start")).ok)
        XCTAssertTrue(controller.handle(request(2, "feed", offset: 0)).ok)
        let response = controller.handle(request(3, "feed", offset: 1_000))
        XCTAssertEqual(response.error?.code, "out_of_order")
        XCTAssertTrue(response.sessionActive)
        XCTAssertEqual(engine.samples.count, 16_016)
        XCTAssertEqual(response.receivedUntilMS, 1_001)
    }

    func testFinishClipsPaddingAndReleasesStateBeforeNextSession() {
        let first = Engine()
        first.output = DiarizationSnapshot(
            spans: [SpeakerSpan(startMS: 0, endMS: 1_000, speaker: "SPEAKER_02")], finalizedUntilMS: 1_000
        )
        let second = Engine()
        var engines = [first, second]
        let controller = SessionController(audioReader: Audio()) { _ in engines.removeFirst() }
        XCTAssertTrue(controller.handle(request(1, "start")).ok)
        XCTAssertTrue(controller.handle(request(2, "feed")).ok)
        let finished = controller.handle(request(3, "finish"))
        XCTAssertTrue(finished.ok)
        XCTAssertFalse(finished.sessionActive)
        XCTAssertEqual(finished.spans, [SpeakerSpan(startMS: 0, endMS: 100, speaker: "SPEAKER_02")])
        XCTAssertEqual(finished.finalizedUntilMS, 100)
        XCTAssertEqual(first.finishCount, 1)
        XCTAssertEqual(first.cleanupCount, 1)
        XCTAssertEqual(controller.handle(request(4, "feed")).error?.code, "session_not_found")
        let started = controller.handle(request(5, "start", session: "b"))
        XCTAssertTrue(started.ok)
        XCTAssertTrue(started.spans.isEmpty)
        XCTAssertEqual(started.receivedUntilMS, 0)
        XCTAssertTrue(controller.handle(request(6, "reset", session: "b")).ok)
        XCTAssertEqual(second.cleanupCount, 1)
    }

    func testNewSessionReplacesAndClosesPreviousSession() {
        let first = Engine()
        let second = Engine()
        var engines = [first, second]
        let controller = SessionController(audioReader: Audio()) { _ in engines.removeFirst() }
        XCTAssertTrue(controller.handle(request(1, "start")).ok)
        XCTAssertTrue(controller.handle(request(2, "feed")).ok)
        XCTAssertTrue(controller.handle(request(3, "start", session: "b")).ok)
        XCTAssertEqual(first.cleanupCount, 1)
        XCTAssertEqual(controller.handle(request(4, "feed")).error?.code, "session_not_found")
        XCTAssertTrue(second.samples.isEmpty)
    }

    func testInvalidAudioPreservesStateAndInferenceFailureInvalidatesIt() {
        let invalidEngine = Engine()
        let invalid = SessionController(audioReader: Audio(failure: WorkerFailure("invalid_audio", "bad WAV"))) { _ in invalidEngine }
        XCTAssertTrue(invalid.handle(request(1, "start")).ok)
        let rejected = invalid.handle(request(2, "feed"))
        XCTAssertEqual(rejected.error?.code, "invalid_audio")
        XCTAssertTrue(rejected.sessionActive)
        XCTAssertTrue(invalidEngine.samples.isEmpty)
        XCTAssertEqual(invalidEngine.cleanupCount, 0)

        let engine = Engine()
        engine.failAfterBlocks = 1
        var limits = WorkerLimits()
        limits.processingBlockSamples = 800
        let controller = SessionController(limits: limits, audioReader: Audio()) { _ in engine }
        XCTAssertTrue(controller.handle(request(1, "start")).ok)
        let failed = controller.handle(request(2, "feed"))
        XCTAssertEqual(failed.error?.code, "inference_failed")
        XCTAssertFalse(failed.sessionActive)
        XCTAssertEqual(engine.cleanupCount, 1)
        XCTAssertEqual(engine.samples.count, 800)
        XCTAssertEqual(controller.handle(request(3, "feed")).error?.code, "session_not_found")
    }

    func testGapDurationAndRequestLimitsRejectBeforeMutation() {
        let engine = Engine()
        var limits = WorkerLimits()
        limits.maxSessionSamples = 3_200
        limits.maxGapSamples = 800
        limits.maxRequestsPerSession = 2
        let controller = SessionController(limits: limits, audioReader: Audio()) { _ in engine }
        XCTAssertTrue(controller.handle(request(1, "start")).ok)
        XCTAssertEqual(controller.handle(request(2, "feed", offset: 51)).error?.code, "gap_limit")
        XCTAssertEqual(controller.handle(request(2, "feed", offset: -1)).error?.code, "invalid_offset")
        XCTAssertEqual(controller.handle(request(2, "feed", offset: Int.max)).error?.code, "invalid_offset")
        XCTAssertTrue(engine.samples.isEmpty)
        XCTAssertTrue(controller.handle(request(2, "feed")).ok)
        XCTAssertEqual(controller.handle(request(3, "feed")).error?.code, "session_limit")
        XCTAssertTrue(controller.handle(request(4, "finish")).ok)
    }

    func testMalformedAndUnknownRequestsHaveMachineReadableResponses() throws {
        let controller = SessionController { _ in Engine() }
        let malformed = controller.handle(line: Data("{no}".utf8))
        XCTAssertNil(malformed.id)
        XCTAssertEqual(malformed.error?.code, "invalid_request")
        let booleanID = controller.handle(line: Data(#"{"id":true,"action":"start","session_id":"a"}"#.utf8))
        XCTAssertEqual(booleanID.error?.code, "invalid_request")
        let unknown = controller.handle(line: Data(#"{"id":"s1","action":"unknown","session_id":"a"}"#.utf8))
        XCTAssertEqual(unknown.id, .string("s1"))
        XCTAssertEqual(unknown.error?.code, "unsupported_action")
        let encoded = try JSONEncoder().encode(malformed)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertTrue(json["id"] is NSNull)
        XCTAssertEqual(json["spans_mode"] as? String, "cumulative")
        XCTAssertEqual(json["session_active"] as? Bool, false)
    }

    func testOversizedJSONLineIsDiscardedAndFollowingRequestSurvives() {
        var framer = JSONLineFramer(maxBytes: 4)
        XCTAssertTrue(framer.append(Data("123".utf8)).isEmpty)
        XCTAssertEqual(framer.append(Data("45".utf8)), [.oversized])
        XCTAssertEqual(framer.append(Data("678\nok\n".utf8)), [.line(Data("ok".utf8))])
        XCTAssertTrue(framer.append(Data("last".utf8)).isEmpty)
        XCTAssertEqual(framer.finish(), [.line(Data("last".utf8))])
        XCTAssertTrue(framer.finish().isEmpty)
    }
}
