import AVFoundation
import Foundation

final class MicCaptureService {
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

    private let engine = AVAudioEngine()
    private let captureQueue = DispatchQueue(label: "InsightKit.MicCapture")
    private var isCapturing = false

    func start() async throws {
        guard await requestPermissionIfNeeded() else {
            throw MicError.permissionDenied
        }

        guard !isCapturing else { return }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        if inputFormat.channelCount == 0 {
            throw MicError.noInputNode
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard let copied = Self.copy(buffer: buffer) else { return }
            self.captureQueue.async {
                self.onBuffer?(copied)
            }
        }

        engine.prepare()
        try engine.start()
        isCapturing = true
    }

    func stop() {
        guard isCapturing else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isCapturing = false
    }

    private func requestPermissionIfNeeded() async -> Bool {
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
