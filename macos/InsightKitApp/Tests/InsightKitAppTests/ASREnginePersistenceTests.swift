import XCTest
@testable import InsightKitApp

final class ASREnginePersistenceTests: XCTestCase {
    func testEngineSwitchKeepsPerEngineModel() {
        let store = AppConfigStore.shared
        let original = store.config
        defer {
            store.updateASRProfileModel(engine: .whisper, model: original.asr.whisperProfile.model)
            store.updateASRProfileModel(engine: .funasr, model: original.asr.funasrProfile.model)
            store.updateASR(
                engine: original.asr.engine,
                model: original.asr.model,
                modelDir: original.asr.modelDir,
                vadEnabled: original.asr.vadEnabled,
                diarizationEnabled: original.asr.diarizationEnabled
            )
        }

        store.updateASRProfileModel(engine: .whisper, model: "large-v3")
        store.updateASRProfileModel(engine: .funasr, model: "iic/speech_paraformer-test")

        store.updateASREngine(.funasr)
        XCTAssertEqual(store.currentASRModel(), "iic/speech_paraformer-test")

        store.updateASREngine(.whisper)
        XCTAssertEqual(store.currentASRModel(), "large-v3")
    }
}
