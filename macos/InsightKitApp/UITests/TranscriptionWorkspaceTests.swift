import XCTest

final class TranscriptionWorkspaceTests: InsightKitUITests {

    override var launchEnvironmentOverrides: [String: String] {
        ["INSIGHTKIT_UI_TEST_ROUTE": "transcription"]
    }

    override var launchArgumentOverrides: [String] {
        ["--ui-test-route=transcription"]
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        let backButton = app.buttons["返回首页"]
        XCTAssertTrue(waitForElement(backButton, timeout: 5), "应导航到转写工作区")
    }

    func testTranscriptionWorkspaceVisible() throws {
        // TranscriptionWorkspaceView uses HSplitView — verify SplitGroup exists
        XCTAssertTrue(app.splitGroups.firstMatch.exists, "转写工作区三栏布局应显示")
    }

    func testImportFileButtonExists() throws {
        let importButton = app.buttons["导入文件"]
        XCTAssertTrue(importButton.exists, "导入文件按钮应显示")
    }

    func testWatcherButtonExists() throws {
        // Button label toggles between "开始监听" and "停止监听"
        let startWatcher = app.buttons["开始监听"]
        let stopWatcher = app.buttons["停止监听"]
        XCTAssertTrue(
            startWatcher.exists || stopWatcher.exists,
            "监听按钮应显示"
        )
    }

    func testBackButtonNavigatesToHome() throws {
        app.buttons["返回首页"].firstMatch.click()
        let homeTitle = app.staticTexts["home_title"]
        XCTAssertTrue(waitForElement(homeTitle, timeout: 5), "应返回首页")
    }
}
