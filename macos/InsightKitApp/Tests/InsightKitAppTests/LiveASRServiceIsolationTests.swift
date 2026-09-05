import XCTest
@testable import InsightKitApp

final class LiveASRServiceIsolationTests: XCTestCase {
    func testSessionIDOnlyLaunchIsolatesTheASRChild() throws {
        try assertIsolatedLaunch(
            environment: [UITestStorageContext.sessionIDEnvironmentKey: UUID().uuidString]
        )
    }

    func testModeEnvironmentLaunchIsolatesTheASRChild() throws {
        try assertIsolatedLaunch(environment: ["INSIGHTKIT_UI_TEST_MODE": "1"])
    }

    func testLongModeArgumentLaunchIsolatesTheASRChild() throws {
        try assertIsolatedLaunch(arguments: ["InsightKitApp", "--ui-test-mode"])
    }

    func testPairedModeArgumentLaunchIsolatesTheASRChild() throws {
        try assertIsolatedLaunch(arguments: ["InsightKitApp", "-INSIGHTKIT_UI_TEST_MODE", "1"])
    }

    func testNonUITestASRChildPreservesExplicitSyntheticConfiguration() throws {
        let environment = syntheticParentEnvironment
        var expected = environment
        expected.removeValue(forKey: "PATH")
        expected["PYTHONDONTWRITEBYTECODE"] = "1"

        try assertChildEnvironment(
            environment: environment,
            arguments: ["InsightKitApp"],
            expected: expected,
            absent: []
        )
    }

    private func assertIsolatedLaunch(
        environment launchEnvironment: [String: String] = [:],
        arguments: [String] = ["InsightKitApp"]
    ) throws {
        let environment = syntheticParentEnvironment.merging(launchEnvironment) { _, launch in launch }
        let context = try XCTUnwrap(UITestStorageContext.resolve(environment: environment, arguments: arguments))
        let huggingFaceHome = context.rootDirectory.appendingPathComponent("cache/huggingface", isDirectory: true)
        let expected = [
            "INSIGHTKIT_UI_TEST_MODE": "1",
            UITestStorageContext.sessionIDEnvironmentKey: context.sessionID.uuidString,
            "INSIGHTKIT_SOCKET": context.socketPath,
            "INSIGHTKIT_RECORDS_ROOT": context.recordsDirectory.path,
            "INSIGHTKIT_UI_TEST_CAPTURE_ROOT": context.captureDirectory.path,
            "INSIGHTKIT_DB_PATH": context.rootDirectory.appendingPathComponent("data/insightkit.db").path,
            "HF_HOME": huggingFaceHome.path,
            "HF_TOKEN_PATH": huggingFaceHome.appendingPathComponent("token").path,
            "PYTHONDONTWRITEBYTECODE": "1",
        ]

        try assertChildEnvironment(
            environment: environment,
            arguments: arguments,
            expected: expected,
            absent: credentialNames
        )
    }

    private func assertChildEnvironment(
        environment: [String: String],
        arguments: [String],
        expected: [String: String],
        absent: [String]
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveASRServiceIsolationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let wavURL = root.appendingPathComponent("synthetic.wav")
        try Data().write(to: wavURL)
        let scriptURL = root.appendingPathComponent("synthetic-asr.sh")
        var checks = absent.map { name in
            "test -z \"${\(name)+x}\" || { printf '%s\\n' 'unexpected variable: \(name)' >&2; exit 41; }"
        }
        checks += expected.keys.sorted().map { name in
            "test \"${\(name)-}\" = \(shellLiteral(expected[name]!)) || { printf '%s\\n' 'unexpected value: \(name)' >&2; exit 42; }"
        }
        let script = """
        #!/bin/sh
        \(checks.joined(separator: "\n"))
        test "$#" = 4 || exit 43
        test "$1" = '--wav' || exit 44
        test "$2" = \(shellLiteral(wavURL.path)) || exit 45
        test "$3" = '--offset-ms' || exit 46
        test "$4" = 1200 || exit 47
        printf '%s\\n' '{"segments":[{"start_ms":1200,"end_ms":1600,"speaker":"SPEAKER_00","text":"synthetic transcript","confidence":0.9}]}'
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let service = LiveASRService(
            pythonBinary: "/bin/sh",
            scriptPath: scriptURL.path,
            timeoutSec: 5,
            maxRetries: 0,
            environment: environment,
            arguments: arguments
        )

        let segments = try service.transcribe(
            chunk: AudioChunk(index: 0, url: wavURL, startMs: 1200, endMs: 1600, rms: 0.2),
            source: "mic"
        )

        XCTAssertEqual(segments, [
            RPCSegmentDelta(
                startMs: 1200, endMs: 1600, speaker: "SPEAKER_00",
                text: "synthetic transcript", confidence: 0.9, source: "mic"
            ),
        ])
    }

    private func shellLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private let credentialNames = [
        "OPENAI_API_KEY", "GEMINI_API_KEY", "DEEPSEEK_API_KEY", "QWEN_API_KEY", "DOUBAO_API_KEY",
        "HF_TOKEN", "PYANNOTE_AUTH_TOKEN", "GH_TOKEN", "GITHUB_TOKEN", "AWS_ACCESS_KEY_ID",
        "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "UNRELATED_OPERATOR_VALUE",
        "HUGGING_FACE_HUB_TOKEN", "HUGGINGFACE_HUB_CACHE", "HF_HUB_CACHE", "HF_ASSETS_CACHE",
    ]

    private var syntheticParentEnvironment: [String: String] {
        Dictionary(uniqueKeysWithValues: credentialNames.map { ($0, "synthetic-only-\($0)") }).merging([
            "PATH": "/usr/bin:/bin",
            "INSIGHTKIT_UI_TEST_MODE": "0",
            "INSIGHTKIT_SOCKET": "/tmp/synthetic-parent.sock",
            "INSIGHTKIT_RECORDS_ROOT": "/tmp/synthetic-parent-records",
            "INSIGHTKIT_UI_TEST_CAPTURE_ROOT": "/tmp/synthetic-parent-capture",
            "INSIGHTKIT_DB_PATH": "/tmp/synthetic-parent-db/insightkit.db",
            "HF_HOME": "/tmp/synthetic-parent-huggingface",
            "HF_TOKEN_PATH": "/tmp/synthetic-parent-huggingface/token",
        ]) { _, runtime in runtime }
    }
}
