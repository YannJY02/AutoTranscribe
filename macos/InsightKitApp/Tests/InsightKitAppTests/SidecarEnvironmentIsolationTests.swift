import XCTest
@testable import InsightKitApp

final class SidecarEnvironmentIsolationTests: XCTestCase {
    func testUITestConfigurationDoesNotForwardInheritedCredentials() throws {
        let context = UITestStorageContext(sessionID: UUID())
        defer { cleanUp(context) }
        let store = AppConfigStore.makeUITestStore(context: context)

        let environment = store.sidecarEnvironment(processEnvironment: syntheticParentEnvironment)

        for name in credentialNames {
            XCTAssertTrue(environment[name, default: ""].isEmpty, "Configuration forwarded \(name)")
        }
        XCTAssertEqual(environment["INSIGHTKIT_DIARIZATION_ENGINE"], "pyannote")
    }

    func testEveryUITestEntrypointRemovesCredentialsAfterFinalEnvironmentMerge() throws {
        for (launchEnvironment, arguments) in launches {
            let context = UITestStorageContext(sessionID: UUID())
            defer { cleanUp(context) }
            let store = AppConfigStore.makeUITestStore(context: context)
            let inherited = syntheticParentEnvironment.merging(launchEnvironment) { _, launch in launch }
            let resolvedContext = try XCTUnwrap(UITestStorageContext.resolve(environment: inherited, arguments: arguments))
            var merged = PythonRuntimeEnvironment.prepared(
                from: inherited,
                runtimeRoot: "/tmp/synthetic-runtime",
                arguments: arguments
            )
            let configured = store.sidecarEnvironment(processEnvironment: inherited)
            merged.merge(configured) { _, configured in configured }
            let childEnvironment = SidecarManager.childEnvironment(from: merged, arguments: arguments)

            for name in credentialNames {
                XCTAssertNil(childEnvironment[name], "Child inherited \(name)")
            }
            XCTAssertEqual(childEnvironment["INSIGHTKIT_RUNTIME_ROOT"], "/tmp/synthetic-runtime")
            XCTAssertEqual(childEnvironment["INSIGHTKIT_DIARIZATION_ENGINE"], "pyannote")
            XCTAssertEqual(childEnvironment["PYTHONDONTWRITEBYTECODE"], "1")
            XCTAssertEqual(childEnvironment["PATH"], merged["PATH"])
            for (name, value) in configured where !credentialNames.contains(name) {
                XCTAssertEqual(childEnvironment[name], value, "Required configuration lost: \(name)")
            }
            XCTAssertEqual(childEnvironment["INSIGHTKIT_UI_TEST_MODE"], "1")
            XCTAssertEqual(childEnvironment[UITestStorageContext.sessionIDEnvironmentKey], resolvedContext.sessionID.uuidString)
            XCTAssertEqual(childEnvironment["INSIGHTKIT_SOCKET"], resolvedContext.socketPath)
            XCTAssertEqual(childEnvironment["INSIGHTKIT_RECORDS_ROOT"], resolvedContext.recordsDirectory.path)
            XCTAssertEqual(childEnvironment["INSIGHTKIT_UI_TEST_CAPTURE_ROOT"], resolvedContext.captureDirectory.path)
            XCTAssertEqual(childEnvironment["INSIGHTKIT_DB_PATH"], resolvedContext.rootDirectory.appendingPathComponent("data/insightkit.db").path)
            let huggingFaceHome = resolvedContext.rootDirectory.appendingPathComponent("cache/huggingface", isDirectory: true)
            XCTAssertEqual(childEnvironment["HF_HOME"], huggingFaceHome.path)
            XCTAssertEqual(childEnvironment["HF_TOKEN_PATH"], huggingFaceHome.appendingPathComponent("token").path)

            // The child reports only an exit status; no credential value is printed.
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sh")
            child.arguments = ["-c", "test -z \"${OPENAI_API_KEY+x}${GEMINI_API_KEY+x}${DEEPSEEK_API_KEY+x}${QWEN_API_KEY+x}${DOUBAO_API_KEY+x}${HF_TOKEN+x}${PYANNOTE_AUTH_TOKEN+x}${GH_TOKEN+x}${GITHUB_TOKEN+x}${AWS_ACCESS_KEY_ID+x}${AWS_SECRET_ACCESS_KEY+x}${AWS_SESSION_TOKEN+x}${UNRELATED_OPERATOR_VALUE+x}${HUGGING_FACE_HUB_TOKEN+x}${HUGGINGFACE_HUB_CACHE+x}${HF_HUB_CACHE+x}${HF_ASSETS_CACHE+x}\" && test \"$INSIGHTKIT_UI_TEST_MODE\" = 1"]
            child.environment = childEnvironment
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try child.run()
            child.waitUntilExit()
            XCTAssertEqual(child.terminationStatus, 0, "Final child process retained a credential variable")
        }
    }

    func testNonUITestChildEnvironmentPreservesOperatorCredentials() {
        let environment = syntheticParentEnvironment

        XCTAssertEqual(SidecarManager.childEnvironment(from: environment, arguments: ["InsightKitApp"]), environment)
    }

    func testPythonDiscoveryProbesUseTheIsolatedChildEnvironment() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InsightKitPythonProbeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = syntheticParentEnvironment.merging([
            UITestStorageContext.sessionIDEnvironmentKey: UUID().uuidString,
        ]) { _, launch in launch }
        let versionProbe = try makeProbeFixture(at: root.appendingPathComponent("version"), output: "3.11.0")
        let dependencyProbe = try makeProbeFixture(at: root.appendingPathComponent("dependencies"), output: "1")

        let version = SidecarManager.pythonVersion(for: versionProbe, environment: environment)

        XCTAssertEqual(version?.0, 3)
        XCTAssertEqual(version?.1, 11)
        XCTAssertEqual(version?.2, 0)
        XCTAssertTrue(SidecarManager.pythonHasASRDeps(for: dependencyProbe, environment: environment))
    }

    func testEveryUITestEntrypointKeepsSidecarLogsInsideItsContext() throws {
        let syntheticHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("InsightKitLogPathTests-\(UUID().uuidString)")

        for (launchEnvironment, arguments) in launches {
            let inherited = syntheticParentEnvironment.merging(launchEnvironment) { _, launch in launch }
            let context = try XCTUnwrap(UITestStorageContext.resolve(environment: inherited, arguments: arguments))

            let path = SidecarManager.resolveLogPath(
                environment: inherited,
                arguments: arguments,
                homeDirectory: syntheticHome
            )

            XCTAssertEqual(path, context.captureDirectory.appendingPathComponent("diagnostics/sidecar.log").path)
            XCTAssertFalse(path.hasPrefix(syntheticHome.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: syntheticHome.path), "Path resolution must not create operator directories")
    }

    func testNonUITestLogPathPreservesTheOperatorLocationWithoutCreatingIt() {
        let syntheticHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("InsightKitLogPathTests-\(UUID().uuidString)")

        let path = SidecarManager.resolveLogPath(
            environment: syntheticParentEnvironment,
            arguments: ["InsightKitApp"],
            homeDirectory: syntheticHome
        )

        XCTAssertEqual(path, syntheticHome.appendingPathComponent("Library/Logs/InsightKit/sidecar.log").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: syntheticHome.path))
    }

    private let credentialNames = [
        "OPENAI_API_KEY", "GEMINI_API_KEY", "DEEPSEEK_API_KEY", "QWEN_API_KEY", "DOUBAO_API_KEY",
        "HF_TOKEN", "PYANNOTE_AUTH_TOKEN",
        "GH_TOKEN", "GITHUB_TOKEN", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN",
        "UNRELATED_OPERATOR_VALUE", "HUGGING_FACE_HUB_TOKEN", "HUGGINGFACE_HUB_CACHE", "HF_HUB_CACHE", "HF_ASSETS_CACHE",
    ]

    private var syntheticParentEnvironment: [String: String] {
        Dictionary(uniqueKeysWithValues: credentialNames.map { ($0, "synthetic-only-\($0)") }).merging([
            "PATH": "/usr/bin:/bin",
            "INSIGHTKIT_DIARIZATION_ENGINE": "pyannote",
            "INSIGHTKIT_UI_TEST_MODE": "0",
            "INSIGHTKIT_SOCKET": "/tmp/synthetic-operator.sock",
            "INSIGHTKIT_RECORDS_ROOT": "/tmp/synthetic-operator-records",
            "INSIGHTKIT_UI_TEST_CAPTURE_ROOT": "/tmp/synthetic-operator-capture",
            "INSIGHTKIT_DB_PATH": "/tmp/synthetic-operator-db/insightkit.db",
            "HF_HOME": "/tmp/synthetic-operator-huggingface",
            "HF_TOKEN_PATH": "/tmp/synthetic-operator-huggingface/token",
        ]) { _, runtime in runtime }
    }

    private var launches: [([String: String], [String])] {
        [
            ([UITestStorageContext.sessionIDEnvironmentKey: UUID().uuidString], ["InsightKitApp"]),
            (["INSIGHTKIT_UI_TEST_MODE": "1"], ["InsightKitApp"]),
            ([:], ["InsightKitApp", "--ui-test-mode"]),
            ([:], ["InsightKitApp", "-INSIGHTKIT_UI_TEST_MODE", "1"]),
        ]
    }

    private func cleanUp(_ context: UITestStorageContext) {
        context.makeDefaults().removePersistentDomain(forName: context.defaultsSuiteName)
        try? FileManager.default.removeItem(at: context.rootDirectory)
    }

    private func makeProbeFixture(at url: URL, output: String) throws -> String {
        let script = """
        #!/bin/sh
        test -z "${GH_TOKEN+x}${AWS_SECRET_ACCESS_KEY+x}${HF_TOKEN+x}${PYANNOTE_AUTH_TOKEN+x}" || exit 42
        test "$INSIGHTKIT_UI_TEST_MODE" = 1 || exit 43
        printf '%s\\n' '\(output)'
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url.path
    }
}
