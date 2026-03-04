import XCTest
@testable import InsightKitApp

final class DiagnosticsTimeoutGracefulDegradeTests: XCTestCase {
    func testDiagnosticCheckCarriesTimeoutFlag() {
        let check = DiagnosticCheck(
            id: "analysis_provider_probe",
            title: "智能分析鉴权探测",
            status: .warn,
            actionHint: "稍后重试",
            details: "probe timeout",
            timedOut: true
        )

        XCTAssertEqual(check.status, .warn)
        XCTAssertTrue(check.timedOut)
    }
}
