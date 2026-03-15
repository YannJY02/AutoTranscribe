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
    }
}
