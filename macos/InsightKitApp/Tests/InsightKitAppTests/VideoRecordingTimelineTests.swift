import CoreMedia
import CoreVideo
import XCTest
@testable import InsightKitApp

final class VideoRecordingTimelineTests: XCTestCase {
    func testCaptureStartTimeUsesTheSourceClock() {
        let startTime = VideoRecordingTimeline.captureStartTime(
            sourcePresentationTime: CMTime(seconds: 100.25, preferredTimescale: 600),
            capturedAt: 1_000.75
        )

        XCTAssertEqual(startTime, 100.25, accuracy: 0.001)
    }

    func testCaptureStartTimeFallsBackForInvalidSourcePTS() {
        let startTime = VideoRecordingTimeline.captureStartTime(
            sourcePresentationTime: .invalid,
            capturedAt: 1_000.75
        )

        XCTAssertEqual(startTime, 1_000.75, accuracy: 0.001)
    }

    func testPresentationTimeUsesSourcePTSInsteadOfCallbackDelay() {
        var timeline = VideoRecordingTimeline()

        let first = timeline.presentationTime(
            sourcePresentationTime: CMTime(seconds: 100, preferredTimescale: 600),
            capturedAt: 1_000
        )
        let second = timeline.presentationTime(
            sourcePresentationTime: CMTime(seconds: 101, preferredTimescale: 600),
            capturedAt: 1_005
        )

        XCTAssertEqual(CMTimeGetSeconds(first), 0, accuracy: 0.001)
        XCTAssertEqual(CMTimeGetSeconds(second), 1, accuracy: 0.001)
        XCTAssertEqual(CMTimeGetSeconds(timeline.firstSourcePresentationTime!), 100, accuracy: 0.001)
        XCTAssertEqual(CMTimeGetSeconds(timeline.lastSourcePresentationTime!), 101, accuracy: 0.001)
    }

    func testPresentationTimeUsesSourcePTSWhenCallbackClockDoesNotAdvance() {
        var timeline = VideoRecordingTimeline(timescale: 600)
        let sourceStep = CMTime(seconds: 0.033, preferredTimescale: 600)

        let first = timeline.presentationTime(
            sourcePresentationTime: CMTime(seconds: 0, preferredTimescale: 600),
            capturedAt: 50
        )
        let second = timeline.presentationTime(
            sourcePresentationTime: sourceStep,
            capturedAt: 50
        )

        XCTAssertEqual(CMTimeGetSeconds(first), 0, accuracy: 0.001)
        XCTAssertGreaterThan(CMTimeGetSeconds(second), CMTimeGetSeconds(first))
        XCTAssertEqual(CMTimeGetSeconds(second), CMTimeGetSeconds(sourceStep), accuracy: 0.0005)
    }

    func testPresentationTimeFallsBackToHostClockForInvalidSourcePTS() {
        var timeline = VideoRecordingTimeline()

        _ = timeline.presentationTime(
            sourcePresentationTime: CMTime(seconds: 100, preferredTimescale: 600),
            capturedAt: 1_000
        )
        let second = timeline.presentationTime(
            sourcePresentationTime: .invalid,
            capturedAt: 1_001
        )

        XCTAssertEqual(CMTimeGetSeconds(second), 1, accuracy: 0.001)
    }

    func testPresentationTimePreservesPausedGapForFinalComposition() {
        var timeline = VideoRecordingTimeline(timescale: 600)

        let first = timeline.presentationTime(
            sourcePresentationTime: CMTime(seconds: 0, preferredTimescale: 600),
            capturedAt: 10
        )
        timeline.pause(at: 11)
        timeline.resume(at: 21)
        let second = timeline.presentationTime(
            sourcePresentationTime: CMTime(seconds: 12, preferredTimescale: 600),
            capturedAt: 22
        )

        XCTAssertEqual(CMTimeGetSeconds(first), 0, accuracy: 0.001)
        XCTAssertEqual(CMTimeGetSeconds(second), 12, accuracy: 0.001)
    }

    func testRecordingDimensionsPreferFirstSampleBufferPixelSize() throws {
        let sampleBuffer = try makeSampleBuffer(width: 1234, height: 678)

        let size = VideoCaptureService.recordingDimensions(
            for: sampleBuffer,
            fallback: CGSize(width: 1920, height: 1080)
        )

        XCTAssertEqual(size.width, 1234)
        XCTAssertEqual(size.height, 678)
    }

    private func makeSampleBuffer(width: Int, height: Int) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let bufferStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        XCTAssertEqual(bufferStatus, kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)

        var formatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescriptionOut: &formatDescription
        )
        XCTAssertEqual(formatStatus, noErr)

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescription: try XCTUnwrap(formatDescription),
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        XCTAssertEqual(sampleStatus, noErr)
        return try XCTUnwrap(sampleBuffer)
    }
}
