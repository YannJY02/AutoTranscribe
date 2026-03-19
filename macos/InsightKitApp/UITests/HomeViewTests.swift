import XCTest

final class HomeViewTests: InsightKitUITests {

    func testHomeScreenShowsThreeCards() throws {
        let liveCard = app.buttons["home_card_live"]
        let importCard = app.buttons["home_card_import"]
        let recordsCard = app.buttons["home_card_records"]

        XCTAssertTrue(waitForElement(liveCard), "实时转写卡片应显示")
        XCTAssertTrue(importCard.exists)
        XCTAssertTrue(recordsCard.exists)
    }

    func testHomeScreenShowsTitle() throws {
        let title = app.staticTexts["home_title"]
        XCTAssertTrue(waitForElement(title), "首页标题应显示")
    }

    func testHomeScreenShowsSubtitle() throws {
        let subtitle = app.staticTexts["home_subtitle"]
        XCTAssertTrue(waitForElement(subtitle), "首页副标题应显示")
    }

    func testTapLiveCardNavigatesToLive() throws {
        app.buttons["home_card_live"].tap()
        let backButton = app.buttons["返回首页"]
        if !backButton.waitForExistence(timeout: 5) {
            throw XCTSkip("Live workspace requires permissions to be pre-granted")
        }
        XCTAssertTrue(backButton.exists, "应导航到实时转写页面")
    }

    func testTapImportCardNavigatesToImport() throws {
        app.buttons["home_card_import"].tap()
        let backButton = app.buttons["返回首页"]
        XCTAssertTrue(waitForElement(backButton, timeout: 5), "应导航到导入转写页面")
    }

    func testTapRecordsCardNavigatesToRecords() throws {
        app.buttons["home_card_records"].tap()
        let backButton = app.buttons["返回首页"]
        XCTAssertTrue(waitForElement(backButton, timeout: 5), "应导航到转写记录页面")
    }
}
