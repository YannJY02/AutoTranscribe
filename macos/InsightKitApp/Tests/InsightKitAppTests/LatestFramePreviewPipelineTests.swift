import CoreMedia
import CoreVideo
import XCTest
@testable import InsightKitApp

final class LatestFramePreviewPipelineTests: XCTestCase {
    func testBlockedRenderQueueKeepsOnlyTheNewestFrame() {
        let worker = PreviewTestScheduler()
        let main = PreviewTestScheduler()
        var rendered: [Int] = []
        var published: [Int?] = []
        let preview = makePipeline(worker: worker, main: main) { frame in
            rendered.append(frame)
            return frame
        }
        preview.setImageHandler { published.append($0) }
        let generation = preview.beginGeneration()

        for frame in 1...300 {
            preview.submit(frame, generation: generation)
        }

        XCTAssertEqual(worker.pendingCount, 1)
        XCTAssertTrue(rendered.isEmpty)
        worker.runNext()
        main.runNext()
        XCTAssertEqual(rendered, [300])
        XCTAssertEqual(published, [300])
        XCTAssertEqual(worker.pendingCount, 0)
        XCTAssertEqual(main.pendingCount, 0)
    }

    func testCaptureSubmissionContinuesWhileRendererIsBlocked() {
        let worker = DispatchQueue(label: "LatestFramePreviewPipelineTests.blockedRender")
        let main = PreviewTestScheduler()
        let firstRenderStarted = expectation(description: "first render started")
        let captureSubmitted = expectation(description: "capture callbacks submitted while render blocked")
        let newestRendered = expectation(description: "newest pending frame rendered")
        let releaseRender = DispatchSemaphore(value: 0)
        let stateLock = NSLock()
        var rendered: [Int] = []
        var published: [Int?] = []
        let preview = LatestFramePreviewPipeline<Int, Int>(
            render: { frame in
                stateLock.withLock { rendered.append(frame) }
                if frame == 1 {
                    firstRenderStarted.fulfill()
                    releaseRender.wait()
                } else if frame == 300 {
                    newestRendered.fulfill()
                }
                return frame
            },
            currentTime: { ProcessInfo.processInfo.systemUptime },
            scheduleRender: { delay, work in
                worker.asyncAfter(deadline: .now() + delay, execute: work)
            },
            schedulePublish: { main.schedule($0) }
        )
        preview.setImageHandler { published.append($0) }
        let generation = preview.beginGeneration()
        preview.submit(1, generation: generation)
        wait(for: [firstRenderStarted], timeout: 2)

        DispatchQueue.global().async {
            for frame in 2...300 {
                preview.submit(frame, generation: generation)
            }
            captureSubmitted.fulfill()
        }
        wait(for: [captureSubmitted], timeout: 2)
        releaseRender.signal()
        wait(for: [newestRendered], timeout: 2)
        worker.sync {}

        XCTAssertEqual(stateLock.withLock { rendered }, [1, 300])
        XCTAssertEqual(main.pendingCount, 1)
        main.runNext()
        XCTAssertEqual(published, [300])
    }

    func testBlockedMainQueuePublishesTheNewestRenderedImageOnce() {
        let worker = PreviewTestScheduler()
        let main = PreviewTestScheduler()
        var published: [Int?] = []
        let preview = makePipeline(worker: worker, main: main, render: { $0 })
        preview.setImageHandler { published.append($0) }
        let generation = preview.beginGeneration()

        for frame in 1...60 {
            preview.submit(frame, generation: generation)
            worker.runNext()
        }

        XCTAssertEqual(main.pendingCount, 1)
        XCTAssertTrue(published.isEmpty)
        main.runNext()
        XCTAssertEqual(published, [60])
        XCTAssertEqual(main.pendingCount, 0)
    }

    func testCaptureSubmissionContinuesWhileImageSubscriberIsBlocked() {
        let worker = PreviewTestScheduler()
        let publicationQueue = DispatchQueue(label: "LatestFramePreviewPipelineTests.blockedSubscriber")
        let subscriberStarted = expectation(description: "image subscriber started")
        let captureSubmitted = expectation(description: "capture callbacks submitted while subscriber blocked")
        let newestPublished = expectation(description: "newest frame published")
        let releaseSubscriber = DispatchSemaphore(value: 0)
        let preview = LatestFramePreviewPipeline<Int, Int>(
            render: { $0 },
            currentTime: { worker.currentTime },
            scheduleRender: { delay, work in worker.schedule(work, after: delay) },
            schedulePublish: { work in publicationQueue.async(execute: work) }
        )
        preview.setImageHandler { image in
            if image == 1 {
                subscriberStarted.fulfill()
                releaseSubscriber.wait()
            } else if image == 2 {
                newestPublished.fulfill()
            }
        }
        let generation = preview.beginGeneration()
        preview.submit(1, generation: generation)
        worker.runNext()
        wait(for: [subscriberStarted], timeout: 2)

        DispatchQueue.global().async {
            XCTAssertTrue(preview.isCurrentGeneration(generation))
            preview.submit(2, generation: generation)
            captureSubmitted.fulfill()
        }
        wait(for: [captureSubmitted], timeout: 2)
        worker.runNext()
        releaseSubscriber.signal()
        wait(for: [newestPublished], timeout: 2)
        publicationQueue.sync {}
    }

    func testRestartDuringRenderRejectsTheOldResultAndOldCallbacks() {
        let worker = PreviewTestScheduler()
        let main = PreviewTestScheduler()
        var preview: LatestFramePreviewPipeline<Int, Int>!
        var oldGeneration: UInt64 = 0
        var newGeneration: UInt64 = 0
        var published: [Int?] = []
        preview = makePipeline(worker: worker, main: main) { frame in
            if frame == 1 {
                preview.invalidate()
                newGeneration = preview.beginGeneration()
                preview.submit(2, generation: newGeneration)
                preview.submit(99, generation: oldGeneration)
            }
            return frame
        }
        defer { preview = nil }
        preview.setImageHandler { published.append($0) }
        oldGeneration = preview.beginGeneration()
        preview.submit(1, generation: oldGeneration)

        worker.runNext()
        main.runNext()
        XCTAssertEqual(published, [nil])
        XCTAssertFalse(preview.isCurrentGeneration(oldGeneration))
        XCTAssertTrue(preview.isCurrentGeneration(newGeneration))

        worker.runNext()
        main.runNext()
        XCTAssertEqual(published.compactMap { $0 }, [2])
        XCTAssertEqual(worker.pendingCount, 0)
    }

    func testStopDiscardsRenderedImageWaitingForMainAndClearsThePreview() {
        let worker = PreviewTestScheduler()
        let main = PreviewTestScheduler()
        var published: [Int?] = []
        let preview = makePipeline(worker: worker, main: main, render: { $0 })
        preview.setImageHandler { published.append($0) }
        let generation = preview.beginGeneration()
        preview.submit(1, generation: generation)
        worker.runNext()

        preview.invalidate()
        preview.submit(2, generation: generation)
        XCTAssertEqual(worker.pendingCount, 0)
        XCTAssertEqual(main.pendingCount, 1)
        main.runNext()
        XCTAssertEqual(published, [nil])
    }

    func testPreviewPacesRenderingAtThirtyFramesPerSecondWithoutCatchupJobs() {
        let worker = PreviewTestScheduler()
        let main = PreviewTestScheduler()
        var rendered: [Int] = []
        var renderTimes: [TimeInterval] = []
        let preview = makePipeline(worker: worker, main: main) { frame in
            rendered.append(frame)
            renderTimes.append(worker.currentTime)
            return frame
        }
        let generation = preview.beginGeneration()
        preview.submit(1, generation: generation)
        worker.runNext()

        worker.advance(to: 0.001)
        preview.submit(2, generation: generation)
        worker.advance(to: 0.002)
        preview.submit(3, generation: generation)
        XCTAssertEqual(worker.pendingCount, 1)
        worker.runNext()

        XCTAssertEqual(rendered, [1, 3])
        XCTAssertEqual(renderTimes[0], 0)
        XCTAssertEqual(renderTimes[1], 1.0 / 30, accuracy: 0.000001)

        worker.advance(to: 1)
        preview.submit(4, generation: generation)
        worker.runNext()
        XCTAssertEqual(renderTimes.last!, 1, accuracy: 0.000001)
        XCTAssertEqual(worker.pendingCount, 0)
    }

    func testPreviewDownscalesWithoutChangingTheRecordingSample() throws {
        let sample = try makeSampleBuffer(width: 1920, height: 1080)
        let renderer = ScreenPreviewRenderer()

        let image = try XCTUnwrap(renderer.render(sample))

        XCTAssertEqual(image.width, 1280)
        XCTAssertEqual(image.height, 720)
        let sourcePixels = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        XCTAssertEqual(CVPixelBufferGetWidth(sourcePixels), 1920)
        XCTAssertEqual(CVPixelBufferGetHeight(sourcePixels), 1080)
        XCTAssertEqual(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)), 123, accuracy: 0.000001)
    }

    func testPreviewPreservesPortraitAspectAndDoesNotUpscaleSmallFrames() throws {
        let renderer = ScreenPreviewRenderer()
        let portrait = try XCTUnwrap(renderer.render(makeSampleBuffer(width: 1080, height: 1920)))
        XCTAssertEqual(portrait.width, 720)
        XCTAssertEqual(portrait.height, 1280)

        let small = try XCTUnwrap(renderer.render(makeSampleBuffer(width: 320, height: 180)))
        XCTAssertEqual(small.width, 320)
        XCTAssertEqual(small.height, 180)
    }

    private func makePipeline(
        worker: PreviewTestScheduler,
        main: PreviewTestScheduler,
        render: @escaping (Int) -> Int?
    ) -> LatestFramePreviewPipeline<Int, Int> {
        LatestFramePreviewPipeline(
            render: render,
            currentTime: { worker.currentTime },
            scheduleRender: { delay, work in worker.schedule(work, after: delay) },
            schedulePublish: { main.schedule($0) }
        )
    }

    private func makeSampleBuffer(width: Int, height: Int) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer
        ), kCVReturnSuccess)
        let pixels = try XCTUnwrap(pixelBuffer)
        var formatDescription: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescriptionOut: &formatDescription
        ), noErr)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(seconds: 123, preferredTimescale: 600),
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
}

private final class PreviewTestScheduler {
    private struct ScheduledWork {
        let time: TimeInterval
        let work: () -> Void
    }

    private let lock = NSLock()
    private var time: TimeInterval = 0
    private var pending: [ScheduledWork] = []

    var currentTime: TimeInterval { lock.withLock { time } }
    var pendingCount: Int { lock.withLock { pending.count } }

    func advance(to time: TimeInterval) {
        lock.withLock { self.time = max(self.time, time) }
    }

    func schedule(_ work: @escaping () -> Void, after delay: TimeInterval = 0) {
        lock.withLock { pending.append(ScheduledWork(time: time + delay, work: work)) }
    }

    func runNext(file: StaticString = #filePath, line: UInt = #line) {
        let next: ScheduledWork? = lock.withLock {
            guard !pending.isEmpty else { return nil }
            let next = pending.removeFirst()
            time = max(time, next.time)
            return next
        }
        guard let next else {
            XCTFail("Expected scheduled preview work", file: file, line: line)
            return
        }
        next.work()
    }
}
