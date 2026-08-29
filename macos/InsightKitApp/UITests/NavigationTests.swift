import XCTest

final class NavigationTests: InsightKitUITests {

    func testFullNavigationCycle() throws {
        let homeTitle = app.staticTexts["home_title"]
        XCTAssertTrue(waitForElement(homeTitle), "应从首页开始")
        attachScreenshot(named: "product-evidence-home")

        // Home → Import (test non-permission routes first)
        app.buttons["home_card_import"].firstMatch.click()
        XCTAssertTrue(waitForElement(app.buttons["返回首页"], timeout: 5))
        attachScreenshot(named: "product-evidence-import")

        // Import → Home
        app.buttons["返回首页"].firstMatch.click()
        XCTAssertTrue(waitForElement(homeTitle, timeout: 5))

        // Home → Records
        app.buttons["home_card_records"].firstMatch.click()
        XCTAssertTrue(waitForElement(app.buttons["返回首页"], timeout: 5))
        attachScreenshot(named: "product-evidence-records")

        // Records → Home
        app.buttons["返回首页"].firstMatch.click()
        XCTAssertTrue(waitForElement(homeTitle, timeout: 5))

        // Home → Live (may require permissions)
        app.buttons["home_card_live"].firstMatch.click()
        let liveBack = app.buttons["返回首页"].firstMatch
        if !liveBack.waitForExistence(timeout: 5) {
            throw XCTSkip("Live workspace requires permissions to be pre-granted")
        }

        // Live → Home
        liveBack.click()
        XCTAssertTrue(waitForElement(homeTitle, timeout: 5))

        // Settings uses a separate app-owned window and ends this journey.
        app.buttons["home_open_settings"].firstMatch.click()
        let settingsWindow = app.windows["InsightKit 设置"].firstMatch
        XCTAssertTrue(waitForElement(settingsWindow, timeout: 5))
        let anonymousModelPath = settingsWindow.textFields.matching(
            NSPredicate(format: "value == %@", "/tmp/InsightKit/models")
        ).firstMatch
        XCTAssertTrue(waitForElement(anonymousModelPath), "UI 证据不得读取本机模型路径")
        XCTAssertTrue(settingsWindow.staticTexts["Key: 未保存"].firstMatch.exists, "UI 证据不得读取真实钥匙串")
        attachScreenshot(named: "product-evidence-settings", windowTitle: "InsightKit 设置")
    }

    func testAppLaunchShowsHome() throws {
        let homeTitle = app.staticTexts["home_title"]
        XCTAssertTrue(waitForElement(homeTitle), "App 启动后应显示首页")

        let liveCard = app.buttons["home_card_live"]
        let importCard = app.buttons["home_card_import"]
        let recordsCard = app.buttons["home_card_records"]

        XCTAssertTrue(liveCard.exists, "实时转写卡片应存在")
        XCTAssertTrue(importCard.exists, "导入转写卡片应存在")
        XCTAssertTrue(recordsCard.exists, "转写记录卡片应存在")
    }
}
