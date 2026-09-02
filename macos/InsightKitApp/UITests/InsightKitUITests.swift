import XCTest

/// Base class for InsightKit UI tests.
/// Provides shared setup/teardown and helper utilities.
class InsightKitUITests: XCTestCase {
    var app: XCUIApplication!
    var captureRoot: URL!

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
        captureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("InsightKitUITestEvidence-\(UUID().uuidString)")
        app.launchEnvironment["INSIGHTKIT_UI_TEST_MODE"] = "1"
        app.launchEnvironment["INSIGHTKIT_UI_TEST_CAPTURE_ROOT"] = captureRoot.path
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
        if let app, app.state != .notRunning {
            let targetWindow = app.windows.firstMatch
            if targetWindow.exists {
                let attachment = XCTAttachment(screenshot: targetWindow.screenshot())
                attachment.name = "target-window-\(name.replacingOccurrences(of: "/", with: "-"))"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        app?.terminate()
        app = nil
        if let captureRoot {
            try? FileManager.default.removeItem(at: captureRoot)
        }
        captureRoot = nil
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

    func attachScreenshot(named name: String, windowTitle: String = "InsightKit") {
        let root = captureRoot!
        let requestURL = root.appendingPathComponent("capture.request")
        let imageURL = root.appendingPathComponent("latest.png")
        let errorURL = root.appendingPathComponent("latest.error.txt")
        try? FileManager.default.removeItem(at: imageURL)
        try? FileManager.default.removeItem(at: errorURL)

        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try windowTitle.write(to: requestURL, atomically: true, encoding: .utf8)
        } catch {
            XCTFail("\(name) window capture request failed: \(error)")
            return
        }

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline && !FileManager.default.fileExists(atPath: imageURL.path) {
            if let message = try? String(contentsOf: errorURL, encoding: .utf8) {
                XCTFail("\(name) window capture failed: \(message)")
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        guard let data = try? Data(contentsOf: imageURL) else {
            XCTFail("\(name) window capture timed out")
            return
        }

        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
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
