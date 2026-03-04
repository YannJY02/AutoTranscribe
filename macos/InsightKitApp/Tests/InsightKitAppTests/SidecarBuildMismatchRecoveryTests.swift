import XCTest
@testable import InsightKitApp

final class SidecarBuildMismatchRecoveryTests: XCTestCase {
    func testShouldRebootstrapWhenBuildMismatch() {
        XCTAssertTrue(SidecarManager.shouldRebootstrapForBuildMismatch(sidecarBuild: "202603040001", appBuild: "202603040002"))
    }

    func testShouldNotRebootstrapWhenBuildMatchesOrMissing() {
        XCTAssertFalse(SidecarManager.shouldRebootstrapForBuildMismatch(sidecarBuild: "202603040002", appBuild: "202603040002"))
        XCTAssertFalse(SidecarManager.shouldRebootstrapForBuildMismatch(sidecarBuild: "", appBuild: "202603040002"))
        XCTAssertFalse(SidecarManager.shouldRebootstrapForBuildMismatch(sidecarBuild: "202603040002", appBuild: ""))
    }
}
