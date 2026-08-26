import XCTest

/// Base class for InsightKit UI tests.
/// Provides shared setup/teardown and helper utilities.
class InsightKitUITests: XCTestCase {
    var app: XCUIApplication!

    var launchEnvironmentOverrides: [String: String] {
        [:]
    }

    var launchArgumentOverrides: [String] {
        []
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "--ui-test-mode",
        ]
        app.launchArguments += launchArgumentOverrides
        app.launchEnvironment["INSIGHTKIT_UI_TEST_MODE"] = "1"
        for (key, value) in launchEnvironmentOverrides {
            app.launchEnvironment[key] = value
        }
        app.launch()
        app.activate()
        addUIInterruptionMonitor(withDescription: "System Permission") { alert in
            let allowButtons = ["OK", "Allow", "允许", "好"]
            for title in allowButtons {
                let button = alert.buttons[title]
                if button.exists {
                    button.click()
                    return true
                }
            }
            return false
        }
    }

    override func tearDownWithError() throws {
        app?.terminate()
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

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    func button(_ identifier: String, fallbackLabel: String? = nil) -> XCUIElement {
        let byIdentifier = app.buttons[identifier].firstMatch
        if byIdentifier.exists || fallbackLabel == nil {
            return byIdentifier
        }
        return app.buttons[fallbackLabel!].firstMatch
    }

    func stringValue(of element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty {
            return value
        }
        return element.label
    }

    @discardableResult
    func waitForEnabled(
        _ element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isEnabled {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return element.exists && element.isEnabled
    }

    @discardableResult
    func waitForStringValue(
        _ expected: String,
        in element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && stringValue(of: element) == expected {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return element.exists && stringValue(of: element) == expected
    }

    /// Dismiss any system alerts by interacting with the app.
    func dismissSystemAlerts() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func enterText(_ text: String, into element: XCUIElement) {
        app.activate()
        element.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        element.typeKey("a", modifierFlags: .command)
        element.typeText(text)
    }
}
