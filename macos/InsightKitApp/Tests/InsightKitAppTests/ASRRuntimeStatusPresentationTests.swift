import XCTest
@testable import InsightKitApp

final class ASRRuntimeStatusPresentationTests: XCTestCase {
    func testReadyRuntimeDoesNotShowReadinessWarning() {
        let status = makeStatus(ready: true, modelExists: true)

        XCTAssertNil(status.userVisibleReadinessMessage)
        XCTAssertNil(status.userVisibleReadinessAccessibilityIdentifier)
    }

    func testMissingModelProducesActionableSettingsWarning() {
        let status = makeStatus(
            ready: false,
            modelExists: false,
            modelName: "large-v3",
            modelPath: "/Users/test/Library/Application Support/InsightKit/models/faster-whisper/large-v3"
        )

        let message = status.userVisibleReadinessMessage ?? ""
        XCTAssertTrue(message.contains("ASR 模型文件缺失"))
        XCTAssertTrue(message.contains("一键修复语音识别"))
        XCTAssertTrue(message.contains("large-v3"))
        XCTAssertTrue(message.contains("/Users/test/Library/Application Support/InsightKit/models/faster-whisper/large-v3"))
        XCTAssertEqual(status.userVisibleReadinessAccessibilityIdentifier, "settings_asr_model_missing_status")
    }

    func testWarmupFailureProducesRuntimeWarning() {
        let status = makeStatus(
            ready: false,
            modelExists: true,
            warm: ASRWarmStatus(
                ready: false,
                state: .failed,
                inProgress: false,
                attempt: 2,
                lastWarmMs: 0,
                lastError: "模型加载失败"
            )
        )

        let message = status.userVisibleReadinessMessage ?? ""
        XCTAssertTrue(message.contains("ASR 模型未就绪"))
        XCTAssertTrue(message.contains("模型加载失败"))
        XCTAssertEqual(status.userVisibleReadinessAccessibilityIdentifier, "settings_asr_runtime_warning_status")
    }

    private func makeStatus(
        ready: Bool,
        modelExists: Bool,
        modelName: String = "large-v3",
        modelPath: String = "/tmp/model",
        warm: ASRWarmStatus = ASRWarmStatus(
            ready: false,
            state: .idle,
            inProgress: false,
            attempt: 0,
            lastWarmMs: 0,
            lastError: ""
        )
    ) -> ASRRuntimeStatus {
        ASRRuntimeStatus(
            ready: ready,
            pythonExecutable: "/usr/bin/python3",
            pythonVersion: "3.11.0",
            engine: "whisper",
            engineOptions: ["whisper"],
            activeProfile: modelName,
            modelName: modelName,
            modelPath: modelPath,
            modelExists: modelExists,
            vadReady: true,
            diarizationReady: false,
            diarizationDegraded: true,
            diarizationReason: "missing token",
            readyByEngine: ["whisper": ready],
            backend: ASRBackendStatus(
                configuredDevice: "auto",
                configuredComputeType: "int8",
                device: "cpu",
                computeType: "int8",
                resolved: "cpu",
                supportedComputeTypes: ["int8"]
            ),
            warm: warm
        )
    }
}
