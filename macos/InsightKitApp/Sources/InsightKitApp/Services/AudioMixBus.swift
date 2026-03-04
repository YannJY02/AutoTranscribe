import AVFoundation
import Foundation

final class AudioMixBus {
    enum Source {
        case microphone
        case systemAudio
    }

    struct Config {
        var targetSampleRate: Double = 16_000
        var micWeight: Float = 0.6
        var systemWeight: Float = 0.6
        var mixedTailFlushSamples: Int = 8_000
    }

    var onMixedSamples: (([Float]) -> Void)?

    private let queue = DispatchQueue(label: "InsightKit.AudioMixBus")
    private let config: Config
    private let targetFormat: AVAudioFormat

    private var mode: AudioInputMode = .microphone
    private var pendingMic: [Float] = []
    private var pendingSystem: [Float] = []
    private var converters: [String: AVAudioConverter] = [:]

    init(config: Config = Config()) {
        self.config = config
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: config.targetSampleRate,
            channels: 1,
            interleaved: false
        )!
    }

    func setMode(_ mode: AudioInputMode) {
        queue.async {
            self.mode = mode
            self.pendingMic.removeAll(keepingCapacity: true)
            self.pendingSystem.removeAll(keepingCapacity: true)
        }
    }

    func ingestMicrophone(_ buffer: AVAudioPCMBuffer) {
        ingest(buffer: buffer, source: .microphone)
    }

    func ingestSystemAudio(_ buffer: AVAudioPCMBuffer) {
        ingest(buffer: buffer, source: .systemAudio)
    }

    private func ingest(buffer: AVAudioPCMBuffer, source: Source) {
        queue.async {
            guard let mono = self.convertToTargetSamples(buffer) else { return }
            guard !mono.isEmpty else { return }

            switch self.mode {
            case .microphone:
                if source == .microphone {
                    self.onMixedSamples?(mono)
                }
            case .systemAudio:
                if source == .systemAudio {
                    self.onMixedSamples?(mono)
                }
            case .mixed:
                self.mixIn(source: source, samples: mono)
            }
        }
    }

    private func mixIn(source: Source, samples: [Float]) {
        switch source {
        case .microphone:
            pendingMic.append(contentsOf: samples)
        case .systemAudio:
            pendingSystem.append(contentsOf: samples)
        }

        let overlapCount = min(pendingMic.count, pendingSystem.count)
        if overlapCount > 0 {
            var out: [Float] = []
            out.reserveCapacity(overlapCount)
            for idx in 0..<overlapCount {
                let value = pendingMic[idx] * config.micWeight + pendingSystem[idx] * config.systemWeight
                out.append(Self.clamp(value))
            }
            pendingMic.removeFirst(overlapCount)
            pendingSystem.removeFirst(overlapCount)
            onMixedSamples?(out)
        }

        // 防止两路采样回调节奏差异导致长时间积压。
        flushTailIfNeeded()
    }

    private func flushTailIfNeeded() {
        if pendingMic.count > config.mixedTailFlushSamples {
            let flushCount = pendingMic.count - config.mixedTailFlushSamples
            let tail = pendingMic.prefix(flushCount).map { Self.clamp($0 * config.micWeight) }
            pendingMic.removeFirst(flushCount)
            onMixedSamples?(tail)
        }

        if pendingSystem.count > config.mixedTailFlushSamples {
            let flushCount = pendingSystem.count - config.mixedTailFlushSamples
            let tail = pendingSystem.prefix(flushCount).map { Self.clamp($0 * config.systemWeight) }
            pendingSystem.removeFirst(flushCount)
            onMixedSamples?(tail)
        }
    }

    private func convertToTargetSamples(_ input: AVAudioPCMBuffer) -> [Float]? {
        if input.format.sampleRate == targetFormat.sampleRate,
           input.format.channelCount == targetFormat.channelCount,
           input.format.commonFormat == .pcmFormatFloat32,
           !input.format.isInterleaved,
           let channel = input.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: channel, count: Int(input.frameLength)))
        }

        let key = formatKey(input.format)
        let converter: AVAudioConverter
        if let cached = converters[key] {
            converter = cached
        } else {
            guard let created = AVAudioConverter(from: input.format, to: targetFormat) else {
                return nil
            }
            converters[key] = created
            converter = created
        }

        converter.reset()

        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let outputCapacity = max(64, Int((Double(input.frameLength) * ratio).rounded(.up)) + 16)
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(outputCapacity)) else {
            return nil
        }

        var convertError: NSError?
        var consumed = false
        let status = converter.convert(to: output, error: &convertError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }

        if status == .error || convertError != nil {
            return nil
        }

        guard let channel = output.floatChannelData?[0], output.frameLength > 0 else {
            return []
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    private func formatKey(_ format: AVAudioFormat) -> String {
        let sd = format.streamDescription.pointee
        return "\(format.sampleRate)-\(format.channelCount)-\(format.commonFormat.rawValue)-\(format.isInterleaved)-\(sd.mFormatFlags)-\(sd.mBytesPerFrame)"
    }

    private static func clamp(_ value: Float) -> Float {
        min(max(value, -1), 1)
    }
}
