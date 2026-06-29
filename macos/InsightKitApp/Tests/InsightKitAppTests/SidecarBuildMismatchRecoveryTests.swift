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

    func testBestEffortShutdownMissingSocketReturnsQuickly() {
        let missingSocket = "/tmp/insightkit-test-missing-\(UUID().uuidString).sock"
        let start = Date()

        SidecarManager.bestEffortShutdownSocketOwner(socketPath: missingSocket, timeoutSec: 1)

        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    func testPreparedPythonEnvironmentPreventsBundlePycacheWrites() {
        let env = PythonRuntimeEnvironment.prepared(
            from: ["PYTHONPATH": "/existing", "PATH": "/custom/bin:/usr/bin"],
            runtimeRoot: "/Bundle/Contents/Resources/insightkit_runtime"
        )

        XCTAssertEqual(env["PYTHONDONTWRITEBYTECODE"], "1")
        XCTAssertEqual(env["INSIGHTKIT_RUNTIME_ROOT"], "/Bundle/Contents/Resources/insightkit_runtime")
        XCTAssertEqual(env["PYTHONPATH"], "/Bundle/Contents/Resources/insightkit_runtime:/existing")
        let pathEntries = env["PATH"]?.split(separator: ":").map(String.init) ?? []
        XCTAssertEqual(pathEntries.first, "/custom/bin")
        XCTAssertTrue(pathEntries.contains("/opt/homebrew/bin"))
        XCTAssertTrue(pathEntries.contains("/usr/local/bin"))
        XCTAssertEqual(pathEntries.filter { $0 == "/usr/bin" }.count, 1)
    }

    func testPreparedPythonEnvironmentAddsExecutableSearchPathForGuiLaunches() {
        let env = PythonRuntimeEnvironment.prepared(from: [:])
        let pathEntries = env["PATH"]?.split(separator: ":").map(String.init) ?? []

        XCTAssertTrue(pathEntries.contains("/opt/homebrew/bin"))
        XCTAssertTrue(pathEntries.contains("/usr/local/bin"))
        XCTAssertTrue(pathEntries.contains("/usr/bin"))
    }
}
