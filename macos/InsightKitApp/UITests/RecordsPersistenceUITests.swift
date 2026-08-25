import XCTest

final class RecordsPersistenceUITests: InsightKitUITests {
    private let seedRecordID = "record-restart-proof"

    func testRecentRecordSearchAndRelaunchPersistence() throws {
        let homeRecord = element("home_recent_record_\(seedRecordID)").firstMatch
        let recordListItem = element("record_list_item_\(seedRecordID)").firstMatch
        XCTAssertTrue(waitForElement(app.staticTexts["home_title"], timeout: 5))
        XCTAssertTrue(waitForElement(homeRecord, timeout: 5))

        homeRecord.tap()
        XCTAssertTrue(waitForElement(recordListItem, timeout: 5))

        let searchField = app.textFields["records_search_field"]
        XCTAssertTrue(waitForElement(searchField, timeout: 5))
        enterText("restart", into: searchField)
        XCTAssertTrue(waitForElement(recordListItem, timeout: 5))

        app.terminate()
        app.launch()
        app.activate()

        XCTAssertTrue(waitForElement(app.staticTexts["home_title"], timeout: 5))
        XCTAssertTrue(waitForElement(element("home_recent_record_\(seedRecordID)").firstMatch, timeout: 5))
    }
}
