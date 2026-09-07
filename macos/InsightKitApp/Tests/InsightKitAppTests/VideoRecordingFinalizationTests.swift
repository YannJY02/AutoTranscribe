import AVFoundation
import CoreMedia
import CoreVideo
import XCTest
@testable import InsightKitApp

final class VideoRecordingFinalizationTests: XCTestCase {
    func testFinishReturnsWhileWriterIsBlockedThenDrainsOnlyAdmittedFrames() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = DispatchQueue(label: "VideoRecordingFinalizationTests.blockedWriter")
        let service = VideoCaptureService(writerQueue: writer)
        try service.startRecording(to: directory.appendingPathComponent("recording.mp4"))
        let stateLock = NSLock()
        var firstFrameTimes: [TimeInterval] = []
        var finishing: Task<URL?, Never>?
        service.onRecordingFirstFrame = { time in
            stateLock.withLock { firstFrameTimes.append(time) }
        }

        let writerBlocked = expectation(description: "writer blocked before accepting queued frames")
        let finishReturned = expectation(description: "Stop returned without waiting for writer")
        let releaseWriter = DispatchSemaphore(value: 0)
        defer { releaseWriter.signal() }
        writer.async {
            writerBlocked.fulfill()
            releaseWriter.wait()
        }
        await fulfillment(of: [writerBlocked], timeout: 2)
        for sourceTime in [100.0, 101.0, 102.0] {
            service.enqueueRecordingSampleBuffer(try makeSampleBuffer(at: sourceTime), capturedAt: sourceTime)
        }
        XCTAssertTrue(stateLock.withLock { firstFrameTimes.isEmpty })

        DispatchQueue.global().async {
            let task = service.beginFinishRecording()
            stateLock.withLock { finishing = task }
            finishReturned.fulfill()
        }
        await fulfillment(of: [finishReturned], timeout: 2)
        let finishTask = stateLock.withLock { finishing }
        if finishTask != nil {
            // A post-Stop frame must not extend the saved media to this timestamp.
            service.enqueueRecordingSampleBuffer(try makeSampleBuffer(at: 200), capturedAt: 200)
        }
        releaseWriter.signal()
        let task = try XCTUnwrap(finishTask)
        let result = await task.value
        let output = try XCTUnwrap(result)

        XCTAssertEqual(stateLock.withLock { firstFrameTimes }, [100])
        let times = try await readVideoPresentationTimes(output)
        XCTAssertEqual(times, [0, 1, 2])
    }

    func testStopBeforeAnyFrameDoesNotReportRecordingReadiness() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = VideoCaptureService()
        let stateLock = NSLock()
        var firstFrameTimes: [TimeInterval] = []
        service.onRecordingFirstFrame = { time in
            stateLock.withLock { firstFrameTimes.append(time) }
        }
        try service.startRecording(to: directory.appendingPathComponent("recording.mp4"))

        let result = await service.beginFinishRecording().value

        XCTAssertNil(result)
        XCTAssertTrue(stateLock.withLock { firstFrameTimes.isEmpty })
    }

    func testCaptureCleanupDoesNotDiscardAnAlreadyQueuedFinishResult() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = VideoCaptureService()
        try service.startRecording(to: directory.appendingPathComponent("recording.mp4"))
        service.enqueueRecordingSampleBuffer(try makeSampleBuffer(at: 100), capturedAt: 100)
        service.enqueueRecordingSampleBuffer(try makeSampleBuffer(at: 101), capturedAt: 101)

        let finishing = service.beginFinishRecording()
        // stopCapture uses this same cleanup call after the explicit Stop barrier.
        service.stopRecording()
        let result = await finishing.value
        let output = try XCTUnwrap(result)

        let times = try await readVideoPresentationTimes(output)
        XCTAssertEqual(times, [0, 1])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("insightkit-video-finalization-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeSampleBuffer(at time: TimeInterval) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(
            kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixelBuffer
        ), kCVReturnSuccess)
        let pixels = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        CVPixelBufferGetBaseAddress(pixels)?.initializeMemory(
            as: UInt8.self,
            repeating: 0,
            count: CVPixelBufferGetBytesPerRow(pixels) * CVPixelBufferGetHeight(pixels)
        )
        CVPixelBufferUnlockBaseAddress(pixels, [])
        var formatDescription: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescriptionOut: &formatDescription
        ), noErr)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 600),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixels,
            formatDescription: try XCTUnwrap(formatDescription),
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ), noErr)
        return try XCTUnwrap(sampleBuffer)
    }

    private func readVideoPresentationTimes(_ url: URL) async throws -> [TimeInterval] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var times: [TimeInterval] = []
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetImageBuffer(sample) != nil else { continue }
            times.append(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)))
        }
        XCTAssertEqual(reader.status, .completed)
        return times.sorted()
    }
}
