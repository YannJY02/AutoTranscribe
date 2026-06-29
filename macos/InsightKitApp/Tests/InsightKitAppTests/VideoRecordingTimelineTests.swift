import CoreMedia
import XCTest
@testable import InsightKitApp

final class VideoRecordingTimelineTests: XCTestCase {
    func testPresentationTimeUsesCaptureClockInsteadOfSourcePTS() {
        var timeline = VideoRecordingTimeline()

        let first = timeline.presentationTime(
            sourcePresentationTime: CMTime(seconds: 100, preferredTimescale: 600),
            capturedAt: 1_000
        )
        let second = timeline.presentationTime(
            sourcePresentationTime: CMTime(seconds: 160, preferredTimescale: 600),
            capturedAt: 1_001
        )

        XCTAssertEqual(CMTimeGetSeconds(first), 0, accuracy: 0.001)
        XCTAssertEqual(CMTimeGetSeconds(second), 1, accuracy: 0.001)
        XCTAssertEqual(CMTimeGetSeconds(timeline.firstSourcePresentationTime!), 100, accuracy: 0.001)
        XCTAssertEqual(CMTimeGetSeconds(timeline.lastSourcePresentationTime!), 160, accuracy: 0.001)
    }

    func testPresentationTimeStaysMonotonicWhenCaptureClockDoesNotAdvance() {
        var timeline = VideoRecordingTimeline(timescale: 600)

        let first = timeline.presentationTime(
            sourcePresentationTime: CMTime(seconds: 0, preferredTimescale: 600),
            capturedAt: 50
        )
        let second = timeline.presentationTime(
            sourcePresentationTime: CMTime(seconds: 0.033, preferredTimescale: 600),
            capturedAt: 50
        )

        XCTAssertEqual(CMTimeGetSeconds(first), 0, accuracy: 0.001)
        XCTAssertGreaterThan(CMTimeGetSeconds(second), CMTimeGetSeconds(first))
        XCTAssertEqual(CMTimeGetSeconds(second), 1.0 / 600.0, accuracy: 0.0005)
    }
}
