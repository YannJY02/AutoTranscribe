import XCTest

final class RecordsPersistenceUITests: InsightKitUITests {
    private var tempRoot: URL!
    private let seedRecordID = "record-restart-proof"

    override var launchEnvironmentOverrides: [String: String] {
        guard let tempRoot else { return [:] }
        return ["INSIGHTKIT_RECORDS_ROOT": tempRoot.path]
    }

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("InsightKitRecordsUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try seedPersistedRecord()
        try super.setUpWithError()
    }

    override func tearDownWithError() throws {
        try super.tearDownWithError()
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
    }

    func testRecentRecordSearchAndRelaunchPersistence() throws {
        XCTAssertTrue(waitForElement(app.staticTexts["home_title"], timeout: 5))
        XCTAssertTrue(waitForElement(app.buttons["home_recent_record_\(seedRecordID)"], timeout: 5))

        app.buttons["home_recent_record_\(seedRecordID)"].firstMatch.tap()
        XCTAssertTrue(waitForElement(app.buttons["record_list_item_\(seedRecordID)"], timeout: 5))

        let searchField = app.textFields["records_search_field"]
        XCTAssertTrue(waitForElement(searchField, timeout: 5))
        enterText("restart", into: searchField)
        XCTAssertTrue(waitForElement(app.buttons["record_list_item_\(seedRecordID)"], timeout: 5))

        app.terminate()
        app.launch()
        app.activate()

        XCTAssertTrue(waitForElement(app.staticTexts["home_title"], timeout: 5))
        XCTAssertTrue(waitForElement(app.buttons["home_recent_record_\(seedRecordID)"], timeout: 5))
    }

    private func seedPersistedRecord() throws {
        let recordDir = tempRoot.appendingPathComponent(seedRecordID)
        try FileManager.default.createDirectory(at: recordDir, withIntermediateDirectories: true)
        try """
        {
          "id": "\(seedRecordID)",
          "createdAt": "2026-05-23T08:00:00Z",
          "duration": 30.0,
          "mediaType": "audio",
          "source": "imported",
          "userTags": ["release"],
          "autoTags": ["restart"],
          "summaryPreview": "restart persistence evidence"
        }
        """.write(to: recordDir.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8)
        try """
        [{"start_ms":0,"end_ms":2500,"speaker":"SPEAKER_00","text":"Restart search target survives relaunch."}]
        """.write(to: recordDir.appendingPathComponent("transcript.json"), atomically: true, encoding: .utf8)
        try """
        {"structured_summary":"Restart persistence evidence remains readable.","highlights":[],"key_decisions":[],"action_items":[],"timeline_beats":[]}
        """.write(to: recordDir.appendingPathComponent("minutes.json"), atomically: true, encoding: .utf8)
        try "00:02 restart note".write(
            to: recordDir.appendingPathComponent("notes.md"),
            atomically: true,
            encoding: .utf8
        )
    }
}
