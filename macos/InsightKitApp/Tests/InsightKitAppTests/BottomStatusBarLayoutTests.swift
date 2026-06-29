import XCTest
@testable import InsightKitApp

final class BottomStatusBarLayoutTests: XCTestCase {
    func testWorkspaceRoutesReserveBottomStatusBarHeight() {
        XCTAssertEqual(
            BottomStatusBarLayout.reservedHeight(for: .records, mode: .collapsed),
            47,
            accuracy: 0.1
        )
        XCTAssertEqual(
            BottomStatusBarLayout.reservedHeight(for: .live, mode: .expandedDebug),
            47,
            accuracy: 0.1
        )
    }

    func testHomeRouteDoesNotReserveBottomStatusBarHeight() {
        XCTAssertEqual(
            BottomStatusBarLayout.reservedHeight(for: .home, mode: .collapsed),
            0,
            accuracy: 0.1
        )
    }

    func testContentHeightSubtractsBottomChromeInsteadOfOverlappingIt() {
        XCTAssertEqual(
            BottomStatusBarLayout.contentHeight(
                availableHeight: 860,
                route: .records,
                mode: .expandedDebug
            ),
            813,
            accuracy: 0.1
        )
        XCTAssertEqual(
            BottomStatusBarLayout.contentHeight(
                availableHeight: 20,
                route: .records,
                mode: .collapsed
            ),
            0,
            accuracy: 0.1
        )
    }
}
