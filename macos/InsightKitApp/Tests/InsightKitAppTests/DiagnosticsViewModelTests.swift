import XCTest
@testable import InsightKitApp

final class DiagnosticsViewModelTests: XCTestCase {
    func testDiagnosticsReportShape() throws {
        let rpc = RPCClientMock()
        let report = try rpc.diagnosticsQuickCheck()
        XCTAssertEqual(report.overall, .pass)
        XCTAssertFalse(report.checks.isEmpty)
        XCTAssertEqual(report.checks.first?.id, "sidecar")
    }

    func testSettingsOnlyProbeCloudAnalysis() {
        XCTAssertFalse(SettingsView.shouldProbeCloudAnalysis(for: .local))
        XCTAssertTrue(SettingsView.shouldProbeCloudAnalysis(for: .cloud))
    }
}
