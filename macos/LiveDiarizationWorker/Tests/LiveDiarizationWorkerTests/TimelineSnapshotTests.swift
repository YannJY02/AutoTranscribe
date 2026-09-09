import FluidAudio
import LiveDiarizationCore
import XCTest
@testable import LiveDiarizationWorker

final class TimelineSnapshotTests: XCTestCase {
    func testStableOpenSpeechRemainsVisibleBeforeAndAfterSegmentClosure() throws {
        let timeline = DiarizerTimeline(config: .default(numSpeakers: 1, frameDurationSeconds: 0.1))
        for expectedEnd in [12_500, 25_000] {
            _ = try timeline.addPredictions(
                finalizedPredictions: Array(repeating: 0.9, count: 125), tentativePredictions: []
            )
            XCTAssertTrue(timeline.speakers.values.allSatisfy { $0.finalizedSegments.isEmpty })
            let snapshot = LocalLSEENDEngine.snapshot(timeline: timeline)
            XCTAssertEqual(snapshot.finalizedUntilMS, expectedEnd)
            XCTAssertEqual(snapshot.spans, [SpeakerSpan(startMS: 0, endMS: expectedEnd, speaker: "SPEAKER_00")])
        }
        _ = try timeline.addPredictions(finalizedPredictions: [0], tentativePredictions: [])
        let closed = LocalLSEENDEngine.snapshot(timeline: timeline)
        XCTAssertEqual(closed.finalizedUntilMS, 25_100)
        XCTAssertEqual(closed.spans, [SpeakerSpan(startMS: 0, endMS: 25_000, speaker: "SPEAKER_00")])
    }

    func testUnstableRightContextIsExcludedFromOpenSpeech() throws {
        let timeline = DiarizerTimeline(config: .default(numSpeakers: 1, frameDurationSeconds: 0.1))
        _ = try timeline.addPredictions(
            finalizedPredictions: Array(repeating: 0.9, count: 10),
            tentativePredictions: Array(repeating: 0.9, count: 5)
        )
        let snapshot = LocalLSEENDEngine.snapshot(timeline: timeline)
        XCTAssertEqual(snapshot.finalizedUntilMS, 1_000)
        XCTAssertEqual(snapshot.spans, [SpeakerSpan(startMS: 0, endMS: 1_000, speaker: "SPEAKER_00")])

        let previewOnly = DiarizerTimeline(config: .default(numSpeakers: 1, frameDurationSeconds: 0.1))
        _ = try previewOnly.addPredictions(finalizedPredictions: [], tentativePredictions: Array(repeating: 0.9, count: 5))
        let preview = LocalLSEENDEngine.snapshot(timeline: previewOnly)
        XCTAssertEqual(preview.finalizedUntilMS, 0)
        XCTAssertTrue(preview.spans.isEmpty)
    }
}
