import XCTest
@testable import InsightKitApp

final class LiveMediaCaptureTimelineTests: XCTestCase {
    func testCompositionTimelineExcludesPausedWallClockBeforeAudioStarts() {
        var timeline = LiveMediaCaptureTimeline()

        timeline.markVideoStart(at: 100)
        timeline.markPauseStart(at: 102)
        timeline.markPauseEnd(at: 112)
        timeline.markAudioStartIfNeeded(at: 115)

        XCTAssertEqual(timeline.compositionTimeline.videoStartSec, 0, accuracy: 0.001)
        XCTAssertEqual(timeline.compositionTimeline.audioStartSec, 5, accuracy: 0.001)
        XCTAssertEqual(timeline.compositionTimeline.videoPauseIntervals.count, 1)
        XCTAssertEqual(timeline.compositionTimeline.videoPauseIntervals.first?.startSec ?? 0, 2, accuracy: 0.001)
        XCTAssertEqual(timeline.compositionTimeline.videoPauseIntervals.first?.endSec ?? 0, 12, accuracy: 0.001)
    }

    func testAudioStartUsesBufferStartInsteadOfReceiptTime() {
        var timeline = LiveMediaCaptureTimeline()

        timeline.markAudioBufferStartIfNeeded(receivedAt: 101.25, sampleCount: 8_000, sampleRate: 16_000)

        XCTAssertEqual(timeline.audioStartSec ?? 0, 100.75, accuracy: 0.001)
    }

    func testAudioSourceTimestampIgnoresDelayedReceiptWithoutSubtractingBufferDuration() {
        var timeline = LiveMediaCaptureTimeline()
        timeline.markVideoStart(at: 100)

        timeline.markAudioBufferStartIfNeeded(
            receivedAt: 100.51, sampleCount: 480, sampleRate: 48_000, sourceStartSec: 100
        )

        XCTAssertEqual(timeline.audioStartSec ?? 0, 100, accuracy: 0.000001)
        XCTAssertEqual(timeline.compositionTimeline.audioStartSec, 0, accuracy: 0.000001)
        XCTAssertEqual(timeline.compositionTimeline.videoStartSec, 0, accuracy: 0.000001)
    }

    func testInvalidAudioSourceTimestampsKeepReceiptDurationFallback() {
        let invalidStarts: [TimeInterval?] = [nil, .nan, .infinity, -.infinity, -1]
        for sourceStart in invalidStarts {
            var timeline = LiveMediaCaptureTimeline()
            timeline.markAudioBufferStartIfNeeded(
                receivedAt: 101.25, sampleCount: 8_000, sampleRate: 16_000, sourceStartSec: sourceStart
            )

            XCTAssertEqual(timeline.audioStartSec ?? 0, 100.75, accuracy: 0.000001)
        }
    }

    func testLaterBuffersCannotMoveTheFirstAudioSourceAnchor() {
        var timeline = LiveMediaCaptureTimeline()
        timeline.markAudioBufferStartIfNeeded(
            receivedAt: 100.51, sampleCount: 480, sampleRate: 48_000, sourceStartSec: 100
        )
        timeline.markAudioBufferStartIfNeeded(
            receivedAt: 103, sampleCount: 480, sampleRate: 48_000, sourceStartSec: 100.01
        )
        timeline.markAudioBufferStartIfNeeded(receivedAt: 104, sampleCount: 480, sampleRate: 48_000)

        XCTAssertEqual(timeline.audioStartSec ?? 0, 100, accuracy: 0.000001)
    }
}
