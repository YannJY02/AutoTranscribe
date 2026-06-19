import XCTest
@testable import InsightKitApp

final class ASREnginePersistenceTests: XCTestCase {
    func testEngineSwitchKeepsPerEngineModel() throws {
        let suiteName = "ASREnginePersistenceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ASREnginePersistenceTests-\(UUID().uuidString)")
            .appendingPathComponent("runtime_config_v1.json")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: snapshotURL.deletingLastPathComponent())
        }

        let store = AppConfigStore(defaults: defaults, configSnapshotURL: snapshotURL)

        store.updateASRProfileModel(engine: .whisper, model: "large-v3")
        store.updateASRProfileModel(engine: .funasr, model: "iic/speech_paraformer-test")
        store.updateASRProfileModel(engine: .qwenmlx, model: "Qwen3-ASR-1.7B-MLX-4bit")

        store.updateASREngine(.funasr)
        XCTAssertEqual(store.currentASRModel(), "iic/speech_paraformer-test")

        store.updateASREngine(.qwenmlx)
        XCTAssertEqual(store.currentASRModel(), "Qwen3-ASR-1.7B-MLX-4bit")

        store.updateASREngine(.whisper)
        XCTAssertEqual(store.currentASRModel(), "large-v3")
    }
}
