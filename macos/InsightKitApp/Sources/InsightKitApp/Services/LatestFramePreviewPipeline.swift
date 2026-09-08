import CoreGraphics
import CoreImage
import CoreMedia
import Foundation

/// A preview may skip intermediate frames, but must never accumulate old ones.
/// Recording uses its own sample-buffer path and does not wait for this pipeline.
final class LatestFramePreviewPipeline<Frame, Image> {
    typealias Generation = UInt64
    typealias Work = () -> Void
    typealias RenderScheduler = (TimeInterval, @escaping Work) -> Void
    typealias PublishScheduler = (@escaping Work) -> Void

    private struct PendingImage {
        let generation: Generation
        let image: Image?
    }

    private let lock = NSLock()
    private let publicationLock = NSRecursiveLock()
    private let render: (Frame) -> Image?
    private let currentTime: () -> TimeInterval
    private let scheduleRender: RenderScheduler
    private let schedulePublish: PublishScheduler
    private let frameInterval: TimeInterval
    private var imageHandler: ((Image?) -> Void)?
    private var generation: Generation = 0
    private var isActive = false
    private var pendingFrame: Frame?
    private var pendingImage: PendingImage?
    private var renderScheduled = false
    private var publishScheduled = false
    private var lastRenderStartedAt: TimeInterval?

    convenience init(render: @escaping (Frame) -> Image?) {
        let renderQueue = DispatchQueue(
            label: "InsightKit.VideoCapture.Preview",
            qos: .userInitiated,
            autoreleaseFrequency: .workItem
        )
        self.init(
            render: render,
            currentTime: { ProcessInfo.processInfo.systemUptime },
            scheduleRender: { delay, work in
                renderQueue.asyncAfter(deadline: .now() + delay, execute: work)
            },
            schedulePublish: { work in
                DispatchQueue.main.async(execute: work)
            }
        )
    }

    init(
        maximumFramesPerSecond: Double = 30,
        render: @escaping (Frame) -> Image?,
        currentTime: @escaping () -> TimeInterval,
        scheduleRender: @escaping RenderScheduler,
        schedulePublish: @escaping PublishScheduler
    ) {
        precondition(maximumFramesPerSecond.isFinite && maximumFramesPerSecond > 0)
        self.frameInterval = 1 / maximumFramesPerSecond
        self.render = render
        self.currentTime = currentTime
        self.scheduleRender = scheduleRender
        self.schedulePublish = schedulePublish
    }

    func setImageHandler(_ handler: @escaping (Image?) -> Void) {
        lock.withLock { imageHandler = handler }
    }

    @discardableResult
    func beginGeneration() -> Generation {
        reset(isActive: true)
    }

    func invalidate() {
        _ = reset(isActive: false)
    }

    func isCurrentGeneration(_ candidate: Generation) -> Bool {
        lock.withLock { isActive && generation == candidate }
    }

    func submit(_ frame: Frame, generation candidate: Generation) {
        let delay: TimeInterval? = lock.withLock {
            guard isActive, generation == candidate else { return nil }
            pendingFrame = frame
            return scheduleNextRenderIfNeeded()
        }
        if let delay {
            enqueueRender(after: delay)
        }
    }

    private func reset(isActive: Bool) -> Generation {
        let result: (Generation, Bool) = publicationLock.withLock {
            lock.withLock {
                generation &+= 1
                self.isActive = isActive
                pendingFrame = nil
                lastRenderStartedAt = nil
                return (generation, replacePendingImage(nil))
            }
        }
        if result.1 {
            enqueuePublish()
        }
        return result.0
    }

    /// Called with the lock held. A scheduled or running render owns the one worker slot.
    private func scheduleNextRenderIfNeeded() -> TimeInterval? {
        guard isActive, pendingFrame != nil, !renderScheduled else { return nil }
        renderScheduled = true
        return lastRenderStartedAt.map { max(0, $0 + frameInterval - currentTime()) } ?? 0
    }

    private func enqueueRender(after delay: TimeInterval) {
        scheduleRender(delay) { [weak self] in self?.renderLatestFrame() }
    }

    private func renderLatestFrame() {
        let input: (Frame, Generation)? = lock.withLock {
            guard isActive, let frame = pendingFrame else {
                renderScheduled = false
                return nil
            }
            pendingFrame = nil
            lastRenderStartedAt = currentTime()
            return (frame, generation)
        }
        guard let (frame, frameGeneration) = input else { return }

        // Conversion can be slow. Capture callbacks can replace pendingFrame meanwhile.
        let image = render(frame)

        let next: (Bool, TimeInterval?) = lock.withLock {
            let shouldPublish: Bool
            if isActive, generation == frameGeneration, let image {
                shouldPublish = replacePendingImage(image)
            } else {
                shouldPublish = false
            }
            renderScheduled = false
            return (shouldPublish, scheduleNextRenderIfNeeded())
        }
        if next.0 {
            enqueuePublish()
        }
        if let delay = next.1 {
            enqueueRender(after: delay)
        }
    }

    /// Called with the lock held. A stalled main queue retains only the latest image.
    private func replacePendingImage(_ image: Image?) -> Bool {
        pendingImage = PendingImage(generation: generation, image: image)
        guard !publishScheduled else { return false }
        publishScheduled = true
        return true
    }

    private func enqueuePublish() {
        schedulePublish { [weak self] in
            guard let self else { return }
            self.publicationLock.withLock {
                let delivery: (Image?, (Image?) -> Void)? = self.lock.withLock {
                    self.publishScheduled = false
                    guard let pending = self.pendingImage else { return nil }
                    self.pendingImage = nil
                    guard pending.generation == self.generation,
                          let handler = self.imageHandler else { return nil }
                    return (pending.image, handler)
                }
                // Generation changes cannot overtake this assignment, but capture
                // submissions never wait for UI subscribers. The recursive lock
                // permits a subscriber to stop/reconfigure during publication.
                if let (image, handler) = delivery {
                    handler(image)
                }
            }
        }
    }
}

struct ScreenPreviewRenderer {
    let maximumPixelDimension: CGFloat
    private let context = CIContext(options: [.cacheIntermediates: false])

    init(maximumPixelDimension: CGFloat = 1280) {
        precondition(maximumPixelDimension.isFinite && maximumPixelDimension >= 1)
        self.maximumPixelDimension = maximumPixelDimension
    }

    func render(_ sampleBuffer: CMSampleBuffer) -> CGImage? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let longestEdge = max(image.extent.width, image.extent.height)
        guard longestEdge > 0 else { return nil }
        let scale = min(1, maximumPixelDimension / longestEdge)
        let preview = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(preview, from: preview.extent.integral)
    }
}
