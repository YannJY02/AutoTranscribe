import Foundation

public protocol AudioReading {
    func read(path: String, maxSamples: Int) throws -> [Float]
}

/// Accepts the worker's interchange format: RIFF/WAVE, mono 16 kHz PCM16 or float32.
/// Decode completely before feeding the model, including RIFF lengths and finite samples.
public struct WAVReader: AudioReading {
    public init() {}

    public func read(path: String, maxSamples: Int) throws -> [Float] {
        guard path.hasPrefix("/"), path.utf8.count <= 4_096, !path.contains("\0"),
            URL(fileURLWithPath: path).pathExtension.lowercased() == "wav"
        else { throw WorkerFailure("invalid_audio_path", "wav_path must be an absolute local .wav path") }

        let url = URL(fileURLWithPath: path)
        let maxBytes = maxSamples * 4 + 65_536
        let data: Data
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize,
                size > 0, size <= maxBytes
            else { throw WorkerFailure("invalid_audio", "WAV must be a regular file within the chunk size limit") }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            data = try handle.read(upToCount: maxBytes + 1) ?? Data()
            guard data.count <= maxBytes else {
                throw WorkerFailure("invalid_audio", "WAV exceeds the chunk size limit")
            }
        } catch let failure as WorkerFailure {
            throw failure
        } catch {
            throw WorkerFailure("audio_read_failed", "Cannot read WAV: \(error.localizedDescription)")
        }
        return try decode(data, maxSamples: maxSamples)
    }

    func decode(_ data: Data, maxSamples: Int) throws -> [Float] {
        func invalid(_ message: String) -> WorkerFailure { WorkerFailure("invalid_audio", message) }
        func tag(_ start: Int, _ text: String) -> Bool {
            data[start..<(start + 4)].elementsEqual(text.utf8)
        }
        func u16(_ offset: Int) -> UInt16 {
            UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
        }
        func u32(_ offset: Int) -> UInt32 {
            UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
                | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
        }
        guard data.count >= 12, tag(0, "RIFF"), tag(8, "WAVE"),
            Int(u32(4)) == data.count - 8
        else { throw invalid("WAV must have a complete RIFF/WAVE header and payload") }

        var format: (code: UInt16, sampleBytes: Int)?
        var audio: Range<Int>?
        var cursor = 12
        while cursor < data.count {
            guard data.count - cursor >= 8 else { throw invalid("Truncated WAV chunk header") }
            let size = Int(u32(cursor + 4))
            let start = cursor + 8
            guard size <= data.count - start else { throw invalid("Truncated WAV chunk payload") }
            if tag(cursor, "fmt ") {
                guard format == nil, size >= 16 else { throw invalid("Invalid WAV format chunk") }
                let code = u16(start)
                let bits = u16(start + 14)
                guard (code == 1 && bits == 16) || (code == 3 && bits == 32) else {
                    throw invalid("WAV encoding must be PCM16 or IEEE float32")
                }
                let sampleBytes = Int(bits / 8)
                guard u16(start + 2) == 1, u32(start + 4) == 16_000,
                    Int(u16(start + 12)) == sampleBytes,
                    Int(u32(start + 8)) == sampleBytes * 16_000
                else { throw invalid("WAV must be mono 16 kHz with consistent frame sizes") }
                format = (code, sampleBytes)
            } else if tag(cursor, "data") {
                guard audio == nil else { throw invalid("WAV must contain one audio data chunk") }
                audio = start..<(start + size)
            }
            cursor = start + size + size % 2
            guard cursor <= data.count else { throw invalid("Missing WAV chunk padding") }
        }
        guard let format, let audio, !audio.isEmpty,
            audio.count % format.sampleBytes == 0
        else { throw invalid("WAV is missing complete format or audio data") }
        let count = audio.count / format.sampleBytes
        guard count <= maxSamples else { throw invalid("WAV duration exceeds the chunk limit") }
        var samples: [Float] = []
        samples.reserveCapacity(count)
        for offset in stride(from: audio.lowerBound, to: audio.upperBound, by: format.sampleBytes) {
            let sample = format.code == 1
                ? Float(Int16(bitPattern: u16(offset))) / 32_768
                : Float(bitPattern: u32(offset))
            guard sample.isFinite, abs(sample) <= 1 else {
                throw invalid("WAV contains non-finite or unnormalized samples")
            }
            samples.append(sample)
        }
        return samples
    }
}
