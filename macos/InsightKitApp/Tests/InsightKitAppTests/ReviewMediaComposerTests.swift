import AVFoundation
import XCTest
@testable import InsightKitApp

final class ReviewMediaComposerTests: XCTestCase {
    func testComposeVideoWithAudioTrimsVideoToShorterAudioTimeline() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InsightKitReviewComposer_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let videoURL = tmp.appendingPathComponent("video.mp4")
        let audioURL = tmp.appendingPathComponent("audio.wav")
        let outputURL = tmp.appendingPathComponent("composed.mp4")

        try writeSilentVideo(to: videoURL, durationSec: 2.0)
        try writeToneAudio(to: audioURL, durationSec: 1.0)

        let composedURL = try AVFoundationReviewMediaComposer().composeVideoWithAudio(
            videoURL: videoURL,
            audioURL: audioURL,
            outputURL: outputURL
        )

        let durations = try loadTrackDurations(composedURL)
        let audioDuration = try XCTUnwrap(durations.audio)
        let videoDuration = try XCTUnwrap(durations.video)

        XCTAssertLessThan(abs(audioDuration - videoDuration), 0.35)
        XCTAssertEqual(videoDuration, 1.0, accuracy: 0.35)
        XCTAssertEqual(audioDuration, 1.0, accuracy: 0.35)
    }

    func testComposeVideoWithAudioUsesTimelineOffsetToSelectMatchingSourceWindow() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InsightKitReviewComposerOffset_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let videoURL = tmp.appendingPathComponent("video.mp4")
        let audioURL = tmp.appendingPathComponent("audio.wav")
        let outputURL = tmp.appendingPathComponent("composed.mp4")

        try writeSegmentedColorVideo(
            to: videoURL,
            segments: [
                (durationSec: 1.0, color: .red),
                (durationSec: 1.0, color: .green),
            ]
        )
        try writeToneAudio(to: audioURL, durationSec: 1.0)

        let composedURL = try AVFoundationReviewMediaComposer().composeVideoWithAudio(
            videoURL: videoURL,
            audioURL: audioURL,
            outputURL: outputURL,
            timeline: ReviewMediaCompositionTimeline(videoStartSec: 0.0, audioStartSec: 1.0)
        )

        let color = try sampleAverageRGB(from: composedURL, at: 0.5)
        XCTAssertGreaterThan(
            Int(color.green),
            Int(color.red) + 40,
            "Timeline-aligned composition should crop the first second of video and start on the green segment."
        )

        let durations = try loadTrackDurations(composedURL)
        XCTAssertEqual(try XCTUnwrap(durations.video), 1.0, accuracy: 0.35)
        XCTAssertEqual(try XCTUnwrap(durations.audio), 1.0, accuracy: 0.35)
    }

    func testComposeVideoWithAudioSkipsPausedVideoSourceRange() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InsightKitReviewComposerPause_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let videoURL = tmp.appendingPathComponent("video.mp4")
        let audioURL = tmp.appendingPathComponent("audio.wav")
        let outputURL = tmp.appendingPathComponent("composed.mp4")

        try writeSegmentedColorVideo(
            to: videoURL,
            segments: [
                (durationSec: 1.0, color: .red),
                (durationSec: 1.0, color: .black),
                (durationSec: 1.0, color: .green),
            ]
        )
        try writeToneAudio(to: audioURL, durationSec: 2.0)

        let composedURL = try AVFoundationReviewMediaComposer().composeVideoWithAudio(
            videoURL: videoURL,
            audioURL: audioURL,
            outputURL: outputURL,
            timeline: ReviewMediaCompositionTimeline(
                videoStartSec: 0,
                audioStartSec: 0,
                videoPauseIntervals: [
                    ReviewMediaCompositionPauseInterval(startSec: 1.0, endSec: 2.0),
                ]
            )
        )

        let firstColor = try sampleAverageRGB(from: composedURL, at: 0.5)
        let secondColor = try sampleAverageRGB(from: composedURL, at: 1.5)
        XCTAssertGreaterThan(Int(firstColor.red), Int(firstColor.green) + 40)
        XCTAssertGreaterThan(Int(secondColor.green), Int(secondColor.red) + 40)

        let durations = try loadTrackDurations(composedURL)
        XCTAssertEqual(try XCTUnwrap(durations.video), 2.0, accuracy: 0.35)
        XCTAssertEqual(try XCTUnwrap(durations.audio), 2.0, accuracy: 0.35)
    }

    private func writeSilentVideo(to url: URL, durationSec: Double) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320,
            AVVideoHeightKey: 180,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320,
            kCVPixelBufferHeightKey as String: 180,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let fps: Int32 = 30
        let frameCount = Int(durationSec * Double(fps))
        for frameIndex in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.002)
            }
            let pixelBuffer = try makePixelBuffer(width: 320, height: 180, color: .black)
            let time = CMTime(value: CMTimeValue(frameIndex), timescale: fps)
            XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: time))
        }

        input.markAsFinished()
        let exp = expectation(description: "finish video writer")
        writer.finishWriting {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        XCTAssertEqual(writer.status, .completed)
    }

    private enum TestFrameColor {
        case black
        case red
        case green

        var bgra: (blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8) {
            switch self {
            case .black:
                return (0, 0, 0, 255)
            case .red:
                return (0, 0, 255, 255)
            case .green:
                return (0, 255, 0, 255)
            }
        }
    }

    private func writeSegmentedColorVideo(
        to url: URL,
        segments: [(durationSec: Double, color: TestFrameColor)]
    ) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320,
            AVVideoHeightKey: 180,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320,
            kCVPixelBufferHeightKey as String: 180,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let fps: Int32 = 30
        var frameIndex = 0
        for segment in segments {
            let frames = Int(segment.durationSec * Double(fps))
            for _ in 0..<frames {
                while !input.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.002)
                }
                let pixelBuffer = try makePixelBuffer(width: 320, height: 180, color: segment.color)
                let time = CMTime(value: CMTimeValue(frameIndex), timescale: fps)
                XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: time))
                frameIndex += 1
            }
        }

        input.markAsFinished()
        let exp = expectation(description: "finish segmented video writer")
        writer.finishWriting {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        XCTAssertEqual(writer.status, .completed)
    }

    private func makePixelBuffer(width: Int, height: Int, color: TestFrameColor) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw NSError(domain: "ReviewMediaComposerTests", code: Int(status))
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let bgra = color.bgra
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            let pointer = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let row = pointer.advanced(by: y * bytesPerRow)
                for x in 0..<width {
                    let pixel = row.advanced(by: x * 4)
                    pixel[0] = bgra.blue
                    pixel[1] = bgra.green
                    pixel[2] = bgra.red
                    pixel[3] = bgra.alpha
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func writeToneAudio(to url: URL, durationSec: Double) throws {
        let sampleRate = 16_000.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frameCount = AVAudioFrameCount(durationSec * sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<Int(frameCount) {
            channel[frame] = sin(Float(frame) * 0.02) * 0.2
        }
        try file.write(from: buffer)
    }

    private func loadTrackDurations(_ url: URL) throws -> (audio: Double?, video: Double?) {
        let asset = AVURLAsset(url: url)
        let exp = expectation(description: "load composed track durations")
        final class Box {
            var result: Result<(audio: Double?, video: Double?), Error>?
        }
        let box = Box()

        Task {
            do {
                let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
                let videoTrack = try await asset.loadTracks(withMediaType: .video).first
                let audioTimeRange = try await audioTrack?.load(.timeRange)
                let videoTimeRange = try await videoTrack?.load(.timeRange)
                box.result = .success((
                    audio: audioTimeRange.map { CMTimeGetSeconds($0.duration) },
                    video: videoTimeRange.map { CMTimeGetSeconds($0.duration) }
                ))
            } catch {
                box.result = .failure(error)
            }
            exp.fulfill()
        }

        wait(for: [exp], timeout: 5)
        return try XCTUnwrap(box.result).get()
    }

    private func sampleAverageRGB(from url: URL, at seconds: Double) throws -> (red: UInt8, green: UInt8, blue: UInt8) {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try generator.copyCGImage(
            at: CMTime(seconds: seconds, preferredTimescale: 600),
            actualTime: nil
        )

        var pixel = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "ReviewMediaComposerTests", code: -1)
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (red: pixel[0], green: pixel[1], blue: pixel[2])
    }
}
