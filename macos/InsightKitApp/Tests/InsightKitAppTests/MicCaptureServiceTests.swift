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

    func stop() {}
}
