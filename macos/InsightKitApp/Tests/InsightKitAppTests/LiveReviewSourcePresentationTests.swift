import XCTest
@testable import InsightKitApp

final class LiveReviewSourcePresentationTests: XCTestCase {
    func testVideoRemainsPrimaryReviewSourceWhenSeparateAudioFallbackExists() {
        let videoURL = URL(fileURLWithPath: "/tmp/recording.mp4")
        let audioURL = URL(fileURLWithPath: "/tmp/recording.wav")

        let presentation = LiveReviewSourcePresentation.make(
            mediaURL: videoURL,
            reviewSourceMediaURL: audioURL,
            statusMessage: "Audio fallback is available."
        )

        XCTAssertEqual(presentation.primaryMediaURL, videoURL)
        XCTAssertEqual(presentation.supplementalAudioURL, audioURL)
        XCTAssertEqual(presentation.statusMessage, "Audio fallback is available.")
    }
}
