import XCTest

final class NavigationTests: InsightKitUITests {

    func testFullNavigationCycle() throws {
        let homeTitle = app.staticTexts["home_title"]
        XCTAssertTrue(waitForElement(homeTitle), "应从首页开始")

        // Home → Import (test non-permission routes first)
        app.buttons["home_card_import"].tap()
        XCTAssertTrue(waitForElement(app.buttons["返回首页"], timeout: 5))

        // Import → Home
        app.buttons["返回首页"].tap()
        XCTAssertTrue(waitForElement(homeTitle, timeout: 5))

        // Home → Records
        app.buttons["home_card_records"].tap()
        XCTAssertTrue(waitForElement(app.buttons["返回首页"], timeout: 5))

        // Records → Home
        app.buttons["返回首页"].tap()
        XCTAssertTrue(waitForElement(homeTitle, timeout: 5))

        // Home → Live (may require permissions)
        app.buttons["home_card_live"].tap()
        let liveBack = app.buttons["返回首页"]
        if !liveBack.waitForExistence(timeout: 5) {
            throw XCTSkip("Live workspace requires permissions to be pre-granted")
        }

        // Live → Home
        liveBack.tap()
        XCTAssertTrue(waitForElement(homeTitle, timeout: 5))
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
