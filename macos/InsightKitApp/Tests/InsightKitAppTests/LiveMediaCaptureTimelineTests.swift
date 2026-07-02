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
}
