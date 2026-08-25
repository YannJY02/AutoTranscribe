import XCTest

final class TranscriptionWorkspaceTests: InsightKitUITests {

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Transcription route is accessible via toolbar "转写总结" button from home
        // or via the home screen toolbar button
        let transcriptionButton = app.buttons["转写总结"].firstMatch
        if transcriptionButton.waitForExistence(timeout: 3) {
            transcriptionButton.tap()
        } else {
            // Fallback: navigate via home toolbar
            let toolbarButton = app.toolbars.buttons["转写总结"].firstMatch
            XCTAssertTrue(toolbarButton.waitForExistence(timeout: 3), "转写总结按钮应存在")
            toolbarButton.tap()
        }
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
        app.buttons["返回首页"].firstMatch.tap()
        let homeTitle = app.staticTexts["home_title"]
        XCTAssertTrue(waitForElement(homeTitle, timeout: 5), "应返回首页")
    }
}
