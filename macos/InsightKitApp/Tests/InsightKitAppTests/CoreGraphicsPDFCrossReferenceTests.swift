import Foundation
import XCTest
@testable import InsightKitApp

final class CoreGraphicsPDFCrossReferenceTests: XCTestCase {
    func testValidClassicPDFIsByteForByteUnchanged() throws {
        let fixture = makePDF()

        let repaired = try CoreGraphicsPDFCrossReference.repairUnusedEntries(in: fixture.data)

        XCTAssertEqual(repaired, fixture.data)
    }

    func testMultipleUnusedZeroOffsetEntriesBecomeRetiredFreeEntriesWithoutChangingOtherBytes() throws {
        let fixture = makePDF(unusedEntryCount: 2)

        let repaired = try CoreGraphicsPDFCrossReference.repairUnusedEntries(in: fixture.data)

        XCTAssertEqual(repaired.count, fixture.data.count)
        XCTAssertEqual(repaired, fixture.expectedRepair)
        guard repaired.count == fixture.data.count else { return }
        let changedOffsets = fixture.data.indices.filter { repaired[$0] != fixture.data[$0] }
        let unusedEntryOffsets = Set(fixture.unusedEntryRanges.flatMap { Array($0) })
        XCTAssertFalse(changedOffsets.isEmpty)
        XCTAssertTrue(changedOffsets.allSatisfy { unusedEntryOffsets.contains($0) })
        XCTAssertEqual(
            repaired.subdata(in: 0..<fixture.xrefOffset),
            fixture.data.subdata(in: 0..<fixture.xrefOffset)
        )
    }

    func testXrefLikeStreamAndLiteralContentAreNotTreatedAsTablesOrReferences() throws {
        // Both a page-content string inside a stream and the Info title carry
        // these bytes. The fake reference must not make real slot 7 live.
        let decoy = """
        xref
        0 2
        0000000000 65535 f\u{20}
        0000000000 00000 n\u{20}
        trailer
        << /Size 2 /Root 7 0 R >>
        startxref
        0
        %%EOF
        """
        let fixture = makePDF(unusedEntryCount: 2, decoy: decoy)

        let repaired = try CoreGraphicsPDFCrossReference.repairUnusedEntries(in: fixture.data)

        XCTAssertEqual(repaired, fixture.expectedRepair)
        guard repaired.count == fixture.data.count else { return }
        XCTAssertEqual(
            repaired.subdata(in: 0..<fixture.xrefOffset),
            fixture.data.subdata(in: 0..<fixture.xrefOffset),
            "All object and stream bytes, including the decoy tables and references, must survive verbatim"
        )
    }

    func testARealReferenceToAZeroOffsetEntryIsRejected() {
        let fixture = makePDF(unusedEntryCount: 2, referencesMissingObject: true)

        XCTAssertThrowsError(try CoreGraphicsPDFCrossReference.repairUnusedEntries(in: fixture.data))
    }

    func testTruncatedStartxrefIsRejected() {
        let fixture = makePDF(unusedEntryCount: 2)
        let truncated = Data(fixture.data.prefix(fixture.startxrefValueRange.lowerBound))

        XCTAssertThrowsError(try CoreGraphicsPDFCrossReference.repairUnusedEntries(in: truncated))
    }

    func testInvalidStartxrefTargetsAreNotReplacedByAGuessedTable() {
        let fixture = makePDF(unusedEntryCount: 2)
        for invalidTarget in [0, fixture.data.count + 1_024] {
            var damaged = fixture.data
            damaged.replaceSubrange(
                fixture.startxrefValueRange,
                with: Data(String(invalidTarget).utf8)
            )

            XCTAssertThrowsError(
                try CoreGraphicsPDFCrossReference.repairUnusedEntries(in: damaged),
                "Invalid startxref target \(invalidTarget) must not trigger a scan for another table"
            )
        }
    }

    private struct Fixture {
        let data: Data
        let xrefOffset: Int
        let startxrefValueRange: Range<Int>
        let unusedEntryRanges: [Range<Int>]

        var expectedRepair: Data {
            var expected = data
            for range in unusedEntryRanges {
                // A retired free entry points to object zero with generation
                // 65535, without requiring changes to the free-list chain.
                expected.replaceSubrange(range, with: Data("0000000000 65535 f \n".utf8))
            }
            return expected
        }
    }

    private func makePDF(
        unusedEntryCount: Int = 0,
        referencesMissingObject: Bool = false,
        decoy: String? = nil
    ) -> Fixture {
        // A complete one-page classic PDF with an uncompressed content stream.
        // Offsets are recorded while writing the fixture, without parsing it.
        let text = decoy ?? "Synthetic PDF fixture"
        let content = "BT\n/F1 12 Tf\n72 720 Td\n(\(text)) Tj\nET\n"
        let missingReference = referencesMissingObject ? " /Metadata 7 0 R" : ""
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R\(missingReference) >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Title (\(text)) >>",
        ]
        var data = Data("%PDF-1.4\n".utf8)
        var objectOffsets: [Int] = []
        for (index, object) in objects.enumerated() {
            objectOffsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }

        let xrefOffset = data.count
        let size = objects.count + unusedEntryCount + 1
        data.append(Data("xref\n0 \(size)\n0000000000 65535 f \n".utf8))
        for offset in objectOffsets {
            data.append(Data(String(format: "%010ld 00000 n \n", offset).utf8))
        }
        var unusedEntryRanges: [Range<Int>] = []
        for _ in 0..<unusedEntryCount {
            let entryStart = data.count
            data.append(Data("0000000000 00000 n \n".utf8))
            unusedEntryRanges.append(entryStart..<data.count)
        }
        data.append(Data("trailer\n<< /Size \(size) /Root 1 0 R /Info 6 0 R >>\nstartxref\n".utf8))
        let valueStart = data.count
        data.append(Data(String(xrefOffset).utf8))
        let valueEnd = data.count
        data.append(Data("\n%%EOF\n".utf8))
        return Fixture(
            data: data,
            xrefOffset: xrefOffset,
            startxrefValueRange: valueStart..<valueEnd,
            unusedEntryRanges: unusedEntryRanges
        )
    }
}
