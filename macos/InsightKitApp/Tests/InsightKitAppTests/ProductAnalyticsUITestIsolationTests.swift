import XCTest
@testable import InsightKitApp

final class ProductAnalyticsUITestIsolationTests: XCTestCase {
    func testEveryUITestEntrypointUsesSessionOwnedAnalyticsStorage() throws {
        for (environment, arguments) in launches {
            let context = try XCTUnwrap(UITestStorageContext.resolve(
                environment: environment, arguments: arguments
            ))

            XCTAssertEqual(
                ProductAnalytics.uiTestStorageDirectory(environment: environment, arguments: arguments),
                context.captureDirectory.appendingPathComponent("ProductAnalytics", isDirectory: true),
                "UI-test launch must select isolated analytics before defaults, keys or transport are created"
            )
        }
    }

    func testUITestAnalyticsCannotInheritAnotherCaptureRoot() throws {
        let inheritedRoot = "/tmp/insightkit-other-run-capture"
        for (launchEnvironment, arguments) in launches {
            var environment = launchEnvironment
            environment["INSIGHTKIT_UI_TEST_CAPTURE_ROOT"] = inheritedRoot
            let context = try XCTUnwrap(UITestStorageContext.resolve(
                environment: environment, arguments: arguments
            ))

            XCTAssertEqual(
                ProductAnalytics.uiTestStorageDirectory(environment: environment, arguments: arguments),
                context.captureDirectory.appendingPathComponent("ProductAnalytics", isDirectory: true)
            )
        }
    }

    func testDifferentUITestSessionsNeverShareAnalyticsStorage() throws {
        let first = try XCTUnwrap(ProductAnalytics.uiTestStorageDirectory(
            environment: [UITestStorageContext.sessionIDEnvironmentKey: UUID().uuidString],
            arguments: []
        ))
        let second = try XCTUnwrap(ProductAnalytics.uiTestStorageDirectory(
            environment: [UITestStorageContext.sessionIDEnvironmentKey: UUID().uuidString],
            arguments: []
        ))

        XCTAssertNotEqual(first, second)
    }

    func testNonUITestLaunchesDoNotSelectTestAnalyticsStorage() {
        let launches: [([String: String], [String])] = [
            ([:], []),
            (["INSIGHTKIT_UI_TEST_MODE": "0"], []),
            ([UITestStorageContext.sessionIDEnvironmentKey: "invalid-session-id"], []),
            (["INSIGHTKIT_UI_TEST_CAPTURE_ROOT": "/tmp/capture-only"], []),
            ([:], ["InsightKitApp", "-INSIGHTKIT_UI_TEST_MODE", "0"]),
        ]
        for (environment, arguments) in launches {
            XCTAssertNil(ProductAnalytics.uiTestStorageDirectory(
                environment: environment, arguments: arguments
            ))
        }
    }

    private var launches: [([String: String], [String])] {
        [
            ([UITestStorageContext.sessionIDEnvironmentKey: UUID().uuidString], []),
            (["INSIGHTKIT_UI_TEST_MODE": "1"], []),
            ([:], ["InsightKitApp", "--ui-test-mode"]),
            ([:], ["InsightKitApp", "-INSIGHTKIT_UI_TEST_MODE", "1"]),
        ]
    }
}
