import XCTest
@testable import InsightKitApp

final class LiveSessionViewModelTests: XCTestCase {
    func testRefreshThrottleBySegmentCountAndInterval() {
        var coordinator = LiveInsightCoordinator(minRefreshInterval: 15, minSegmentsBeforeRefresh: 2)

        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(coordinator.registerIngested(1, now: t0))

        coordinator.markRefreshed(at: t0)

        let t1 = t0.addingTimeInterval(3)
        XCTAssertFalse(coordinator.registerIngested(1, now: t1))

        let t2 = t0.addingTimeInterval(5)
        XCTAssertTrue(coordinator.registerIngested(1, now: t2))

        coordinator.markRefreshed(at: t2)

        let t3 = t2.addingTimeInterval(16)
        XCTAssertTrue(coordinator.registerIngested(1, now: t3))
    }
}
