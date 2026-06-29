import XCTest
@testable import InsightKitApp

final class ChunkAssemblerTests: XCTestCase {
    func testFirstChunkTwoSecondsThenSteadySixSecondsAndFlush() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ChunkAssemblerTests_\(UUID().uuidString)", isDirectory: true)

        let assembler = ChunkAssembler(chunkDurationSec: 6, sampleRate: 16_000, chunkDir: tmp)
        let samplesA = Array(repeating: Float(0.1), count: 40_000)
        let chunksA = try assembler.append(samples: samplesA)

        XCTAssertEqual(chunksA.count, 1)
        XCTAssertEqual(chunksA[0].startMs, 0)
        XCTAssertEqual(chunksA[0].endMs, 2_000)

        let samplesB = Array(repeating: Float(0.2), count: 100_000)
        let chunksB = try assembler.append(samples: samplesB)

        XCTAssertEqual(chunksB.count, 1)
        XCTAssertEqual(chunksB[0].startMs, 2_000)
        XCTAssertEqual(chunksB[0].endMs, 8_000)

        let tail = try assembler.flush(minDurationSec: 0.1)
        XCTAssertEqual(tail.count, 1)
        XCTAssertEqual(tail[0].startMs, 8_000)
        XCTAssertEqual(tail[0].endMs, 8_750)

        XCTAssertTrue(FileManager.default.fileExists(atPath: chunksA[0].url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: chunksB[0].url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tail[0].url.path))

        let combinedURL = tmp.appendingPathComponent("recording.wav")
        let resultURL = try XCTUnwrap(assembler.writeCombinedWAV(to: combinedURL))
        XCTAssertEqual(resultURL, combinedURL)
        let data = try Data(contentsOf: combinedURL)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data.subdata(in: 8..<12), encoding: .ascii), "WAVE")
        XCTAssertEqual(data.count, 44 + (140_000 * 2))
    }

    func testWAVWriterAvoidsFullScaleClippingForOverRangeSamples() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ChunkAssemblerTests_\(UUID().uuidString)", isDirectory: true)

        let assembler = ChunkAssembler(
            chunkDurationSec: 1,
            firstChunkDurationSec: 0.1,
            sampleRate: 16_000,
            chunkDir: tmp
        )
        _ = try assembler.append(samples: Array(repeating: Float(1.3), count: 1_600))

        let combinedURL = tmp.appendingPathComponent("recording.wav")
        _ = try XCTUnwrap(assembler.writeCombinedWAV(to: combinedURL))
        let samples = try readInt16Samples(from: combinedURL)

        XCTAssertFalse(samples.contains(Int16.max))
        XCTAssertLessThan(samples.map { abs(Int($0)) }.max() ?? 0, Int(Int16.max))
    }

    func testAudibleContentIgnoresNearDigitalSilence() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ChunkAssemblerTests_\(UUID().uuidString)", isDirectory: true)
        let assembler = ChunkAssembler(
            chunkDurationSec: 1,
            firstChunkDurationSec: 0.1,
            sampleRate: 16_000,
            chunkDir: tmp
        )

        _ = try assembler.append(samples: Array(repeating: Float(0.00002), count: 1_600))

        XCTAssertFalse(assembler.hasAudibleContent())

        _ = try assembler.append(samples: Array(repeating: Float(0.02), count: 16_000))

        XCTAssertTrue(assembler.hasAudibleContent())
    }

    private func readInt16Samples(from url: URL) throws -> [Int16] {
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 44)
        return stride(from: 44, to: data.count, by: 2).map { offset in
            let value = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
            return Int16(bitPattern: value)
        }
    }
}
