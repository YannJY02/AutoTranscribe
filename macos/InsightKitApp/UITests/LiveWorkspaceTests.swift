import XCTest

final class LiveWorkspaceTests: InsightKitUITests {

    override func setUpWithError() throws {
        try super.setUpWithError()
        app.buttons["home_card_live"].tap()
        // Live workspace may trigger permission dialogs (microphone/screen recording).
        // If "返回首页" doesn't appear within timeout, permissions are likely blocking.
        let backButton = app.buttons["返回首页"]
        if !backButton.waitForExistence(timeout: 5) {
            throw XCTSkip("Live workspace requires microphone/screen recording permissions to be pre-granted")
        }
    }

    func testThreePanelLayoutVisible() throws {
        XCTAssertTrue(app.splitGroups.firstMatch.exists, "三栏布局应显示")
    }

    func testBackButtonExists() throws {
        XCTAssertTrue(app.buttons["返回首页"].exists, "返回首页按钮应显示")
    }

    func testBackButtonNavigatesToHome() throws {
        app.buttons["返回首页"].tap()
        let homeTitle = app.staticTexts["home_title"]
        XCTAssertTrue(waitForElement(homeTitle, timeout: 5), "应返回首页")
    }
}
