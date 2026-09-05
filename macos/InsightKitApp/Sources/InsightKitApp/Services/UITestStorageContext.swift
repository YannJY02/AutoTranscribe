import Foundation

/// A UI-test run owns its preferences and files across app relaunches.
/// The runner also compiles this type so both processes use the same namespace.
struct UITestStorageContext {
    static let sessionIDEnvironmentKey = "INSIGHTKIT_UI_TEST_SESSION_ID"
    static let hostBundleIdentifier = "com.yannjy.insightkit.uitesthost"
    private static let fallbackSessionID = UUID()

    let sessionID: UUID
    let temporaryDirectory: URL

    init(sessionID: UUID, temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.sessionID = sessionID
        self.temporaryDirectory = temporaryDirectory
    }

    static var current: UITestStorageContext? {
        resolve(environment: ProcessInfo.processInfo.environment, arguments: ProcessInfo.processInfo.arguments)
    }

    static func resolve(
        environment: [String: String],
        arguments: [String] = []
    ) -> UITestStorageContext? {
        if let value = environment[sessionIDEnvironmentKey], let sessionID = UUID(uuidString: value) {
            return UITestStorageContext(sessionID: sessionID)
        }
        let enabledByPair = arguments.indices.contains { index in
            arguments[index] == "-INSIGHTKIT_UI_TEST_MODE"
                && arguments.indices.contains(index + 1) && arguments[index + 1] == "1"
        }
        guard environment["INSIGHTKIT_UI_TEST_MODE"] == "1"
            || arguments.contains("--ui-test-mode") || enabledByPair
        else { return nil }
        // Ad-hoc UI-test launches must also stay away from operator storage.
        return UITestStorageContext(sessionID: fallbackSessionID)
    }

    var defaultsSuiteName: String { "com.yannjy.insightkit.uitest.\(sessionID.uuidString)" }
    var rootDirectory: URL {
        temporaryDirectory.appendingPathComponent("InsightKitUITest-\(sessionID.uuidString)", isDirectory: true)
    }
    var recordsDirectory: URL { rootDirectory.appendingPathComponent("Records", isDirectory: true) }
    var configSnapshotURL: URL { rootDirectory.appendingPathComponent("runtime_config_v1.json") }
    var captureDirectory: URL {
        rootDirectory.appendingPathComponent("InsightKitUITestEvidence-\(sessionID.uuidString)", isDirectory: true)
    }

    var launchEnvironment: [String: String] {
        [
            Self.sessionIDEnvironmentKey: sessionID.uuidString,
            "INSIGHTKIT_UI_TEST_MODE": "1",
            "INSIGHTKIT_UI_TEST_CAPTURE_ROOT": captureDirectory.path,
            "INSIGHTKIT_RECORDS_ROOT": recordsDirectory.path,
            // Unix socket paths have a short platform limit.
            "INSIGHTKIT_SOCKET": "/tmp/ik-ui-\(sessionID.uuidString).sock",
        ]
    }

    func makeDefaults() -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            preconditionFailure("Cannot create isolated UI-test preferences")
        }
        return defaults
    }
}
