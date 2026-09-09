import Foundation
import XCTest
@testable import LiveDiarizationCore

final class WAVReaderTests: XCTestCase {
    private func wav(samples: [UInt32], float: Bool = false, channels: UInt16 = 1, rate: UInt32 = 16_000) -> Data {
        var data = Data()
        func u16(_ value: UInt16) {
            data.append(UInt8(truncatingIfNeeded: value))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        func u32(_ value: UInt32) {
            for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        let sampleBytes: UInt16 = float ? 4 : 2
        data.append(contentsOf: "RIFF".utf8)
        u32(36 + UInt32(samples.count) * UInt32(sampleBytes))
        data.append(contentsOf: "WAVEfmt ".utf8)
        u32(16)
        u16(float ? 3 : 1)
        u16(channels)
        u32(rate)
        u32(rate * UInt32(sampleBytes) * UInt32(channels))
        u16(sampleBytes * channels)
        u16(sampleBytes * 8)
        data.append(contentsOf: "data".utf8)
        u32(UInt32(samples.count) * UInt32(sampleBytes))
        for sample in samples {
            if float { u32(sample) } else { u16(UInt16(truncatingIfNeeded: sample)) }
        }
        return data
    }

    func testPCM16AndFloat32Decode() throws {
        let reader = WAVReader()
        XCTAssertEqual(try reader.decode(wav(samples: [0, 16_384, 32_768]), maxSamples: 10), [0, 0.5, -1])
        XCTAssertEqual(try reader.decode(wav(samples: [Float(0.25).bitPattern], float: true), maxSamples: 10), [0.25])
    }

    func testWrongFormatTruncationEmptyAndOversizedAudioAreRejected() {
        let reader = WAVReader()
        let inputs = [
            wav(samples: [0, 0], channels: 2),
            wav(samples: [0], rate: 8_000),
            Data(wav(samples: [0, 1]).dropLast()),
            wav(samples: []),
            wav(samples: [0, 1, 2]),
            wav(samples: [Float.nan.bitPattern], float: true),
            wav(samples: [Float.infinity.bitPattern], float: true),
            wav(samples: [Float(1.1).bitPattern], float: true),
        ]
        for input in inputs {
            XCTAssertThrowsError(try reader.decode(input, maxSamples: 2)) { error in
                XCTAssertEqual((error as? WorkerFailure)?.code, "invalid_audio")
            }
        }
    }

    func testLocalFileReadAndPathBounds() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("diarization-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try wav(samples: [16_384]).write(to: url)
        XCTAssertEqual(try WAVReader().read(path: url.path, maxSamples: 2), [0.5])
        for path in ["relative.wav", "https://example.com/audio.wav", "/tmp/audio.mp3"] {
            XCTAssertThrowsError(try WAVReader().read(path: path, maxSamples: 2)) { error in
                XCTAssertEqual((error as? WorkerFailure)?.code, "invalid_audio_path")
            }
        }
    }
}
