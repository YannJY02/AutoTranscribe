import AVFoundation
import CoreMedia
import XCTest
@testable import InsightKitApp

final class SystemAudioCaptureServiceTests: XCTestCase {
    func testPCMConversionPreservesTheFirstSampleTimestamp() throws {
        let sampleBuffer = try makeSampleBuffer(
            presentationTimeStamp: CMTime(seconds: 123.456, preferredTimescale: 48_000)
        )
        var receivedBuffer: AVAudioPCMBuffer?
        var receivedStart: TimeInterval?

        SystemAudioCaptureService.handleSampleBuffer(sampleBuffer) { buffer, sourceStart in
            receivedBuffer = buffer
            receivedStart = sourceStart
        }

        let buffer = try XCTUnwrap(receivedBuffer)
        XCTAssertEqual(buffer.frameLength, 480)
        XCTAssertEqual(buffer.format.sampleRate, 48_000)
        XCTAssertEqual(try XCTUnwrap(buffer.floatChannelData)[0][0], 0.2, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(receivedStart), 123.456, accuracy: 0.000001,
                       "The 10 ms buffer duration must not be subtracted from its first-sample PTS")
    }

    func testPCMConversionRetainsAudioWhenItsTimestampIsInvalid() throws {
        for timestamp in [CMTime.invalid, .indefinite, .positiveInfinity, CMTime(value: -1, timescale: 1)] {
            let sampleBuffer = try makeSampleBuffer(presentationTimeStamp: timestamp)
            var received = false

            SystemAudioCaptureService.handleSampleBuffer(sampleBuffer) { buffer, sourceStart in
                received = true
                XCTAssertEqual(buffer.frameLength, 480)
                XCTAssertNil(sourceStart, "An invalid PTS must select the downstream receipt fallback")
            }

            XCTAssertTrue(received, "An invalid timestamp must not discard valid PCM")
        }
    }

    private func makeSampleBuffer(presentationTimeStamp: CMTime) throws -> CMSampleBuffer {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false
        ))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        pcm.frameLength = 480
        pcm.floatChannelData![0].initialize(repeating: 0.2, count: 480)
        var description: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: format.streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description
        ), noErr)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: try XCTUnwrap(description),
            sampleCount: 480,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        ), noErr)
        let buffer = try XCTUnwrap(sampleBuffer)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(
            buffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: pcm.audioBufferList
        ), noErr)
        XCTAssertEqual(CMSampleBufferSetDataReady(buffer), noErr)
        return buffer
    }
}
