import XCTest
@testable import InsightKitApp

final class AppConfigStoreTests: XCTestCase {
    func testLocalAnalysisModeIsIndependentFromASREngineAndCloudCredentials() throws {
        var config = makeRuntimeConfig(
            selectedVendor: .deepseek,
            providers: [
                .init(vendor: .deepseek, baseURL: "https://api.deepseek.com", modelID: "deepseek-v4-flash", apiKeyRef: "vendor.deepseek.api_key", extraHeaders: [:]),
            ]
        )
        config.asr.engine = .qwenmlx
        config.analysis.mode = .local

        let env = AppConfigStore.buildSidecarEnvironment(
            config: config,
            processEnvironment: ["DEEPSEEK_API_KEY": "must-not-be-forwarded"]
        ) { _, _ in "must-not-be-read" }

        XCTAssertEqual(config.asr.engine, .qwenmlx)
        XCTAssertEqual(env["INSIGHTKIT_ASR_ENGINE"], LocalASREngine.qwenmlx.rawValue)
        XCTAssertEqual(env["INSIGHTKIT_ANALYSIS_MODE"], "local")
        XCTAssertEqual(env["OPENAI_API_KEY"], "")
        XCTAssertEqual(env["GEMINI_API_KEY"], "")
        XCTAssertEqual(env["DEEPSEEK_API_KEY"], "")
        XCTAssertEqual(env["QWEN_API_KEY"], "")
        XCTAssertEqual(env["DOUBAO_API_KEY"], "")
    }

    func testLocalToCloudTransitionBumpsSidecarRevisionAndReloadsCloudCredential() throws {
        let suiteName = "AppConfigStoreTests-analysis-mode-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let snapshot = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName)
            .appendingPathComponent("runtime_config_v1.json")
        let store = AppConfigStore(defaults: defaults, configSnapshotURL: snapshot)
        let initialRevision = store.configRevision

        store.updateAnalysisMode(.local)
        let localRevision = store.configRevision
        store.updateAnalysisMode(.cloud)

        XCTAssertGreaterThan(localRevision, initialRevision)
        XCTAssertGreaterThan(store.configRevision, localRevision)

        var config = store.config
        config.analysis.selectedVendor = .deepseek
        config.analysis.mode = .local
        let localEnvironment = AppConfigStore.buildSidecarEnvironment(
            config: config,
            processEnvironment: [:]
        ) { _, _ in "cloud-secret" }
        config.analysis.mode = .cloud
        let cloudEnvironment = AppConfigStore.buildSidecarEnvironment(
            config: config,
            processEnvironment: [:]
        ) { _, _ in "cloud-secret" }

        XCTAssertEqual(localEnvironment["DEEPSEEK_API_KEY"], "")
        XCTAssertEqual(cloudEnvironment["DEEPSEEK_API_KEY"], "cloud-secret")
    }

    func testRepairRestoresSingleProviderCopiedFromAnotherVendorDefault() {
        let config = makeRuntimeConfig(
            selectedVendor: .openai,
            providers: [
                .init(vendor: .deepseek, baseURL: "https://api.deepseek.com", modelID: "deepseek-v4-flash", apiKeyRef: "vendor.deepseek.api_key", extraHeaders: [:]),
                .init(vendor: .doubao, baseURL: "https://ark.cn-beijing.volces.com/api/v3", modelID: "doubao-seed-1-8-251228", apiKeyRef: "vendor.doubao.api_key", extraHeaders: [:]),
                .init(vendor: .openai, baseURL: "https://api.deepseek.com", modelID: "deepseek-v4-flash", apiKeyRef: "vendor.openai.api_key", extraHeaders: [:]),
                .init(vendor: .gemini, baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", modelID: "gemini-2.5-flash", apiKeyRef: "vendor.gemini.api_key", extraHeaders: [:]),
            ]
        )

        let repaired = AppConfigStore.repairCorruptedAnalysisProfiles(in: config)

        XCTAssertTrue(repaired.changed)
        XCTAssertEqual(repaired.config.analysis.selectedVendor, .openai)
        XCTAssertEqual(repaired.config.analysis.providers.map(\.vendor), ProviderVendor.allCases)

        let openAI = profile(.openai, in: repaired.config)
        XCTAssertEqual(openAI.baseURL, "https://api.openai.com/v1")
        XCTAssertEqual(openAI.modelID, "gpt-4.1-mini")

        let deepSeek = profile(.deepseek, in: repaired.config)
        XCTAssertEqual(deepSeek.baseURL, "https://api.deepseek.com")
        XCTAssertEqual(deepSeek.modelID, "deepseek-v4-flash")

        let qwen = profile(.qwen, in: repaired.config)
        XCTAssertEqual(qwen.baseURL, "https://dashscope.aliyuncs.com/compatible-mode/v1")
        XCTAssertEqual(qwen.modelID, "qwen-plus-latest")
    }

    func testRepairPreservesCustomCompatibleEndpointWhenItDoesNotMatchAnotherVendorDefault() {
        let config = makeRuntimeConfig(
            selectedVendor: .gemini,
            providers: [
                .init(vendor: .openai, baseURL: "https://api.openai.com/v1", modelID: "gpt-4.1-mini", apiKeyRef: "vendor.openai.api_key", extraHeaders: [:]),
                .init(vendor: .gemini, baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", modelID: "gemini-2.5-flash", apiKeyRef: "vendor.gemini.api_key", extraHeaders: [:]),
                .init(vendor: .deepseek, baseURL: "https://api.deepseek.com", modelID: "deepseek-v4-flash", apiKeyRef: "vendor.deepseek.api_key", extraHeaders: [:]),
                .init(vendor: .qwen, baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", modelID: "qwen-plus-latest", apiKeyRef: "vendor.qwen.api_key", extraHeaders: [:]),
                .init(vendor: .doubao, baseURL: "https://ark.cn-beijing.volces.com/api/v3", modelID: "doubao-seed-1-8-251228", apiKeyRef: "vendor.doubao.api_key", extraHeaders: [:]),
            ]
        )

        let repaired = AppConfigStore.repairCorruptedAnalysisProfiles(in: config)

        XCTAssertFalse(repaired.changed)
        let gemini = profile(.gemini, in: repaired.config)
        XCTAssertEqual(gemini.baseURL, "https://generativelanguage.googleapis.com/v1beta/openai")
        XCTAssertEqual(gemini.modelID, "gemini-2.5-flash")
        let doubao = profile(.doubao, in: repaired.config)
        XCTAssertEqual(doubao.modelID, "doubao-seed-1-8-251228")
    }

    func testSidecarEnvironmentUsesSilentKeychainReadsForProviderSecrets() {
        let config = RuntimeConfigV2(
            asr: RuntimeConfigV2.ASR(
                engine: .whisper,
                model: "large-v3",
                modelDir: "/tmp/models",
                vadEnabled: true,
                diarizationEnabled: false,
                whisperProfile: .init(model: "large-v3"),
                funasrProfile: .init(model: "iic/SenseVoiceSmall"),
                qwenProfile: .init(model: "Qwen3-ASR-1.7B-MLX-4bit")
            ),
            analysis: RuntimeConfigV2.Analysis(
                selectedVendor: .deepseek,
                providers: [
                    .init(vendor: .openai, baseURL: "https://api.openai.com/v1", modelID: "gpt-4.1-mini", apiKeyRef: "vendor.openai.api_key", extraHeaders: [:]),
                    .init(vendor: .gemini, baseURL: "https://generativelanguage.googleapis.com", modelID: "gemini-2.5-flash", apiKeyRef: "vendor.gemini.api_key", extraHeaders: [:]),
                    .init(vendor: .deepseek, baseURL: "https://api.deepseek.com", modelID: "deepseek-v4-flash", apiKeyRef: "vendor.deepseek.api_key", extraHeaders: [:]),
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

        XCTAssertNil(interactionFlags[.openai])
        XCTAssertNil(interactionFlags[.gemini])
        XCTAssertEqual(interactionFlags[.deepseek], false)
        XCTAssertNil(interactionFlags[.qwen])
        XCTAssertNil(interactionFlags[.doubao])
        XCTAssertEqual(env["INSIGHTKIT_PROVIDER_VENDOR"], ProviderVendor.deepseek.rawValue)
        XCTAssertEqual(env["DEEPSEEK_API_KEY"], "secret-deepseek")
        XCTAssertNil(env["OPENAI_API_KEY"])
        XCTAssertNil(env["GEMINI_API_KEY"])
        XCTAssertNil(env["QWEN_API_KEY"])
        XCTAssertNil(env["DOUBAO_API_KEY"])
        XCTAssertEqual(env["HF_TOKEN"], "hf-token")
        XCTAssertEqual(env["INSIGHTKIT_QWEN_MLX_MODEL"], "Qwen3-ASR-1.7B-MLX-4bit")
        XCTAssertEqual(env["INSIGHTKIT_DIARIZATION_ENGINE"], "fluid-lseend")
    }

    func testSidecarEnvironmentPassesFluidAudioOverrides() {
        let config = makeRuntimeConfig(
            selectedVendor: .deepseek,
            providers: [
                .init(vendor: .deepseek, baseURL: "https://api.deepseek.com", modelID: "deepseek-v4-flash", apiKeyRef: "vendor.deepseek.api_key", extraHeaders: [:]),
            ]
        )

        let env = AppConfigStore.buildSidecarEnvironment(
            config: config,
            processEnvironment: [
                "INSIGHTKIT_DIARIZATION_ENGINE": "pyannote",
                "INSIGHTKIT_FLUIDAUDIO_CLI": "/opt/fluidaudiocli",
            ]
        ) { _, _ in
            ""
        }

        XCTAssertEqual(env["INSIGHTKIT_DIARIZATION_ENGINE"], "pyannote")
        XCTAssertEqual(env["INSIGHTKIT_FLUIDAUDIO_CLI"], "/opt/fluidaudiocli")
    }

    func testSidecarEnvironmentCarriesAppleSpeechPrototypeFlagWithoutChangingEngine() {
        let config = makeRuntimeConfig(
            selectedVendor: .deepseek,
            providers: [
                .init(vendor: .deepseek, baseURL: "https://api.deepseek.com", modelID: "deepseek-v4-flash", apiKeyRef: "vendor.deepseek.api_key", extraHeaders: [:]),
            ],
            appleSpeechPrototypeEnabled: true
        )

        let env = AppConfigStore.buildSidecarEnvironment(
            config: config,
            processEnvironment: [:]
        ) { _, _ in
            ""
        }

        XCTAssertEqual(env["INSIGHTKIT_ASR_ENGINE"], "funasr")
        XCTAssertEqual(env["INSIGHTKIT_APPLE_SPEECH_PROTOTYPE_ENABLED"], "1")
    }

    func testAppleSpeechPrototypeIsNotListedAsPeerLocalASREngine() {
        XCTAssertEqual(LocalASREngine.allCases.map(\.rawValue), ["whisper", "funasr", "qwen-mlx"])
        XCTAssertFalse(LocalASREngine.allCases.map(\.displayName).contains("Apple Speech"))
    }

    func testSidecarEnvironmentFallsBackToProcessEnvForActiveProviderKey() {
        let config = RuntimeConfigV2(
            asr: RuntimeConfigV2.ASR(
                engine: .whisper,
                model: "large-v3",
                modelDir: "/tmp/models",
                vadEnabled: true,
                diarizationEnabled: false,
                whisperProfile: .init(model: "large-v3"),
                funasrProfile: .init(model: "iic/SenseVoiceSmall"),
                qwenProfile: .init(model: "Qwen3-ASR-1.7B-MLX-4bit")
            ),
            analysis: RuntimeConfigV2.Analysis(
                selectedVendor: .deepseek,
                providers: [
                    .init(vendor: .deepseek, baseURL: "https://api.deepseek.com", modelID: "deepseek-v4-flash", apiKeyRef: "vendor.deepseek.api_key", extraHeaders: [:]),
                ]
            ),
            strict: RuntimeConfigV2.Strict(strictMode: true),
            download: RuntimeConfigV2.Download(autoBootstrapEnabled: true)
        )

        let env = AppConfigStore.buildSidecarEnvironment(
            config: config,
            processEnvironment: ["DEEPSEEK_API_KEY": "env-deepseek"]
        ) { _, _ in
            ""
        }

        XCTAssertEqual(env["DEEPSEEK_API_KEY"], "env-deepseek")
    }

    private func makeRuntimeConfig(
        selectedVendor: ProviderVendor,
        providers: [ProviderProfile],
        appleSpeechPrototypeEnabled: Bool = false
    ) -> RuntimeConfigV2 {
        RuntimeConfigV2(
            asr: RuntimeConfigV2.ASR(
                engine: .funasr,
                model: "iic/speech_paraformer-large-vad-punc_asr_nat-zh-cn-16k-common-vocab8404-pytorch",
                modelDir: "/tmp/models",
                vadEnabled: true,
                diarizationEnabled: true,
                whisperProfile: .init(model: "large-v3"),
                funasrProfile: .init(model: "iic/speech_paraformer-large-vad-punc_asr_nat-zh-cn-16k-common-vocab8404-pytorch"),
                qwenProfile: .init(model: "Qwen3-ASR-1.7B-MLX-4bit"),
                appleSpeechPrototypeEnabled: appleSpeechPrototypeEnabled
            ),
            analysis: RuntimeConfigV2.Analysis(selectedVendor: selectedVendor, providers: providers),
            strict: RuntimeConfigV2.Strict(strictMode: true),
            download: RuntimeConfigV2.Download(autoBootstrapEnabled: true)
        )
    }

    private func profile(_ vendor: ProviderVendor, in config: RuntimeConfigV2) -> ProviderProfile {
        config.analysis.providers.first(where: { $0.vendor == vendor })!
    }
}
