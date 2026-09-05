import PDFKit
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

    func testMarkdownExportPrefersInsightPackageAsCanonicalSmartMinutesSource() throws {
        let metadata = try seedRecord()
        try """
        {
          "session_overview":{"title":"Canonical","overview":"Package export overview","topics":["export"]},
          "highlight_insights":[{"quote":"Package quote","reason":"A stronger package detail","speaker":"Alice","evidence_span":{"start_ms":3000,"end_ms":5000}}],
          "speaker_perspectives":[{"speaker":"Alice","viewpoints":["Package speaker viewpoint"],"evidence_spans":[{"start_ms":3000,"end_ms":5000}]}],
          "decision_ledger":[{"problem":"Export source","options":["minutes","package"],"decision":"Use package in export","rationale":"It is canonical","owner":"Alice","needs_review":false,"evidence_span":{"start_ms":3000,"end_ms":5000}}],
          "action_tracks":[{"task":"Export from canonical package","owner":"Alice","due_at":"","priority":"medium","status":"open","needs_review":false,"evidence_span":{"start_ms":3000,"end_ms":5000}}],
          "timeline_beats":[{"timestamp":"00:03","title":"Package export chapter","summary":"Export reads the package."}],
          "provenance_links":[]
        }
        """.write(to: tempRoot.appendingPathComponent("insight_package.json"), atomically: true, encoding: .utf8)

        let markdown = try RecordDocumentExporter.renderMarkdown(metadata: metadata, recordPath: tempRoot)

        XCTAssertTrue(markdown.contains("Package export overview"))
        XCTAssertTrue(markdown.contains("Package quote"))
        XCTAssertTrue(markdown.contains("Alice：Package speaker viewpoint"))
        XCTAssertTrue(markdown.contains("Use package in export"))
        XCTAssertTrue(markdown.contains("Export from canonical package"))
        XCTAssertTrue(markdown.contains("[00:03] Package export chapter：Export reads the package."))
        XCTAssertFalse(markdown.contains("The release export loop is ready."))
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

    func testMarkdownMarksOnlyExplicitlyFlaggedDecisionsAndActionsForReview() throws {
        let metadata = try seedRecordWithMixedReviewStates()

        let markdown = try RecordDocumentExporter.renderMarkdown(metadata: metadata, recordPath: tempRoot)

        XCTAssertTrue(markdown.contains("""
        ## 关键决策

        - Decision requiring review
          - 复核：待复核
        - Decision with false review flag
        - Decision without review flag

        ## 待办事项

        - Action requiring review
          - 复核：待复核
        - Action with false review flag
        - Action without review flag
        """))
        XCTAssertEqual(markdown.components(separatedBy: "复核：待复核").count - 1, 2)
        XCTAssertFalse(markdown.contains("已确认"))
    }

    func testPDFPreservesReviewNoticesFromTheSharedDocumentContent() throws {
        let metadata = try seedRecordWithMixedReviewStates()

        let url = try RecordDocumentExporter.export(format: "pdf", metadata: metadata, recordPath: tempRoot)
        let text = try XCTUnwrap(PDFDocument(url: url)?.string)

        // PDFKit inserts layout whitespace after full-width punctuation.
        let compactText = text.filter { !$0.isWhitespace }
        XCTAssertEqual(compactText.components(separatedBy: "复核：待复核").count - 1, 2)
        for item in [
            "Decision requiring review", "Decision with false review flag", "Decision without review flag",
            "Action requiring review", "Action with false review flag", "Action without review flag",
        ] {
            XCTAssertTrue(text.contains(item))
        }
        XCTAssertFalse(text.contains("已确认"))
    }

    func testPDFKeepsReviewNoticeWithItsItemAtPageBoundary() throws {
        for isAction in [false, true] {
            // These fixtures put the item within one line of the old page boundary.
            for fillerCount in isAction ? [4, 5, 6] : [8, 9, 10] {
                let item = isAction ? "Boundary action" : "Boundary decision"
                let metadata = try seedRecordWithReviewItem(
                    item,
                    overview: Array(repeating: "Summary padding", count: fillerCount).joined(separator: "\n"),
                    isAction: isAction
                )
                let url = try RecordDocumentExporter.export(format: "pdf", metadata: metadata, recordPath: tempRoot)
                let document = try XCTUnwrap(PDFDocument(url: url))
                let itemPage = try XCTUnwrap((0..<document.pageCount).first {
                    document.page(at: $0)?.string?.contains(item) == true
                })
                let text = try XCTUnwrap(document.page(at: itemPage)?.string).filter { !$0.isWhitespace }

                XCTAssertTrue(text.contains("复核：待复核"), "Detached \(item) notice with \(fillerCount) padding lines")
                let allText = try XCTUnwrap(document.string).filter { !$0.isWhitespace }
                XCTAssertEqual(allText.components(separatedBy: "复核：待复核").count - 1, 1)
            }
        }
    }

    func testPDFKeepsWrappedMultilineItemAndItsReviewNoticeTogether() throws {
        let words = (0..<60).map { String(format: "wrapped%03d", $0) }
        let item = words.prefix(30).joined(separator: " ")
            + "\n\n# Item detail\n- Embedded bullet\n"
            + words.suffix(30).joined(separator: " ")
        let metadata = try seedRecordWithReviewItem(
            item,
            overview: Array(repeating: "Summary padding", count: 8).joined(separator: "\n"),
            isAction: true
        )
        let url = try RecordDocumentExporter.export(format: "pdf", metadata: metadata, recordPath: tempRoot)
        let document = try XCTUnwrap(PDFDocument(url: url))
        let itemPages = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.filter { $0.contains("wrapped") }

        XCTAssertEqual(itemPages.count, 1)
        let text = try XCTUnwrap(itemPages.first)
        XCTAssertTrue(text.filter { !$0.isWhitespace }.contains("复核：待复核"))
        XCTAssertTrue(words.allSatisfy { text.contains($0) })
    }

    func testPDFKeepsReviewNoticeOnEveryPageOfAnOversizedItem() throws {
        let words = (0..<1_000).map { String(format: "segment%04d", $0) }
        let metadata = try seedRecordWithReviewItem(words.joined(separator: " "))
        let url = try RecordDocumentExporter.export(format: "pdf", metadata: metadata, recordPath: tempRoot)
        let document = try XCTUnwrap(PDFDocument(url: url))
        var itemPageCount = 0
        var allText = ""
        for pageIndex in 0..<document.pageCount {
            let text = try XCTUnwrap(document.page(at: pageIndex)?.string)
            allText += text + "\n"
            if text.contains("segment") {
                itemPageCount += 1
                XCTAssertTrue(text.filter { !$0.isWhitespace }.contains("复核：待复核"), "Page \(pageIndex + 1)")
            }
            if text.filter({ !$0.isWhitespace }).contains("复核：待复核") {
                XCTAssertTrue(text.contains("segment"), "Review-only page \(pageIndex + 1)")
            }
        }

        XCTAssertGreaterThan(itemPageCount, 1)
        let missing = words.filter { !allText.contains($0) }
        XCTAssertTrue(missing.isEmpty, "Missing \(missing.count) words; first: \(missing.prefix(3))")
    }

    func testPDFDoesNotInferReviewFlagsFromLiteralItemText() throws {
        let words = (0..<1_000).map { String(format: "literal%04d", $0) }
        let item = words.joined(separator: " ") + "\n  - 复核：待复核"
        for isAction in [false, true] {
            for reviewFlag: Bool? in [false, nil] {
                let metadata = try seedRecordWithReviewItem(item, isAction: isAction, reviewFlag: reviewFlag)
                let markdown = try RecordDocumentExporter.renderMarkdown(metadata: metadata, recordPath: tempRoot)
                XCTAssertEqual(markdown.components(separatedBy: "复核：待复核").count - 1, 1)

                let url = try RecordDocumentExporter.export(format: "pdf", metadata: metadata, recordPath: tempRoot)
                let text = try XCTUnwrap(PDFDocument(url: url)?.string).filter { !$0.isWhitespace }
                XCTAssertEqual(
                    text.components(separatedBy: "复核：待复核").count - 1, 1,
                    "Literal content must not create review flags: action=\(isAction), flag=\(String(describing: reviewFlag))"
                )
            }
        }
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

    private func seedRecordWithMixedReviewStates() throws -> RecordMetadata {
        let metadata = try seedRecord()
        try """
        {
          "session_overview":{"title":"Review flags","overview":"Mixed review state export","topics":[]},
          "highlight_insights":[],
          "speaker_perspectives":[],
          "decision_ledger":[
            {"problem":"Pending","options":[],"decision":"Decision requiring review","rationale":"Unverified","owner":"Alice","needs_review":true,"evidence_span":{"start_ms":1000,"end_ms":2000}},
            {"problem":"False flag","options":[],"decision":"Decision with false review flag","rationale":"Existing content","owner":"Bob","needs_review":false,"evidence_span":{"start_ms":2000,"end_ms":3000}},
            {"problem":"Legacy","options":[],"decision":"Decision without review flag","rationale":"Existing content","owner":"Carol","evidence_span":{"start_ms":3000,"end_ms":4000}}
          ],
          "action_tracks":[
            {"task":"Action requiring review","owner":"Alice","due_at":"next week","priority":"high","status":"open","needs_review":true,"evidence_span":{"start_ms":4000,"end_ms":5000}},
            {"task":"Action with false review flag","owner":"Bob","due_at":"","priority":"low","status":"completed","needs_review":false,"evidence_span":{"start_ms":5000,"end_ms":6000}},
            {"task":"Action without review flag","owner":"Carol","due_at":"","priority":"medium","status":"in_progress","evidence_span":{"start_ms":6000,"end_ms":7000}}
          ],
          "timeline_beats":[],
          "provenance_links":[]
        }
        """.write(to: tempRoot.appendingPathComponent("insight_package.json"), atomically: true, encoding: .utf8)
        return metadata
    }

    private func seedRecordWithReviewItem(
        _ decision: String,
        overview: String = "Review pagination",
        isAction: Bool = false,
        reviewFlag: Bool? = true
    ) throws -> RecordMetadata {
        let metadata = try seedRecord()
        var decisionItem: [String: Any] = [
            "problem": "Pagination", "options": [], "decision": decision, "rationale": "Unverified",
            "owner": "Alice", "evidence_span": ["start_ms": 1000, "end_ms": 2000],
        ]
        var actionItem: [String: Any] = [
            "task": decision, "owner": "Alice", "due_at": "", "priority": "medium", "status": "open",
            "evidence_span": ["start_ms": 1000, "end_ms": 2000],
        ]
        if let reviewFlag {
            decisionItem["needs_review"] = reviewFlag
            actionItem["needs_review"] = reviewFlag
        }
        let package: [String: Any] = [
            "session_overview": ["title": "Review pagination", "overview": overview, "topics": []],
            "highlight_insights": [],
            "speaker_perspectives": [],
            "decision_ledger": isAction ? [] : [decisionItem],
            "action_tracks": isAction ? [actionItem] : [],
            "timeline_beats": [],
            "provenance_links": [],
        ]
        try JSONSerialization.data(withJSONObject: package).write(to: tempRoot.appendingPathComponent("insight_package.json"))
        return metadata
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
