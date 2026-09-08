import AVFoundation
import XCTest
@testable import InsightKitApp

final class VideoCaptureTeardownTests: XCTestCase {
    @MainActor
    func testDelayedTeardownStopsOnlyItsOwnedCameraAndKeepsReplacementActive() async {
        let captureQueue = DispatchQueue(label: "VideoCaptureTeardownTests.capture")
        let service = VideoCaptureService(captureSessionQueue: captureQueue)
        let oldStarted = expectation(description: "old camera session started")
        let oldSession = TrackingCaptureSession(onStart: { oldStarted.fulfill() })
        service.startCameraSession(oldSession, deviceID: "old-camera")
        await fulfillment(of: [oldStarted], timeout: 2)
        let blocked = expectation(description: "old teardown is queued")
        let releaseTeardown = DispatchSemaphore(value: 0)
        defer { releaseTeardown.signal() }
        captureQueue.async {
            blocked.fulfill()
            releaseTeardown.wait()
        }
        await fulfillment(of: [blocked], timeout: 2)

        service.stopCapture()
        let newStarted = expectation(description: "replacement camera session started")
        let replacement = TrackingCaptureSession(onStart: { newStarted.fulfill() })
        service.startCameraSession(replacement, deviceID: "new-camera")
        releaseTeardown.signal()
        await fulfillment(of: [newStarted], timeout: 2)
        await flushMainQueue()

        XCTAssertEqual(oldSession.stopCount, 1)
        XCTAssertEqual(replacement.stopCount, 0, "Old cleanup must never stop the replacement session")
        XCTAssertTrue(service.isCapturing)

        service.stopCapture(waitUntilStopped: true)
        await flushMainQueue()
        XCTAssertEqual(replacement.stopCount, 1, "The replacement remains owned until its own Stop")
        XCTAssertFalse(service.isCapturing)
    }

    private func flushMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

private final class TrackingCaptureSession: AVCaptureSession, @unchecked Sendable {
    private let lock = NSLock()
    private let onStart: () -> Void
    private var stops = 0

    var stopCount: Int { lock.withLock { stops } }

    init(onStart: @escaping () -> Void) {
        self.onStart = onStart
        super.init()
    }

    override func startRunning() { onStart() }
    override func stopRunning() { lock.withLock { stops += 1 } }
}
