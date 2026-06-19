import Foundation

struct AudioChunk: Hashable {
    let index: Int
    let url: URL
    let startMs: Int
    let endMs: Int
    let rms: Float

    var isLikelySilent: Bool {
        rms < 0.015
    }
}

final class ChunkAssembler {
    enum ChunkError: LocalizedError {
        case cannotCreateDirectory
        case cannotWriteChunk

        var errorDescription: String? {
            switch self {
            case .cannotCreateDirectory:
                return "无法创建实时 chunk 目录。"
            case .cannotWriteChunk:
                return "写入实时 chunk 文件失败。"
            }
        }
    }

    let sampleRate: Int
    let chunkDurationSec: Double

    private let chunkDir: URL
    private let steadyChunkSamples: Int
    private let firstChunkSamples: Int
    private let maxRetainedChunkFiles: Int
    private var pending: [Float] = []
    private var emittedSamples: Int = 0
    private var chunkIndex: Int = 0
    private var createdChunkURLs: [URL] = []

    init(
        chunkDurationSec: Double = 8,
        firstChunkDurationSec: Double = 2,
        sampleRate: Int = 16_000,
        chunkDir: URL? = nil,
        maxRetainedChunkFiles: Int = 1_800
    ) {
        self.chunkDurationSec = chunkDurationSec
        self.sampleRate = sampleRate
        self.steadyChunkSamples = max(1, Int(chunkDurationSec * Double(sampleRate)))
        self.firstChunkSamples = max(1, Int(firstChunkDurationSec * Double(sampleRate)))
        self.maxRetainedChunkFiles = max(20, maxRetainedChunkFiles)

        if let chunkDir {
            self.chunkDir = chunkDir
        } else {
            self.chunkDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("insightkit-live-chunks", isDirectory: true)
        }
    }

    func reset() {
        pending.removeAll(keepingCapacity: true)
        emittedSamples = 0
        chunkIndex = 0
        cleanupAllChunkFiles()
        createdChunkURLs.removeAll(keepingCapacity: true)
    }

    func append(samples: [Float]) throws -> [AudioChunk] {
        guard !samples.isEmpty else { return [] }
        try ensureChunkDir()
        pending.append(contentsOf: samples)

        var chunks: [AudioChunk] = []
        while pending.count >= currentChunkSamplesTarget() {
            let target = currentChunkSamplesTarget()
            let chunkData = Array(pending.prefix(target))
            pending.removeFirst(target)
            chunks.append(try emitChunk(samples: chunkData))
        }
        return chunks
    }

    func flush(minDurationSec: Double = 1.0) throws -> [AudioChunk] {
        try ensureChunkDir()
        let minSamples = Int(minDurationSec * Double(sampleRate))
        guard pending.count >= minSamples else { return [] }
        let chunkData = pending
        pending.removeAll(keepingCapacity: true)
        return [try emitChunk(samples: chunkData)]
    }

    func writeCombinedWAV(to outputURL: URL) -> URL? {
        let wavFiles = createdChunkURLs.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        guard !wavFiles.isEmpty else { return nil }
        guard let firstData = try? Data(contentsOf: wavFiles[0]), firstData.count > 44 else {
            return nil
        }

        var pcm = Data()
        for file in wavFiles {
            guard let data = try? Data(contentsOf: file), data.count > 44 else { continue }
            pcm.append(data.subdata(in: 44..<data.count))
        }
        guard !pcm.isEmpty else { return nil }

        do {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var header = firstData.subdata(in: 0..<44)
            let fileSize = UInt32(44 + pcm.count - 8)
            let dataSize = UInt32(pcm.count)
            header.replaceSubrange(4..<8, with: withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
            header.replaceSubrange(40..<44, with: withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })

            var result = header
            result.append(pcm)
            try result.write(to: outputURL, options: .atomic)
            return outputURL
        } catch {
            return nil
        }
    }

    private func ensureChunkDir() throws {
        var isDir: ObjCBool = false
        let path = chunkDir.path
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
            if isDir.boolValue {
                return
            }
            throw ChunkError.cannotCreateDirectory
        }
        do {
            try FileManager.default.createDirectory(at: chunkDir, withIntermediateDirectories: true)
        } catch {
            throw ChunkError.cannotCreateDirectory
        }
    }

    private func emitChunk(samples: [Float]) throws -> AudioChunk {
        let rms = computeRMS(samples)
        let startMs = Int((Double(emittedSamples) / Double(sampleRate)) * 1000)
        emittedSamples += samples.count
        let endMs = Int((Double(emittedSamples) / Double(sampleRate)) * 1000)

        let name = String(format: "chunk_%06d_%d_%d.wav", chunkIndex, startMs, endMs)
        let url = chunkDir.appendingPathComponent(name)
        chunkIndex += 1

        let wav = makeWAV(samples: samples, sampleRate: sampleRate)
        do {
            try wav.write(to: url, options: .atomic)
        } catch {
            throw ChunkError.cannotWriteChunk
        }
        createdChunkURLs.append(url)
        cleanupOverflowChunkFilesIfNeeded()

        return AudioChunk(index: chunkIndex - 1, url: url, startMs: startMs, endMs: endMs, rms: rms)
    }

    private func currentChunkSamplesTarget() -> Int {
        chunkIndex == 0 ? firstChunkSamples : steadyChunkSamples
    }

    private func computeRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var energy: Float = 0
        for sample in samples {
            energy += sample * sample
        }
        return sqrt(energy / Float(samples.count))
    }

    private func cleanupOverflowChunkFilesIfNeeded() {
        if createdChunkURLs.count <= maxRetainedChunkFiles {
            return
        }
        let overflow = createdChunkURLs.count - maxRetainedChunkFiles
        let stale = createdChunkURLs.prefix(overflow)
        for url in stale {
            try? FileManager.default.removeItem(at: url)
        }
        createdChunkURLs.removeFirst(overflow)
    }

    private func cleanupAllChunkFiles() {
        for url in createdChunkURLs {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func makeWAV(samples: [Float], sampleRate: Int) -> Data {
        let bytesPerSample = 2
        let channels = 1
        let byteRate = sampleRate * channels * bytesPerSample
        let blockAlign = channels * bytesPerSample
        let dataSize = samples.count * bytesPerSample

        var data = Data(capacity: 44 + dataSize)

        func appendASCII(_ str: String) {
            data.append(str.data(using: .ascii)!)
        }

        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { bytes in
                data.append(bytes.bindMemory(to: UInt8.self))
            }
        }

        appendASCII("RIFF")
        appendLE(UInt32(36 + dataSize))
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendLE(UInt32(16))
        appendLE(UInt16(1))
        appendLE(UInt16(channels))
        appendLE(UInt32(sampleRate))
        appendLE(UInt32(byteRate))
        appendLE(UInt16(blockAlign))
        appendLE(UInt16(16))
        appendASCII("data")
        appendLE(UInt32(dataSize))

        for sample in samples {
            let clamped = min(max(sample, -1), 1)
            let int16 = Int16(clamped * Float(Int16.max))
            appendLE(UInt16(bitPattern: int16))
        }

        return data
    }
}
