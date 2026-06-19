import XCTest
@testable import InsightKitApp

final class RecordDocumentExporterTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("InsightKitRecordExportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try super.tearDownWithError()
    }

    func testExportsReadableMarkdownFromPersistedRecordFolder() throws {
        let metadata = try seedRecord()

        let url = try RecordDocumentExporter.export(
            format: "markdown",
            metadata: metadata,
            recordPath: tempRoot
        )

        let markdown = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(markdown.contains("AI 免责声明"))
        XCTAssertTrue(markdown.contains("## 长文版结构化总结"))
        XCTAssertTrue(markdown.contains("## 会议金句"))
        XCTAssertTrue(markdown.contains("## 发言人总结"))
        XCTAssertTrue(markdown.contains("## 关键决策"))
        XCTAssertTrue(markdown.contains("## 待办事项"))
        XCTAssertTrue(markdown.contains("## 智能章节"))
        XCTAssertTrue(markdown.contains("## 带时间戳逐字稿"))
        XCTAssertTrue(markdown.contains("[00:03] export note"))
    }

    func testExportsPDFWithPDFHeader() throws {
        let metadata = try seedRecord()

        let url = try RecordDocumentExporter.export(
            format: "pdf",
            metadata: metadata,
            recordPath: tempRoot
        )

        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 4)
        XCTAssertEqual(String(data: data.prefix(5), encoding: .utf8), "%PDF-")
    }

    func testRecordReviewNotesUseCurrentPlaybackTime() throws {
        let metadata = try seedRecord()
        let dataSource = RecordReviewDataSource(metadata: metadata, rootDirectory: tempRoot.deletingLastPathComponent())
        dataSource.currentPlaybackTime = 42

        dataSource.onNoteCreated("time-bound", at: dataSource.recordingTime)

        XCTAssertEqual(dataSource.notes.last?.timestamp, 42)
    }

    func testRecordReviewShowsExportFailureStatusForUnsupportedFormat() throws {
        let metadata = try seedRecord()
        let dataSource = RecordReviewDataSource(metadata: metadata, rootDirectory: tempRoot.deletingLastPathComponent())

        dataSource.exportRecord(format: "docx")

        XCTAssertNil(dataSource.lastExportURL)
        XCTAssertEqual(
            dataSource.exportStatusMessage,
            "导出失败：不支持的导出格式：docx"
        )
    }

    private func seedRecord() throws -> RecordMetadata {
        try "{}".write(to: tempRoot.appendingPathComponent("recording.m4a"), atomically: true, encoding: .utf8)
        try """
        {
          "structured_summary": "The release export loop is ready.",
          "highlights": ["Keep the local archive readable."],
          "key_decisions": ["Ship local export first."],
          "action_items": ["Verify Markdown and PDF exports."],
          "timeline_beats": [
            {"timestamp":"00:03","title":"Export proof","summary":"The app writes archive-ready files."}
          ]
        }
        """.write(to: tempRoot.appendingPathComponent("minutes.json"), atomically: true, encoding: .utf8)
        try """
        [
          {"start_ms":3000,"end_ms":5000,"speaker":"SPEAKER_00","text":"Export evidence is readable."}
        ]
        """.write(to: tempRoot.appendingPathComponent("transcript.json"), atomically: true, encoding: .utf8)
        try "00:03 export note".write(to: tempRoot.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)

        return RecordMetadata(
            id: tempRoot.lastPathComponent,
            createdAt: Date(timeIntervalSince1970: 1_779_520_000),
            duration: 65,
            mediaType: .audio,
            source: .imported,
            userTags: ["release"],
            autoTags: ["export"],
            summaryPreview: "Export fixture"
        )
    }
}
