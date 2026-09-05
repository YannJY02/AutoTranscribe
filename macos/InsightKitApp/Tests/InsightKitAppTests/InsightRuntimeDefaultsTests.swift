import Darwin
import XCTest
@testable import InsightKitApp

final class InsightRuntimeDefaultsTests: XCTestCase {
    func testUITestEntrypointsWithoutExplicitSocketStayInTheirRun() throws {
        let launches: [([String: String], [String])] = [
            ([UITestStorageContext.sessionIDEnvironmentKey: UUID().uuidString], []),
            (["INSIGHTKIT_UI_TEST_MODE": "1"], []),
            ([:], ["InsightKitApp", "--ui-test-mode"]),
            ([:], ["InsightKitApp", "-INSIGHTKIT_UI_TEST_MODE", "1"]),
        ]
        for (environment, arguments) in launches {
            let context = try XCTUnwrap(UITestStorageContext.resolve(environment: environment, arguments: arguments))
            XCTAssertEqual(
                InsightRuntimeDefaults.resolvedSocketPath(environment: environment, arguments: arguments),
                context.socketPath
            )
        }
    }

    func testUITestContextCannotInheritTheOperatorSocket() {
        let context = UITestStorageContext(sessionID: UUID())
        let environment = [
            UITestStorageContext.sessionIDEnvironmentKey: context.sessionID.uuidString,
            "INSIGHTKIT_SOCKET": "/tmp/insightkit-app-\(getuid()).sock",
        ]
        XCTAssertEqual(
            InsightRuntimeDefaults.resolvedSocketPath(environment: environment),
            context.socketPath
        )
    }

    func testProductionRetainsItsDefaultAndExplicitSocket() {
        XCTAssertEqual(
            InsightRuntimeDefaults.resolvedSocketPath(environment: [:]),
            "/tmp/insightkit-app-\(getuid()).sock"
        )
        XCTAssertEqual(
            InsightRuntimeDefaults.resolvedSocketPath(environment: ["INSIGHTKIT_SOCKET": "/tmp/custom-insightkit.sock"]),
            "/tmp/custom-insightkit.sock"
        )
    }
}
