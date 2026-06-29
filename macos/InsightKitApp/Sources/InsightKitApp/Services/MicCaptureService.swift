import AVFoundation
import Foundation

enum MicCaptureEngineError: LocalizedError, Equatable {
    case inputTapInstallationFailed(String)

    var errorDescription: String? {
        switch self {
        case .inputTapInstallationFailed:
            return "麦克风采集启动失败。请检查音频输入设备，关闭其他正在占用麦克风的应用，然后重新开始 Live Workspace。"
        }
    }

    var failureReason: String? {
        switch self {
        case .inputTapInstallationFailed(let reason):
            return reason
        }
    }
}

protocol MicCapturePermissionProviding {
    func requestPermissionIfNeeded() async -> Bool
}

struct SystemMicCapturePermissionProvider: MicCapturePermissionProviding {
    func requestPermissionIfNeeded() async -> Bool {
        if #available(macOS 14.0, *) {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                return true
            case .notDetermined:
                return await AVCaptureDevice.requestAccess(for: .audio)
            default:
                return false
            }
        }

        return await AVCaptureDevice.requestAccess(for: .audio)
    }
}

protocol MicCaptureEngineProviding: AnyObject {
    func inputFormat() -> AVAudioFormat
    func installTap(
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat,
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void
    ) throws
    func removeTap()
    func prepare()
    func start() throws
    func stop()
}

final class AVAudioMicCaptureEngine: MicCaptureEngineProviding {
    typealias InputTapInstaller = (
        AVAudioNode,
        AVAudioFrameCount,
        AVAudioFormat,
        @escaping (AVAudioPCMBuffer) -> Void
    ) -> Void

    private let engine = AVAudioEngine()
    private let inputTapInstaller: InputTapInstaller

    init(inputTapInstaller: InputTapInstaller? = nil) {
        self.inputTapInstaller = inputTapInstaller ?? Self.installDefaultInputTap
    }

    func inputFormat() -> AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    func installTap(
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat,
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void
    ) throws {
        do {
            try ObjCExceptionBridge.perform { [self] in
                self.inputTapInstaller(self.engine.inputNode, bufferSize, format, onBuffer)
            }
        } catch {
            throw MicCaptureEngineError.inputTapInstallationFailed(error.localizedDescription)
        }
    }

    func removeTap() {
        engine.inputNode.removeTap(onBus: 0)
    }

    func prepare() {
        engine.prepare()
    }

    func start() throws {
        try engine.start()
    }

    func stop() {
        engine.stop()
    }

    private static func installDefaultInputTap(
        inputNode: AVAudioNode,
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat,
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void
    ) {
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in
            onBuffer(buffer)
        }
    }
}

final class MicCaptureService: @unchecked Sendable {
    enum MicError: LocalizedError {
        case permissionDenied
        case noInputNode

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "麦克风权限未授权。"
            case .noInputNode:
                return "未找到可用麦克风输入设备。"
            }
        }
    }

    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    private let engine: MicCaptureEngineProviding
    private let permissionProvider: MicCapturePermissionProviding
    private let controlQueue = DispatchQueue(label: "InsightKit.MicCapture.Control")
    private let controlQueueKey = DispatchSpecificKey<Void>()
    private let captureQueue = DispatchQueue(label: "InsightKit.MicCapture")
    private var isCapturing = false

    init(
        engine: MicCaptureEngineProviding = AVAudioMicCaptureEngine(),
        permissionProvider: MicCapturePermissionProviding = SystemMicCapturePermissionProvider()
    ) {
        self.engine = engine
        self.permissionProvider = permissionProvider
        controlQueue.setSpecific(key: controlQueueKey, value: ())
    }

    func start() async throws {
        guard await permissionProvider.requestPermissionIfNeeded() else {
            throw MicError.permissionDenied
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            controlQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }

                do {
                    try self.startOnControlQueue()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        if DispatchQueue.getSpecific(key: controlQueueKey) != nil {
            stopOnControlQueue()
            return
        }

        controlQueue.sync {
            stopOnControlQueue()
        }
    }

    private func startOnControlQueue() throws {
        guard !isCapturing else { return }

        let inputFormat = engine.inputFormat()
        if inputFormat.channelCount == 0 || inputFormat.sampleRate <= 0 {
            throw MicError.noInputNode
        }

        do {
            engine.removeTap()
            try engine.installTap(bufferSize: 2048, format: inputFormat) { [weak self] buffer in
                guard let self else { return }
                guard let copied = Self.copy(buffer: buffer) else { return }
                self.captureQueue.async {
                    self.onBuffer?(copied)
                }
            }

            engine.prepare()
            try engine.start()
            isCapturing = true
        } catch {
            engine.removeTap()
            engine.stop()
            isCapturing = false
            throw error
        }
    }

    private func stopOnControlQueue() {
        guard isCapturing else { return }
        engine.removeTap()
        engine.stop()
        isCapturing = false
    }

    private static func copy(buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard
            let clone = AVAudioPCMBuffer(
                pcmFormat: buffer.format,
                frameCapacity: buffer.frameCapacity
            )
        else {
            return nil
        }

        clone.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard
                let src = buffer.floatChannelData,
                let dst = clone.floatChannelData
            else {
                return nil
            }
            for c in 0..<channels {
                dst[c].update(from: src[c], count: frameLength)
            }
        case .pcmFormatInt16:
            guard
                let src = buffer.int16ChannelData,
                let dst = clone.int16ChannelData
            else {
                return nil
            }
            for c in 0..<channels {
                dst[c].update(from: src[c], count: frameLength)
            }
        case .pcmFormatInt32:
            guard
                let src = buffer.int32ChannelData,
                let dst = clone.int32ChannelData
            else {
                return nil
            }
            for c in 0..<channels {
                dst[c].update(from: src[c], count: frameLength)
            }
        default:
            return nil
        }

        return clone
    }
}
