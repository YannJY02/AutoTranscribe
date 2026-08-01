#!/usr/bin/env swift

import AppKit
import ApplicationServices
import Foundation
import os.signpost

struct BaselineFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct Configuration {
    let recordsRoot: String
    let recordCount: Int
    let searchHitCount: Int
    let searchHitID: String
    let runID: String
    let runKind: String
    let startGate: String?

    init(arguments: [String]) throws {
        guard arguments.count.isMultiple(of: 2) else {
            throw BaselineFailure(message: "arguments must be --name value pairs")
        }
        var values: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let key = arguments[index]
            guard key.hasPrefix("--"), values[key] == nil else {
                throw BaselineFailure(message: "invalid or duplicate argument: \(key)")
            }
            values[key] = arguments[index + 1]
        }
        let required = [
            "--records-root", "--record-count", "--search-hit-count",
            "--search-hit-id", "--run-id", "--run-kind",
        ]
        let allowed = Set(required + ["--start-gate"])
        let unexpected = values.keys.filter { !allowed.contains($0) }
        guard unexpected.isEmpty else {
            throw BaselineFailure(message: "unknown argument: \(unexpected.sorted().joined(separator: ", "))")
        }
        for key in required where values[key]?.isEmpty != false {
            throw BaselineFailure(message: "missing argument: \(key)")
        }
        guard let recordCount = Int(values["--record-count"]!), recordCount > 0,
              let searchHitCount = Int(values["--search-hit-count"]!), searchHitCount > 0
        else { throw BaselineFailure(message: "record counts must be positive integers") }

        let root = values["--records-root"]!
        let canonicalRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/InsightKit/BenchmarkFixtures/v1")
            .standardizedFileURL.path
        guard URL(fileURLWithPath: root).standardizedFileURL.path.hasPrefix(canonicalRoot + "/"),
              FileManager.default.fileExists(atPath: root)
        else { throw BaselineFailure(message: "records root is outside the canonical fixture corpus") }

        recordsRoot = root
        self.recordCount = recordCount
        self.searchHitCount = searchHitCount
        searchHitID = values["--search-hit-id"]!
        runID = values["--run-id"]!
        runKind = values["--run-kind"]!
        if let gate = values["--start-gate"] {
            let path = URL(fileURLWithPath: gate).standardizedFileURL.path
            guard path.hasPrefix("/tmp/insightkit-benchmark-gate-") else {
                throw BaselineFailure(message: "start gate must use the dedicated /tmp prefix")
            }
            startGate = path
        } else {
            startGate = nil
        }
    }
}

final class InstalledAppBaseline {
    private let config: Configuration
    private let appURL = URL(fileURLWithPath: "/Users/yann.jy/Applications/InsightKit.app")
    private let bundleIdentifier = "com.yannjy.insightkit"
    private let signpostLog = OSLog(
        subsystem: "com.yannjy.insightkit.performance-baseline",
        category: .pointsOfInterest
    )
    private var runningApp: NSRunningApplication!
    private var application: AXUIElement!

    init(config: Configuration) {
        self.config = config
    }

    func run() throws {
        let sensitiveEnvironmentKeys = ProcessInfo.processInfo.environment.keys.filter {
            let key = $0.uppercased()
            return key.contains("TOKEN") || key.contains("SECRET") || key.contains("PASSWORD")
                || key.hasSuffix("_KEY")
        }
        guard sensitiveEnvironmentKeys.isEmpty else {
            throw BaselineFailure(
                message: "refusing to launch from an environment with sensitive keys: "
                    + sensitiveEnvironmentKeys.sorted().joined(separator: ", ")
            )
        }
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            throw BaselineFailure(message: "Accessibility and post-event access are required")
        }
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            throw BaselineFailure(message: "Canonical Installed App is missing")
        }

        let launchStart = ProcessInfo.processInfo.systemUptime
        try launch()
        _ = try waitFor(identifier: "home_title", timeout: 30)
        _ = try waitFor(identifier: "home_card_records", timeout: 30, requireEnabled: true)
        try emitMetric(
            name: "app.launch_to_home_usable_ms",
            value: elapsedMilliseconds(since: launchStart),
            phase: "launch",
            startEvent: "NSWorkspace launch request accepted",
            stopEvent: "Home Workspace rendered and Records action enabled",
            source: "host monotonic clock; corroborate with Instruments App Launch"
        )
        try waitForStartGate()

        try navigate(phase: "live", sourceIdentifier: "home_card_live")
        try returnHome()
        try navigate(phase: "import", sourceIdentifier: "home_card_import")
        try returnHome()
        try navigate(phase: "records", sourceIdentifier: "home_card_records")

        let recordCount = NumberFormatter.localizedString(
            from: NSNumber(value: config.recordCount),
            number: .decimal
        )
        _ = try waitForText("全部记录 (\(recordCount))", timeout: 60)
        let searchHit = try waitFor(identifier: "record_list_item_\(config.searchHitID)", timeout: 30)
        try replayScrollTrace(on: searchHit, name: "RecordListScroll")

        let search = try waitFor(identifier: "records_search_field", timeout: 15, requireEnabled: true)
        try click(search)
        let query = "benchmark-focus-token"
        let inputStart = try replayText(query, interval: 0.08)
        _ = try waitForValue(query, in: search, timeout: 10)
        let searchHitCount = NumberFormatter.localizedString(
            from: NSNumber(value: config.searchHitCount),
            number: .decimal
        )
        _ = try waitForText("全部记录 (\(searchHitCount))", timeout: 30)
        try emitMetric(
            name: "interaction.input_response_ms",
            value: elapsedMilliseconds(since: inputStart),
            phase: "records_search",
            startEvent: "final fixed keyboard event delivered",
            stopEvent: "stable expected search result count visible",
            source: "host monotonic clock; corroborate with Instruments System Trace"
        )

        try returnHome()
        try click(waitFor(identifier: "home_card_records", timeout: 15, requireEnabled: true))
        _ = try waitFor(identifier: "workflow_back_home", timeout: 30, requireEnabled: true)
        let setupSearch = try waitFor(identifier: "records_search_field", timeout: 15, requireEnabled: true)
        try click(setupSearch)
        _ = try replayText(query, interval: 0.08)
        _ = try waitForValue(query, in: setupSearch, timeout: 10)
        _ = try waitForText("全部记录 (\(searchHitCount))", timeout: 30)
        let longRecord = try waitForElement(description: "filtered long Record", timeout: 30) {
            self.find(identifierPrefix: "record_list_item_")
        }
        try click(longRecord)
        let transcriptStart = try waitFor(identifier: "record_transcript_row_0", timeout: 30)
        try replayScrollTrace(on: transcriptStart, name: "LongTranscriptScroll")

        try click(waitFor(identifier: "workflow_back_records_list", timeout: 15, requireEnabled: true))
        _ = try waitFor(identifier: "records_search_field", timeout: 15)
        try returnHome()

        let settingsStart = ProcessInfo.processInfo.systemUptime
        try click(waitFor(identifier: "home_open_settings", timeout: 15, requireEnabled: true))
        let settingsWindow = try waitForWindow(title: "InsightKit 设置", timeout: 15)
        try emitMetric(
            name: "workspace.navigation_to_interactive_ms",
            value: elapsedMilliseconds(since: settingsStart),
            phase: "settings",
            startEvent: "fixed center pointer click delivered",
            stopEvent: "Settings window rendered",
            source: "host monotonic clock; corroborate with Instruments Time Profiler"
        )
        try close(window: settingsWindow)

        try replayResizeTrace()
        runningApp.terminate()
    }

    private func launch() throws {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) {
            app.terminate()
        }
        let terminateDeadline = Date().addingTimeInterval(10)
        while !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty,
              Date() < terminateDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty else {
            throw BaselineFailure(message: "Canonical Installed App did not terminate before launch")
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-RecordsRootDirectory", config.recordsRoot,
        ]
        configuration.activates = true
        configuration.createsNewApplicationInstance = true

        let semaphore = DispatchSemaphore(value: 0)
        var launchedApp: NSRunningApplication?
        var launchError: Error?
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
            launchedApp = app
            launchError = error
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now() + 0.05) == .timedOut {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if let launchError { throw launchError }
        guard let launchedApp else { throw BaselineFailure(message: "launch returned no application") }
        runningApp = launchedApp
        activate()
        application = AXUIElementCreateApplication(runningApp.processIdentifier)
    }

    private func waitForStartGate() throws {
        guard let gate = config.startGate else { return }
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: gate) { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        throw BaselineFailure(message: "timed out waiting for the trace start gate")
    }

    private func navigate(phase: String, sourceIdentifier: String) throws {
        let source = try waitFor(identifier: sourceIdentifier, timeout: 15, requireEnabled: true)
        let signpostID = OSSignpostID(log: signpostLog)
        os_signpost(.begin, log: signpostLog, name: "WorkspaceNavigation", signpostID: signpostID, "%{public}s", phase)
        let start = ProcessInfo.processInfo.systemUptime
        try click(source)
        _ = try waitFor(identifier: "workflow_back_home", timeout: 30, requireEnabled: true)
        let value = elapsedMilliseconds(since: start)
        os_signpost(.end, log: signpostLog, name: "WorkspaceNavigation", signpostID: signpostID, "%{public}s", phase)
        try emitMetric(
            name: "workspace.navigation_to_interactive_ms",
            value: value,
            phase: phase,
            startEvent: "fixed center pointer click delivered",
            stopEvent: "destination rendered and Back action enabled",
            source: "host monotonic clock; corroborate with Instruments Time Profiler"
        )
    }

    private func returnHome() throws {
        try click(waitFor(identifier: "workflow_back_home", timeout: 15, requireEnabled: true))
        _ = try waitFor(identifier: "home_card_records", timeout: 30, requireEnabled: true)
    }

    private func replayScrollTrace(on element: AXUIElement, name: StaticString) throws {
        activate()
        let frame = try frame(of: element)
        CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: frame.midY))
        let signpostID = OSSignpostID(log: signpostLog)
        os_signpost(.begin, log: signpostLog, name: name, signpostID: signpostID)
        let start = ProcessInfo.processInfo.systemUptime
        for index in 0..<120 {
            wait(until: start + Double(index) * 0.016)
            guard let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 1,
                wheel1: -24,
                wheel2: 0,
                wheel3: 0
            ) else { throw BaselineFailure(message: "could not create scroll event") }
            event.post(tap: .cghidEventTap)
        }
        os_signpost(.end, log: signpostLog, name: name, signpostID: signpostID)
        try emitWindow(name: String(describing: name), start: start)
    }

    private func replayResizeTrace() throws {
        guard let window = windows().first else { throw BaselineFailure(message: "main window is unavailable") }
        let signpostID = OSSignpostID(log: signpostLog)
        os_signpost(.begin, log: signpostLog, name: "WindowResize", signpostID: signpostID)
        let start = ProcessInfo.processInfo.systemUptime
        try setSize(CGSize(width: 1100, height: 760), on: window)
        wait(until: start + 1)
        try setSize(CGSize(width: 1440, height: 900), on: window)
        wait(until: start + 1.5)
        os_signpost(.end, log: signpostLog, name: "WindowResize", signpostID: signpostID)
        try emitWindow(name: "WindowResize", start: start)
    }

    private func click(_ element: AXUIElement) throws {
        activate()
        let frame = try frame(of: element)
        let point = CGPoint(x: frame.midX, y: frame.midY)
        CGWarpMouseCursorPosition(point)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let event = CGEvent(
                mouseEventSource: nil,
                mouseType: type,
                mouseCursorPosition: point,
                mouseButton: .left
            ) else { throw BaselineFailure(message: "could not create pointer event") }
            event.post(tap: .cghidEventTap)
        }
    }

    private func replayText(_ text: String, interval: TimeInterval) throws -> TimeInterval {
        activate()
        let start = ProcessInfo.processInfo.systemUptime
        var finalEvent = start
        for (index, character) in text.enumerated() {
            wait(until: start + Double(index) * interval)
            let utf16 = Array(String(character).utf16)
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: keyDown) else {
                    throw BaselineFailure(message: "could not create keyboard event")
                }
                utf16.withUnsafeBufferPointer { buffer in
                    event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
                }
                event.post(tap: .cghidEventTap)
            }
            finalEvent = ProcessInfo.processInfo.systemUptime
        }
        return finalEvent
    }

    private func waitFor(
        identifier: String,
        timeout: TimeInterval,
        requireEnabled: Bool = false
    ) throws -> AXUIElement {
        try waitForElement(description: identifier, timeout: timeout) {
            guard let element = self.find(identifier: identifier) else { return nil }
            if requireEnabled, self.attribute(element, kAXEnabledAttribute as CFString) as? Bool == false {
                return nil
            }
            return element
        }
    }

    private func waitForText(_ text: String, timeout: TimeInterval) throws -> AXUIElement {
        try waitForElement(description: text, timeout: timeout) { self.find(text: text) }
    }

    private func waitForValue(
        _ value: String,
        in element: AXUIElement,
        timeout: TimeInterval
    ) throws -> AXUIElement {
        try waitForElement(description: value, timeout: timeout) {
            self.attribute(element, kAXValueAttribute as CFString) as? String == value ? element : nil
        }
    }

    private func waitForWindow(title: String, timeout: TimeInterval) throws -> AXUIElement {
        try waitForElement(description: title, timeout: timeout) {
            self.windows().first { self.attribute($0, kAXTitleAttribute as CFString) as? String == title }
        }
    }

    private func waitForElement(
        description: String,
        timeout: TimeInterval,
        lookup: () -> AXUIElement?
    ) throws -> AXUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            activate()
            if let element = lookup() { return element }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        throw BaselineFailure(message: "timed out waiting for \(description)")
    }

    private func activate() {
        runningApp.activate(options: [.activateAllWindows])
    }

    private func find(identifier: String) -> AXUIElement? {
        find { self.attribute($0, kAXIdentifierAttribute as CFString) as? String == identifier }
    }

    private func find(identifierPrefix: String) -> AXUIElement? {
        find {
            (self.attribute($0, kAXIdentifierAttribute as CFString) as? String)?
                .hasPrefix(identifierPrefix) == true
        }
    }

    private func find(text: String) -> AXUIElement? {
        find { element in
            for name in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
                if self.attribute(element, name as CFString) as? String == text { return true }
            }
            return false
        }
    }

    private func find(where predicate: (AXUIElement) -> Bool) -> AXUIElement? {
        var queue = [application!]
        var index = 0
        var seen = Set<CFHashCode>()
        while index < queue.count {
            let element = queue[index]
            index += 1
            guard seen.insert(CFHash(element)).inserted else { continue }
            if predicate(element) { return element }
            if let children = attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }
        return nil
    }

    private func windows() -> [AXUIElement] {
        attribute(application, kAXWindowsAttribute as CFString) as? [AXUIElement] ?? []
    }

    private func close(window: AXUIElement) throws {
        guard let button = (attribute(window, kAXChildrenAttribute as CFString) as? [AXUIElement])?
            .first(where: { attribute($0, kAXSubroleAttribute as CFString) as? String == kAXCloseButtonSubrole })
        else { throw BaselineFailure(message: "Settings close button is unavailable") }
        guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
            throw BaselineFailure(message: "could not close Settings window")
        }
    }

    private func frame(of element: AXUIElement) throws -> CGRect {
        guard let positionValue = attribute(element, kAXPositionAttribute as CFString),
              let sizeValue = attribute(element, kAXSizeAttribute as CFString)
        else { throw BaselineFailure(message: "element frame is unavailable") }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { throw BaselineFailure(message: "element frame is invalid") }
        return CGRect(origin: position, size: size)
    }

    private func setSize(_ size: CGSize, on window: AXUIElement) throws {
        var value = size
        guard let axValue = AXValueCreate(.cgSize, &value),
              AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, axValue) == .success
        else { throw BaselineFailure(message: "could not replay resize trace") }
    }

    private func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }

    private func wait(until uptime: TimeInterval) {
        while true {
            let remaining = uptime - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { return }
            if remaining > 0.002 { Thread.sleep(forTimeInterval: remaining - 0.001) }
        }
    }

    private func elapsedMilliseconds(since start: TimeInterval) -> Double {
        (ProcessInfo.processInfo.systemUptime - start) * 1_000
    }

    private func emitMetric(
        name: String,
        value: Double,
        phase: String,
        startEvent: String,
        stopEvent: String,
        source: String
    ) throws {
        try emit(prefix: "INSIGHTKIT_BENCHMARK_METRIC", row: [
            "run_id": config.runID,
            "run_kind": config.runKind,
            "record_count": config.recordCount,
            "metric": name,
            "value": value,
            "unit": "ms",
            "direction": "lower",
            "component": "app",
            "phase": phase,
            "start_event": startEvent,
            "stop_event": stopEvent,
            "measurement_source": source,
        ])
    }

    private func emitWindow(name: String, start: TimeInterval) throws {
        let stop = ProcessInfo.processInfo.systemUptime
        let stopWall = Date().timeIntervalSince1970
        try emit(prefix: "INSIGHTKIT_BENCHMARK_WINDOW", row: [
            "run_id": config.runID,
            "run_kind": config.runKind,
            "record_count": config.recordCount,
            "name": name,
            "start_uptime_seconds": start,
            "stop_uptime_seconds": stop,
            "start_wall_seconds": stopWall - (stop - start),
            "stop_wall_seconds": stopWall,
        ])
    }

    private func emit(prefix: String, row: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        print("\(prefix) \(String(decoding: data, as: UTF8.self))")
        fflush(stdout)
    }
}

do {
    let config = try Configuration(arguments: Array(CommandLine.arguments.dropFirst()))
    try InstalledAppBaseline(config: config).run()
} catch {
    fputs("INSIGHTKIT_BENCHMARK_FAILURE \(error.localizedDescription)\n", stderr)
    exit(1)
}
