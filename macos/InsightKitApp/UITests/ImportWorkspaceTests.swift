import XCTest

final class ImportWorkspaceTests: InsightKitUITests {

    override func setUpWithError() throws {
        try super.setUpWithError()
        app.buttons["home_card_import"].tap()
        let backButton = app.buttons["返回首页"]
        XCTAssertTrue(waitForElement(backButton, timeout: 5))
    }

    func testThreePanelLayoutVisible() throws {
        XCTAssertTrue(app.splitGroups.firstMatch.exists, "三栏布局应显示")
    }

    func testBackButtonNavigatesToHome() throws {
        app.buttons["返回首页"].tap()
        let homeTitle = app.staticTexts["home_title"]
        XCTAssertTrue(waitForElement(homeTitle, timeout: 5), "应返回首页")
    }
}
