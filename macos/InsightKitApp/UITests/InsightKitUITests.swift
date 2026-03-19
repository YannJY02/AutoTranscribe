import XCTest

/// Base class for InsightKit UI tests.
/// Provides shared setup/teardown and helper utilities.
class InsightKitUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        addUIInterruptionMonitor(withDescription: "System Permission") { alert in
            let allowButtons = ["OK", "Allow", "允许", "好"]
            for title in allowButtons {
                let button = alert.buttons[title]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    /// Wait for an element to exist within a timeout.
    @discardableResult
    func waitForElement(
        _ element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        element.waitForExistence(timeout: timeout)
    }

    /// Dismiss any system alerts by interacting with the app.
    func dismissSystemAlerts() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
}
