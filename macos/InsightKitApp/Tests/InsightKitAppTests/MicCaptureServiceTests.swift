import AVFoundation
import InsightKitObjCShims
import XCTest
@testable import InsightKitApp

final class MicCaptureServiceTests: XCTestCase {
    func testConcurrentStartsInstallOnlyOneInputTap() async throws {
        let engine = MicCaptureEngineSpy()
        let service = MicCaptureService(
            engine: engine,
            permissionProvider: MicCapturePermissionProviderStub(isGranted: true)
        )

        async let firstStart: Void = service.start()
        async let secondStart: Void = service.start()

        try await firstStart
        try await secondStart

        XCTAssertEqual(engine.installTapCalls, 1)
        XCTAssertEqual(engine.startCalls, 1)
    }

    func testFailedStartResetsCaptureGateForRetry() async throws {
        let engine = MicCaptureEngineSpy()
        engine.installTapError = MicCaptureEngineSpy.Error.installFailed
        let service = MicCaptureService(
            engine: engine,
            permissionProvider: MicCapturePermissionProviderStub(isGranted: true)
        )

        do {
            try await service.start()
            XCTFail("Expected first microphone start to fail.")
        } catch MicCaptureEngineSpy.Error.installFailed {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        engine.installTapError = nil
        try await service.start()

        XCTAssertEqual(engine.installTapCalls, 2)
        XCTAssertEqual(engine.removeTapCalls, 3)
        XCTAssertEqual(engine.startCalls, 1)
    }

    func testInvalidInputFormatFailsBeforeInstallingTap() async {
        let engine = MicCaptureEngineSpy(
            format: AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 0,
                channels: 0,
                interleaved: false
            )!
        )
        let service = MicCaptureService(
            engine: engine,
            permissionProvider: MicCapturePermissionProviderStub(isGranted: true)
        )

        do {
            try await service.start()
            XCTFail("Expected invalid microphone input format to fail.")
        } catch MicCaptureService.MicError.noInputNode {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(engine.installTapCalls, 0)
        XCTAssertEqual(engine.startCalls, 0)
    }

    func testStopDrainsAcceptedCallbacksAndRejectsThePreviousTapAfterRestart() async throws {
        let engine = MicCaptureEngineSpy()
        let service = MicCaptureService(
            engine: engine,
            permissionProvider: MicCapturePermissionProviderStub(isGranted: true)
        )
        let firstEntered = expectation(description: "first callback is busy")
        let releaseFirst = DispatchSemaphore(value: 0)
        defer { releaseFirst.signal() }
        var received: [Float] = []
        service.onBuffer = { buffer in
            if received.isEmpty {
                firstEntered.fulfill()
                _ = releaseFirst.wait(timeout: .now() + 5)
            }
            received.append(buffer.floatChannelData![0][0])
        }
        try await service.start()
        engine.emit(value: 0.1, tapIndex: 0)
        await fulfillment(of: [firstEntered], timeout: 2)
        engine.emit(value: 0.2, tapIndex: 0)
        let stopped = expectation(description: "engine stopped before draining callbacks")
        engine.onStopped = { stopped.fulfill() }
        let draining = Task { await service.stopAndDrain() }
        await fulfillment(of: [stopped], timeout: 2)
        engine.onStopped = nil
        engine.emit(value: 0.9, tapIndex: 0)
        releaseFirst.signal()
        await draining.value
        XCTAssertEqual(received, [0.1, 0.2])

        try await service.start()
        engine.emit(value: 0.9, tapIndex: 0)
        engine.emit(value: 0.3, tapIndex: 1)
        await service.stopAndDrain()
        XCTAssertEqual(received, [0.1, 0.2, 0.3])
    }

    func testStopCancelsAStartWaitingForPermission() async {
        let engine = MicCaptureEngineSpy()
        let requested = expectation(description: "permission is pending")
        let permission = MicCapturePermissionGate(onRequest: { requested.fulfill() })
        let service = MicCaptureService(engine: engine, permissionProvider: permission)
        let starting = Task { try await service.start() }
        await fulfillment(of: [requested], timeout: 2)
        service.stop()
        permission.resolve()
        do {
            try await starting.value
            XCTFail("A cancelled capture start must not install a microphone tap")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(engine.startCalls, 0)
        XCTAssertEqual(engine.installTapCalls, 0)
    }

    func testAVAudioTapObjectiveCExceptionBecomesRecoverableError() throws {
        do {
            try ObjCExceptionBridge.perform {
                NSException(
                    name: .invalidArgumentException,
                    reason: "simulated AVAudioNode.installTap failure",
                    userInfo: nil
                ).raise()
            }
            XCTFail("Expected Objective-C exception bridge to throw.")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, IKObjCExceptionErrorDomain)
            XCTAssertEqual(
                error.userInfo[IKObjCExceptionNameKey] as? String,
                NSExceptionName.invalidArgumentException.rawValue
            )
        }
    }

    func testAVAudioTapObjectiveCExceptionBecomesRecoverableMicError() throws {
        let engine = AVAudioMicCaptureEngine { _, _, _, _ in
            NSException(
                name: .invalidArgumentException,
                reason: "simulated AVAudioNode.installTap failure",
                userInfo: nil
            ).raise()
        }
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!

        do {
            try engine.installTap(bufferSize: 2048, format: format) { _ in }
            XCTFail("Expected Objective-C exception to be converted into a microphone capture error.")
        } catch MicCaptureEngineError.inputTapInstallationFailed(let reason) {
            XCTAssertTrue(reason.contains("NSInvalidArgumentException"))
            XCTAssertTrue(reason.contains("simulated AVAudioNode.installTap failure"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private final class MicCapturePermissionProviderStub: MicCapturePermissionProviding {
    let isGranted: Bool

    init(isGranted: Bool) {
        self.isGranted = isGranted
    }

    func requestPermissionIfNeeded() async -> Bool {
        isGranted
    }
}

private final class MicCaptureEngineSpy: MicCaptureEngineProviding {
    enum Error: Swift.Error {
        case duplicateTap
        case installFailed
    }

    var installTapError: Swift.Error?
    private(set) var installTapCalls = 0
    private(set) var removeTapCalls = 0
    private(set) var startCalls = 0
    private var hasTapInstalled = false
    private let format: AVAudioFormat
    private let lock = NSLock()
    private var taps: [(AVAudioPCMBuffer) -> Void] = []
    var onStopped: (() -> Void)?

    init(
        format: AVAudioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
    ) {
        self.format = format
    }

    func inputFormat() -> AVAudioFormat {
        format
    }

    func installTap(
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat,
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        installTapCalls += 1
        if let installTapError {
            throw installTapError
        }
        if hasTapInstalled {
            throw Error.duplicateTap
        }
        hasTapInstalled = true
        taps.append(onBuffer)
    }

    func removeTap() {
        lock.lock()
        removeTapCalls += 1
        hasTapInstalled = false
        lock.unlock()
    }

    func prepare() {}

    func start() throws {
        lock.lock()
        startCalls += 1
        lock.unlock()
    }

    func stop() { onStopped?() }

    func emit(value: Float, tapIndex: Int) {
        lock.lock()
        let tap = taps[tapIndex]
        lock.unlock()
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        buffer.frameLength = 1
        buffer.floatChannelData![0][0] = value
        tap(buffer)
    }
}

private final class MicCapturePermissionGate: MicCapturePermissionProviding {
    private let onRequest: () -> Void
    private var continuation: CheckedContinuation<Bool, Never>?

    init(onRequest: @escaping () -> Void) { self.onRequest = onRequest }

    func requestPermissionIfNeeded() async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            onRequest()
        }
    }

    func resolve() { continuation?.resume(returning: true) }
}
