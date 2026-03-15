import XCTest
@testable import InsightKitApp

final class AppConfigStoreTests: XCTestCase {
    func testSidecarEnvironmentUsesSilentKeychainReadsForProviderSecrets() {
        let config = RuntimeConfigV2(
            asr: RuntimeConfigV2.ASR(
                engine: .whisper,
                model: "large-v3",
                modelDir: "/tmp/models",
                vadEnabled: true,
                diarizationEnabled: false,
                whisperProfile: .init(model: "large-v3"),
                funasrProfile: .init(model: "iic/SenseVoiceSmall")
            ),
            analysis: RuntimeConfigV2.Analysis(
                selectedVendor: .deepseek,
                providers: [
                    .init(vendor: .openai, baseURL: "https://api.openai.com/v1", modelID: "gpt-4.1-mini", apiKeyRef: "vendor.openai.api_key", extraHeaders: [:]),
                    .init(vendor: .gemini, baseURL: "https://generativelanguage.googleapis.com", modelID: "gemini-2.5-flash", apiKeyRef: "vendor.gemini.api_key", extraHeaders: [:]),
                    .init(vendor: .deepseek, baseURL: "https://api.deepseek.com/v1", modelID: "deepseek-chat", apiKeyRef: "vendor.deepseek.api_key", extraHeaders: [:]),
                    .init(vendor: .qwen, baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", modelID: "qwen-plus-latest", apiKeyRef: "vendor.qwen.api_key", extraHeaders: [:]),
                    .init(vendor: .doubao, baseURL: "https://ark.cn-beijing.volces.com/api/v3", modelID: "doubao-seed-1-6-250615", apiKeyRef: "vendor.doubao.api_key", extraHeaders: [:]),
                ]
            ),
            strict: RuntimeConfigV2.Strict(strictMode: true),
            download: RuntimeConfigV2.Download(autoBootstrapEnabled: true)
        )

        var interactionFlags: [ProviderVendor: Bool] = [:]
        let env = AppConfigStore.buildSidecarEnvironment(
            config: config,
            processEnvironment: ["HF_TOKEN": "hf-token"]
        ) { vendor, allowUserInteraction in
            interactionFlags[vendor] = allowUserInteraction
            return "secret-\(vendor.rawValue)"
        }

        XCTAssertEqual(interactionFlags[.openai], false)
        XCTAssertEqual(interactionFlags[.gemini], false)
        XCTAssertEqual(interactionFlags[.deepseek], false)
        XCTAssertEqual(interactionFlags[.qwen], false)
        XCTAssertEqual(interactionFlags[.doubao], false)
        XCTAssertEqual(env["INSIGHTKIT_PROVIDER_VENDOR"], ProviderVendor.deepseek.rawValue)
        XCTAssertEqual(env["DEEPSEEK_API_KEY"], "secret-deepseek")
        XCTAssertEqual(env["OPENAI_API_KEY"], "secret-openai")
        XCTAssertEqual(env["HF_TOKEN"], "hf-token")
    }
}
