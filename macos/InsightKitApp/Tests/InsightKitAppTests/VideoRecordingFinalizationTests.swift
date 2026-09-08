import AVFoundation
import CoreMedia
import CoreVideo
import XCTest
@testable import InsightKitApp

final class VideoRecordingFinalizationTests: XCTestCase {
    func testPausedFramesCannotExhaustAFullBufferAndPrePauseFramesStillDrain() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = DispatchQueue(label: "VideoRecordingFinalizationTests.pausedFullBuffer")
        let stateLock = NSLock()
        var encoderReady = false
        var failureMessages: [String] = []
        let service = VideoCaptureService(
            writerQueue: writer,
            recordingBufferLimits: .init(maximumFrames: 2, maximumBytes: 1024 * 1024),
            writerIsReady: { input in stateLock.withLock { encoderReady } && input.isReadyForMoreMediaData }
        )
        service.onRecordingFailure = { message in stateLock.withLock { failureMessages.append(message) } }
        try service.startRecording(to: directory.appendingPathComponent("paused.mp4"))
        for time in [100.0, 101] {
            service.enqueueRecordingSampleBuffer(try makeSampleBuffer(at: time), capturedAt: time)
        }
        service.pauseRecording(at: 110)
        XCTAssertEqual(service.recordingBufferUsage.frames, 2)

        for time in 111..<121 {
            service.enqueueRecordingSampleBuffer(try makeSampleBuffer(at: Double(time)), capturedAt: Double(time))
        }
        writer.sync {}

        XCTAssertEqual(service.recordingBufferUsage.frames, 2, "Paused frames must not reserve buffer capacity")
        XCTAssertNil(writer.sync { service.recordingFailureMessage })
        stateLock.withLock { encoderReady = true }
        let result = await service.beginFinishRecording().value
        let times = try await readVideoPresentationTimes(XCTUnwrap(result))
        XCTAssertEqual(times, [0, 1], "Pause must preserve the frames admitted before it")
        XCTAssertTrue(stateLock.withLock { failureMessages.isEmpty })
    }

    func testResumeAdmitsFramesAfterPausedSamplesWereRejected() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = DispatchQueue(label: "VideoRecordingFinalizationTests.resumeAdmission")
        let stateLock = NSLock()
        var encoderReady = false
        let service = VideoCaptureService(
            writerQueue: writer,
            recordingBufferLimits: .init(maximumFrames: 2, maximumBytes: 1024 * 1024),
            writerIsReady: { input in stateLock.withLock { encoderReady } && input.isReadyForMoreMediaData }
        )
        try service.startRecording(to: directory.appendingPathComponent("resumed.mp4"))
        service.enqueueRecordingSampleBuffer(try makeSampleBuffer(at: 100), capturedAt: 100)
        service.pauseRecording(at: 110)
        for time in 111..<121 {
            service.enqueueRecordingSampleBuffer(try makeSampleBuffer(at: Double(time)), capturedAt: Double(time))
        }
        stateLock.withLock { encoderReady = true }
        service.resumeRecording(at: 130)
        service.enqueueRecordingSampleBuffer(try makeSampleBuffer(at: 131), capturedAt: 131)

        let result = await service.beginFinishRecording().value

        let times = try await readVideoPresentationTimes(XCTUnwrap(result))
        XCTAssertEqual(times, [0, 31], "Resume must reopen admission after restoring the source timeline")
        XCTAssertNil(writer.sync { service.recordingFailureMessage })
    }

    func testActiveEncoderStallFailsAtFrameLimitBeforeStopAndReleasesItsBuffers() async throws {
        try await assertActiveEncoderStallFails(
            limits: .init(maximumFrames: 2, maximumBytes: 1024 * 1024)
        )
    }

    func testActiveEncoderStallFailsAtByteLimitBeforeStopAndReleasesItsBuffers() async throws {
        let sample = try makeSampleBuffer(at: 100)
        let bytes = CVPixelBufferGetDataSize(try XCTUnwrap(CMSampleBufferGetImageBuffer(sample)))
        try await assertActiveEncoderStallFails(
            limits: .init(maximumFrames: 120, maximumBytes: bytes * 2)
        )
    }

    private func assertActiveEncoderStallFails(limits: VideoCaptureService.RecordingBufferLimits) async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = DispatchQueue(label: "VideoRecordingFinalizationTests.stalledEncoder")
        let service = VideoCaptureService(
            writerQueue: writer, recordingBufferLimits: limits, writerIsReady: { _ in false }
        )
        let failed = expectation(description: "active recording reports buffer exhaustion before Stop")
        let callbackLock = NSLock()
        var messages: [String] = []
        service.onRecordingFailure = { message in
            XCTAssertTrue(Thread.isMainThread)
            callbackLock.withLock { messages.append(message) }
            failed.fulfill()
        }
        try service.startRecording(to: directory.appendingPathComponent("stalled.mp4"))
        for sourceTime in [100.0, 101] {
            service.enqueueRecordingSampleBuffer(try makeSampleBuffer(at: sourceTime), capturedAt: sourceTime)
            writer.sync {}
        }
        XCTAssertEqual(service.recordingBufferUsage.frames, 2)
        XCTAssertLessThanOrEqual(service.recordingBufferUsage.bytes, limits.maximumBytes)
        XCTAssertTrue(callbackLock.withLock { messages.isEmpty })

        service.enqueueRecordingSampleBuffer(try makeSampleBuffer(at: 102), capturedAt: 102)
        await fulfillment(of: [failed], timeout: 2)
        writer.sync {}

        XCTAssertEqual(service.recordingBufferUsage.frames, 0)
        XCTAssertEqual(service.recordingBufferUsage.bytes, 0)
        XCTAssertEqual(writer.sync { service.recordingFailureMessage }, callbackLock.withLock { messages.first })
        for sourceTime in 103..<113 {
            service.enqueueRecordingSampleBuffer(try makeSampleBuffer(at: Double(sourceTime)), capturedAt: Double(sourceTime))
        }
        XCTAssertEqual(service.recordingBufferUsage.frames, 0, "Failure must close admission immediately")
        let result = await service.beginFinishRecording().value
        XCTAssertNil(result)
        XCTAssertEqual(callbackLock.withLock { messages.count }, 1)
    }

    func testAdmissionOverflowNotifiesBeforeBlockedWriterCanDrain() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = DispatchQueue(label: "VideoRecordingFinalizationTests.blockedAdmission")
        let service = VideoCaptureService(
            writerQueue: writer,
            recordingBufferLimits: .init(maximumFrames: 2, maximumBytes: 1024 * 1024)
        )
        let failed = expectation(description: "failure reaches UI while writer is still blocked")
        service.onRecordingFailure = { _ in failed.fulfill() }
        try service.startRecording(to: directory.appendingPathComponent("blocked.mp4"))
        let blocked = expectation(description: "writer cannot consume admitted buffers")
        let releaseWriter = DispatchSemaphore(value: 0)
        defer { releaseWriter.signal() }
        writer.async {
            blocked.fulfill()
            releaseWriter.wait()
        }
        await fulfillment(of: [blocked], timeout: 2)
        for sourceTime in [100.0, 101, 102, 103] {
            service.enqueueRecordingSampleBuffer(try makeSampleBuffer(at: sourceTime), capturedAt: sourceTime)
        }

        await fulfillment(of: [failed], timeout: 2)

        XCTAssertEqual(service.recordingBufferUsage.frames, 2)
        XCTAssertLessThanOrEqual(service.recordingBufferUsage.bytes, 1024 * 1024)
        let finishing = service.beginFinishRecording()
        releaseWriter.signal()
        let result = await finishing.value
        XCTAssertNil(result)
        XCTAssertEqual(service.recordingBufferUsage.frames, 0)
    }

    @MainActor
    func testQueuedFailureCannotNotifyOrClearAReplacementRecording() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = DispatchQueue(label: "VideoRecordingFinalizationTests.failureReplacement")
        let service = VideoCaptureService(
            writerQueue: writer,
            recordingBufferLimits: .init(maximumFrames: 1, maximumBytes: 1024 * 1024)
        )
        var failureMessages: [String] = []
        service.onRecordingFailure = { failureMessages.append($0) }
        try service.startRecording(to: directory.appendingPathComponent("previous.mp4"))
        // Keep the first sample queued so the second must exhaust admission.
        let releaseWriter = DispatchSemaphore(value: 0)
        defer { releaseWriter.signal() }
        writer.async { releaseWriter.wait() }
        service.enqueueRecordingSampleBuffer(try makeSampleBuffer(at: 100), capturedAt: 100)
        service.enqueueRecordingSampleBuffer(try makeSampleBuffer(at: 101), capturedAt: 101)
        releaseWriter.signal()
        // The queued main-thread callback has not run yet. A replacement must
        // invalidate it even though the prior failure cleared its writer state.
        try service.startRecording(to: directory.appendingPathComponent("replacement.mp4"))
        service.enqueueRecordingSampleBuffer(try makeSampleBuffer(at: 300), capturedAt: 300)

        let result = await service.beginFinishRecording().value

        let times = try await readVideoPresentationTimes(XCTUnwrap(result))
        XCTAssertEqual(times, [0])
        XCTAssertTrue(failureMessages.isEmpty)
        XCTAssertNil(writer.sync { service.recordingFailureMessage })
    }

    @MainActor
    func testPendingCaptureTeardownCannotCloseANewerRecording() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let captureQueue = DispatchQueue(label: "VideoRecordingFinalizationTests.captureTeardown")
        let service = VideoCaptureService(captureSessionQueue: captureQueue)
        let releaseTeardown = DispatchSemaphore(value: 0)
        defer { releaseTeardown.signal() }
        captureQueue.async { releaseTeardown.wait() }
        service.stopCapture()
        try service.startRecording(to: directory.appendingPathComponent("new-capture.mp4"))
        releaseTeardown.signal()
        captureQueue.sync {}
        service.enqueueRecordingSampleBuffer(try makeSampleBuffer(at: 300), capturedAt: 300)

        let result = await service.beginFinishRecording().value

        let times = try await readVideoPresentationTimes(XCTUnwrap(result))
        XCTAssertEqual(times, [0])
    }

    func testFinishReturnsWhileWriterIsBlockedThenDrainsOnlyAdmittedFrames() async throws {
        try await assertFinishDrainsOnlyAdmittedFrames(at: [100, 101, 102])
    }

    func testFinishPreservesEveryFrameInAnAdmittedBurstUnderEncoderBackpressure() async throws {
        try await assertFinishDrainsOnlyAdmittedFrames(at: (100..<160).map(Double.init))
    }

    private func assertFinishDrainsOnlyAdmittedFrames(at sourceTimes: [TimeInterval]) async throws {
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
        for sourceTime in sourceTimes {
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
        XCTAssertEqual(times, sourceTimes.map { $0 - sourceTimes[0] })
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

    func testPauseKeepsPreparedFramesAndRejectsOnlyFramesAdmittedDuringThePause() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = DispatchQueue(label: "VideoRecordingFinalizationTests.pauseWriter")
        let service = VideoCaptureService(writerQueue: writer)
        try service.startRecording(to: directory.appendingPathComponent("recording.mp4"))
        let blocked = expectation(description: "writer blocked before the pre-pause burst")
        let releaseWriter = DispatchSemaphore(value: 0)
        defer { releaseWriter.signal() }
        writer.async {
            blocked.fulfill()
            releaseWriter.wait()
        }
        await fulfillment(of: [blocked], timeout: 2)
        for sourceTime in (100..<160).map(Double.init) {
            service.enqueueRecordingSampleBuffer(try makeSampleBuffer(at: sourceTime), capturedAt: sourceTime)
        }
        releaseWriter.signal()
        // Pause is ordered after frame preparation, but must not prevent those
        // frames from draining when the encoder becomes ready asynchronously.
        service.pauseRecording(at: 160)
        service.enqueueRecordingSampleBuffer(try makeSampleBuffer(at: 170), capturedAt: 170)
        service.resumeRecording(at: 180)
        service.enqueueRecordingSampleBuffer(try makeSampleBuffer(at: 181), capturedAt: 181)
        service.enqueueRecordingSampleBuffer(try makeSampleBuffer(at: 182), capturedAt: 182)

        let result = await service.beginFinishRecording().value
        let times = try await readVideoPresentationTimes(XCTUnwrap(result))
        // This is the raw video timeline. Final composition removes pause [60, 80],
        // placing source-relative frames 81/82 at playback times 61/62 exactly once.
        XCTAssertEqual(times, (0..<60).map(Double.init) + [81, 82])
    }

    func testFinishDeadlineReturnsBeforeBlockedWriterAndCleanupCannotAffectTheNextRecording() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = DispatchQueue(label: "VideoRecordingFinalizationTests.timeoutWriter")
        let service = VideoCaptureService(writerQueue: writer)
        try service.startRecording(to: directory.appendingPathComponent("timed-out.mp4"))
        let blocked = expectation(description: "writer blocked beyond the Stop deadline")
        let releaseWriter = DispatchSemaphore(value: 0)
        defer { releaseWriter.signal() }
        writer.async {
            blocked.fulfill()
            releaseWriter.wait()
        }
        await fulfillment(of: [blocked], timeout: 2)
        for sourceTime in (100..<160).map(Double.init) {
            service.enqueueRecordingSampleBuffer(try makeSampleBuffer(at: sourceTime), capturedAt: sourceTime)
        }

        let result = await service.beginFinishRecording(timeoutSec: 0).value
        XCTAssertNil(result, "Stop's deadline starts before its writer-queue barrier can run")
        releaseWriter.signal()
        XCTAssertEqual(writer.sync { service.recordingFailureMessage }, "Video recording finalization timed out.")

        try service.startRecording(to: directory.appendingPathComponent("next.mp4"))
        service.enqueueRecordingSampleBuffer(try makeSampleBuffer(at: 300), capturedAt: 300)
        let nextResult = await service.beginFinishRecording().value
        let times = try await readVideoPresentationTimes(XCTUnwrap(nextResult))
        XCTAssertEqual(times, [0], "Stale readiness and finish callbacks must not clear a replacement writer")
        XCTAssertNil(writer.sync { service.recordingFailureMessage })
    }

    func testWriterFailureReturnsNoRecordingAndDoesNotReportFirstFrameReadiness() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalidParent = directory.appendingPathComponent("file-instead-of-directory")
        try Data().write(to: invalidParent)
        let writer = DispatchQueue(label: "VideoRecordingFinalizationTests.failedWriter")
        let service = VideoCaptureService(writerQueue: writer)
        let stateLock = NSLock()
        var firstFrameTimes: [TimeInterval] = []
        service.onRecordingFirstFrame = { time in
            stateLock.withLock { firstFrameTimes.append(time) }
        }
        try service.startRecording(to: invalidParent.appendingPathComponent("recording.mp4"))
        service.enqueueRecordingSampleBuffer(try makeSampleBuffer(at: 100), capturedAt: 100)

        let result = await service.beginFinishRecording().value

        XCTAssertNil(result)
        XCTAssertTrue(stateLock.withLock { firstFrameTimes.isEmpty })
        XCTAssertNotNil(writer.sync { service.recordingFailureMessage })
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
