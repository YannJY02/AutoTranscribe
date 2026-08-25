import XCTest

final class RecordsPersistenceUITests: InsightKitUITests {
    private let seedRecordID = "record-restart-proof"

    func testRecentRecordSearchAndRelaunchPersistence() throws {
        let recordListItem = element("record_list_item_\(seedRecordID)").firstMatch
        XCTAssertTrue(waitForElement(app.staticTexts["home_title"], timeout: 5))
        button("home_card_records").tap()
        XCTAssertTrue(waitForElement(recordListItem, timeout: 5))

        let searchField = app.textFields["records_search_field"]
        XCTAssertTrue(waitForElement(searchField, timeout: 5))
        enterText("restart", into: searchField)
        XCTAssertTrue(waitForElement(recordListItem, timeout: 5))

        app.terminate()
        app.launchArguments.removeAll { $0 == "--ui-test-mode" }
        app.launchEnvironment["INSIGHTKIT_UI_TEST_MODE"] = "0"
        app.launch()
        app.activate()

        XCTAssertTrue(waitForElement(app.staticTexts["home_title"], timeout: 5))
        button("home_card_records").tap()
        XCTAssertTrue(waitForElement(element("record_list_item_\(seedRecordID)").firstMatch, timeout: 5))
    }
}
