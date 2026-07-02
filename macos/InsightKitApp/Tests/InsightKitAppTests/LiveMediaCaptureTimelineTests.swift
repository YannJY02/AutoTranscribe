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
    }
}
