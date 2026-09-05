import XCTest

final class RecordsPersistenceUITests: InsightKitUITests {
    private let seedRecordID = "record-restart-proof"

    func testRecentRecordSearchAndRelaunchPersistence() throws {
        let recordListItem = element("record_list_item_\(seedRecordID)").firstMatch
        XCTAssertTrue(waitForElement(app.staticTexts["home_title"], timeout: 5))
        button("home_card_records").click()
        XCTAssertTrue(waitForElement(recordListItem, timeout: 5))

        let searchField = app.textFields["records_search_field"]
        XCTAssertTrue(waitForElement(searchField, timeout: 5))
        enterText("restart", into: searchField)
        XCTAssertTrue(waitForElement(recordListItem, timeout: 5))

        app.terminate()
        // Read the record written by the first process; do not seed it again.
        // Keep storage, telemetry, and credential isolation across the restart.
        app.launchEnvironment["INSIGHTKIT_UI_TEST_SEED_RECORDS"] = "0"
        app.launch()
        app.activate()

        XCTAssertTrue(waitForElement(app.staticTexts["home_title"], timeout: 5))
        button("home_card_records").click()
        XCTAssertTrue(waitForElement(element("record_list_item_\(seedRecordID)").firstMatch, timeout: 5))
    }
}
