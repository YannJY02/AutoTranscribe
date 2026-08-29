import Foundation

final class AppConfigStore: ObservableObject {
    static let shared = AppConfigStore.makeSharedStore()

    @Published private(set) var config: RuntimeConfigV2
    @Published private(set) var configRevision: Int = 0

    private let defaultsKey = "insightkit.runtime.config.v1"
    private let defaultsKeyV2 = "insightkit.runtime.config.v2"
    private let defaults: UserDefaults
    private let configSnapshotURL: URL
    private let keychain = KeychainService()

    private static func makeSharedStore() -> AppConfigStore {
        guard isRunningTests else {
            return AppConfigStore()
        }

        let suiteName = "InsightKitAppTests-\(ProcessInfo.processInfo.processIdentifier)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        let snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName)
            .appendingPathComponent("runtime_config_v1.json")
        return AppConfigStore(defaults: defaults, configSnapshotURL: snapshotURL)
    }

    private static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        if isUITestMode {
            return true
        }
        if environment.keys.contains(where: { $0.localizedCaseInsensitiveContains("xctest") }) {
            return true
        }

        let processName = ProcessInfo.processInfo.processName.lowercased()
        if processName.contains("xctest") || processName.contains("packagetests") {
            return true
        }

        return Bundle.allBundles.contains { bundle in
            let path = bundle.bundlePath.lowercased()
            return path.hasSuffix(".xctest") || path.contains(".xctest/")
        }
    }

    init(
        defaults: UserDefaults = .standard,
        configSnapshotURL: URL = AppConfigStore.configSnapshotPath()
    ) {
        self.defaults = defaults
        self.configSnapshotURL = configSnapshotURL
        if
            let raw = defaults.data(forKey: defaultsKeyV2),
            let decoded = try? JSONDecoder().decode(RuntimeConfigV2.self, from: raw)
        {
            config = decoded
        } else if
            let raw = defaults.data(forKey: defaultsKey),
            let decoded = try? JSONDecoder().decode(RuntimeConfigV2.self, from: raw)
        {
            config = decoded
        } else {
            config = Self.defaultConfig()
            persist()
        }
        let repaired = normalizeCorruptedAnalysisProfilesIfNeeded()
        if repaired {
            persist()
        } else {
            writeConfigSnapshot()
        }
    }

    func updateASR(
        engine: LocalASREngine? = nil,
        model: String,
        modelDir: String,
        vadEnabled: Bool,
        diarizationEnabled: Bool
    ) {
        let normalizedEngine = engine ?? config.asr.engine
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDir = modelDir.trimmingCharacters(in: .whitespacesAndNewlines)
        if config.asr.engine == normalizedEngine,
           config.asr.model == normalizedModel,
           config.asr.modelDir == normalizedDir,
           config.asr.vadEnabled == vadEnabled,
           config.asr.diarizationEnabled == diarizationEnabled
        {
            return
        }
        config.asr.engine = normalizedEngine
        config.asr.model = normalizedModel
        config.asr.modelDir = normalizedDir
        config.asr.vadEnabled = vadEnabled
        config.asr.diarizationEnabled = diarizationEnabled
        syncActiveASRModel()
        persist()
    }

    func updateASREngine(_ engine: LocalASREngine) {
        if config.asr.engine == engine {
            return
        }
        config.asr.engine = engine
        syncActiveASRModel()
        persist()
    }

    func updateAppleSpeechPrototypeEnabled(_ enabled: Bool) {
        if config.asr.appleSpeechPrototypeEnabled == enabled {
            return
        }
        config.asr.appleSpeechPrototypeEnabled = enabled
        persist()
    }

    func updateASRProfileModel(engine: LocalASREngine, model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        switch engine {
        case .whisper:
            if config.asr.whisperProfile.model == trimmed {
                return
            }
            config.asr.whisperProfile.model = trimmed
        case .funasr:
            if config.asr.funasrProfile.model == trimmed {
                return
            }
            config.asr.funasrProfile.model = trimmed
        case .qwenmlx:
            if config.asr.qwenProfile.model == trimmed {
                return
            }
            config.asr.qwenProfile.model = trimmed
        }
        syncActiveASRModel()
        persist()
    }

    func updateStrictMode(_ enabled: Bool) {
        if config.strict.strictMode == enabled {
            return
        }
        config.strict.strictMode = enabled
        persist()
    }

    func updateSelectedVendor(_ vendor: ProviderVendor) {
        if config.analysis.selectedVendor == vendor {
            return
        }
        config.analysis.selectedVendor = vendor
        persist()
    }

    func updateProfile(vendor: ProviderVendor, baseURL: String, modelID: String) {
        guard let idx = config.analysis.providers.firstIndex(where: { $0.vendor == vendor }) else {
            return
        }
        let normalizedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if config.analysis.providers[idx].baseURL == normalizedBaseURL,
           config.analysis.providers[idx].modelID == normalizedModelID
        {
            return
        }
        config.analysis.providers[idx].baseURL = normalizedBaseURL
        config.analysis.providers[idx].modelID = normalizedModelID
        persist()
    }

    func profile(for vendor: ProviderVendor) -> ProviderProfile {
        if let profile = config.analysis.providers.first(where: { $0.vendor == vendor }) {
            return profile
        }
        return Self.defaultConfig().analysis.providers.first(where: { $0.vendor == vendor })!
    }

    func setAPIKey(_ key: String, for vendor: ProviderVendor) throws {
        let account = apiKeyAccount(for: vendor)
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = ((try? keychain.readSecret(account: account)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized == existing {
            return
        }
        if normalized.isEmpty {
            try keychain.deleteSecret(account: account)
            bumpRevision()
            return
        }
        try keychain.save(secret: normalized, account: account)
        bumpRevision()
    }

    func hasAPIKey(for vendor: ProviderVendor) -> Bool {
        if Self.isUITestMode { return false }
        return ((try? keychain.readSecret(account: apiKeyAccount(for: vendor))) ?? "").isEmpty == false
    }

    func apiKeyValue(for vendor: ProviderVendor) -> String {
        if Self.isUITestMode { return "" }
        return (try? keychain.readSecret(account: apiKeyAccount(for: vendor))) ?? ""
    }

    func sidecarEnvironment() -> [String: String] {
        Self.buildSidecarEnvironment(
            config: config,
            processEnvironment: ProcessInfo.processInfo.environment
        ) { [keychain] vendor, allowUserInteraction in
            let account = "vendor.\(vendor.rawValue).api_key"
            let policy: KeychainService.InteractionPolicy = allowUserInteraction ? .allowUI : .failIfInteractionRequired
            return (try? keychain.readSecret(account: account, interactionPolicy: policy)) ?? ""
        }
    }

    static func buildSidecarEnvironment(
        config: RuntimeConfigV2,
        processEnvironment: [String: String],
        apiKeyLookup: (_ vendor: ProviderVendor, _ allowUserInteraction: Bool) -> String
    ) -> [String: String] {
        var env: [String: String] = [:]

        let profilesByVendor = Dictionary(uniqueKeysWithValues: config.analysis.providers.map { ($0.vendor, $0) })
        let activeVendor = config.analysis.selectedVendor
        let activeProfile = profilesByVendor[activeVendor] ?? Self.defaultConfig().analysis.providers.first(where: { $0.vendor == activeVendor })!
        env["INSIGHTKIT_PROVIDER_VENDOR"] = activeVendor.rawValue
        env["INSIGHTKIT_PROVIDER_MODEL"] = activeProfile.modelID
        env["INSIGHTKIT_STRICT_MODE"] = config.strict.strictMode ? "1" : "0"

        env["INSIGHTKIT_ASR_ENGINE"] = config.asr.engine.rawValue
        env["INSIGHTKIT_ASR_MODEL"] = Self.currentASRModel(from: config)
        env["INSIGHTKIT_MODEL_DIR"] = config.asr.modelDir
        env["INSIGHTKIT_VAD_ENABLED"] = config.asr.vadEnabled ? "1" : "0"
        env["INSIGHTKIT_DIARIZATION_ENABLED"] = config.asr.diarizationEnabled ? "1" : "0"
        env["INSIGHTKIT_DIARIZATION_ENGINE"] = processEnvironment["INSIGHTKIT_DIARIZATION_ENGINE"] ?? "fluid-lseend"
        env["INSIGHTKIT_ASR_STRICT_LOCAL_ONLY"] = "1"
        env["INSIGHTKIT_FUNASR_ASR_MODEL"] = config.asr.funasrProfile.model
        env["INSIGHTKIT_WHISPER_MODEL"] = config.asr.whisperProfile.model
        env["INSIGHTKIT_QWEN_MLX_MODEL"] = config.asr.qwenProfile.model
        env["INSIGHTKIT_QWEN_ASR_MODEL"] = config.asr.qwenProfile.model
        env["INSIGHTKIT_QWEN_FORCED_ALIGNER_MODEL"] = "Qwen3-ForcedAligner-0.6B"
        env["INSIGHTKIT_QWEN_RETURN_TIMESTAMPS"] = "1"
        env["INSIGHTKIT_APPLE_SPEECH_PROTOTYPE_ENABLED"] = config.asr.appleSpeechPrototypeEnabled ? "1" : "0"
        if let cli = processEnvironment["INSIGHTKIT_FLUIDAUDIO_CLI"], !cli.isEmpty {
            env["INSIGHTKIT_FLUIDAUDIO_CLI"] = cli
        }

        func providerAPIKey(_ vendor: ProviderVendor, envName: String) -> String {
            let stored = apiKeyLookup(vendor, false).trimmingCharacters(in: .whitespacesAndNewlines)
            if !stored.isEmpty {
                return stored
            }
            return processEnvironment[envName]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        for profile in config.analysis.providers {
            switch profile.vendor {
            case .openai:
                env["OPENAI_BASE_URL"] = profile.baseURL
                env["OPENAI_MODEL"] = profile.modelID
                if activeVendor == .openai {
                    env["OPENAI_API_KEY"] = providerAPIKey(.openai, envName: "OPENAI_API_KEY")
                }
            case .gemini:
                env["GEMINI_BASE_URL"] = profile.baseURL
                env["GEMINI_MODEL"] = profile.modelID
                if activeVendor == .gemini {
                    env["GEMINI_API_KEY"] = providerAPIKey(.gemini, envName: "GEMINI_API_KEY")
                }
            case .deepseek:
                env["DEEPSEEK_BASE_URL"] = profile.baseURL
                env["DEEPSEEK_MODEL"] = profile.modelID
                if activeVendor == .deepseek {
                    env["DEEPSEEK_API_KEY"] = providerAPIKey(.deepseek, envName: "DEEPSEEK_API_KEY")
                }
            case .qwen:
                env["QWEN_BASE_URL"] = profile.baseURL
                env["QWEN_MODEL"] = profile.modelID
                if activeVendor == .qwen {
                    env["QWEN_API_KEY"] = providerAPIKey(.qwen, envName: "QWEN_API_KEY")
                }
            case .doubao:
                env["DOUBAO_BASE_URL"] = profile.baseURL
                env["DOUBAO_MODEL"] = profile.modelID
                if activeVendor == .doubao {
                    env["DOUBAO_API_KEY"] = providerAPIKey(.doubao, envName: "DOUBAO_API_KEY")
                }
            }
        }

        if let token = processEnvironment["HF_TOKEN"], !token.isEmpty {
            env["HF_TOKEN"] = token
        }
        if let token = processEnvironment["PYANNOTE_AUTH_TOKEN"], !token.isEmpty {
            env["PYANNOTE_AUTH_TOKEN"] = token
        }
        return env
    }

    func activeProviderParams() -> [String: Any] {
        let vendor = config.analysis.selectedVendor
        let profile = profile(for: vendor)
        return [
            "provider_vendor": vendor.rawValue,
            "provider_model": profile.modelID,
            "strict_mode": config.strict.strictMode,
        ]
    }

    func currentASRModel() -> String {
        Self.currentASRModel(from: config)
    }

    private static func currentASRModel(from config: RuntimeConfigV2) -> String {
        switch config.asr.engine {
        case .whisper:
            return config.asr.whisperProfile.model
        case .funasr:
            return config.asr.funasrProfile.model
        case .qwenmlx:
            return config.asr.qwenProfile.model
        }
    }

    // MARK: - Engine-aware presets

    static let whisperPresets: [String] = [
        "large-v3-turbo",
        "large-v3",
        "large-v2",
        "large-v1",
        "medium",
        "small",
        "base",
        "tiny",
    ]

    static let funasrPresets: [String] = [
        "iic/SenseVoiceSmall",
        "FunAudioLLM/Fun-ASR-Nano-2512",
        "iic/speech_paraformer-large-vad-punc_asr_nat-zh-cn-16k-common-vocab8404-pytorch",
        "iic/speech_seaco_paraformer_large_asr_nat-zh-cn-16k-common-vocab8404-pytorch",
        "iic/speech_paraformer-large-contextual_asr_nat-zh-cn-16k-common-vocab8404",
    ]

    static let qwenPresets: [String] = [
        "Qwen3-ASR-1.7B-MLX-4bit",
        "Qwen3-ASR-1.7B",
        "Qwen/Qwen3-ASR-1.7B",
        "aufklarer/Qwen3-ASR-1.7B-MLX-4bit",
    ]

    private static let deepSeekDefaultBaseURL = "https://api.deepseek.com"
    private static let deepSeekLegacyBaseURL = "https://api.deepseek.com/v1"
    private static let deepSeekDefaultModel = "deepseek-v4-flash"
    private static let deepSeekLegacyModels: Set<String> = ["deepseek-chat", "deepseek-reasoner"]

    func defaultModelName(for engine: LocalASREngine) -> String {
        switch engine {
        case .whisper:
            return config.asr.whisperProfile.model.isEmpty ? "large-v3" : config.asr.whisperProfile.model
        case .funasr:
            return config.asr.funasrProfile.model.isEmpty
                ? "iic/speech_paraformer-large-vad-punc_asr_nat-zh-cn-16k-common-vocab8404-pytorch"
                : config.asr.funasrProfile.model
        case .qwenmlx:
            return config.asr.qwenProfile.model.isEmpty
                ? "Qwen3-ASR-1.7B-MLX-4bit"
                : config.asr.qwenProfile.model
        }
    }

    func defaultModelDir(for engine: LocalASREngine) -> String {
        // Models for each engine are stored in the same base directory.
        // For Whisper, faster-whisper downloads to modelDir directly.
        // For FunASR, the Python runtime resolves the HuggingFace cache,
        // so we keep the same base dir and let the sidecar handle sub-paths.
        return config.asr.modelDir
    }

    // MARK: - Vendor-aware presets

    static let vendorModelPresets: [ProviderVendor: [String]] = [
        .openai: [
            "gpt-5.2",
            "gpt-5.2-pro",
            "gpt-5-mini",
            "gpt-5-nano",
            "gpt-5",
            "gpt-4.1",
            "gpt-4.1-mini",
            "gpt-4.1-nano",
            "gpt-4o",
            "gpt-4o-mini",
        ],
        .gemini: [
            "gemini-2.5-pro",
            "gemini-2.5-flash",
            "gemini-2.5-flash-lite",
            "gemini-2.5-flash-preview-09-2025",
            "gemini-2.5-flash-lite-preview-09-2025",
            "gemini-flash-latest",
        ],
        .deepseek: [
            "deepseek-v4-flash",
            "deepseek-v4-pro",
            "deepseek-chat",
            "deepseek-reasoner",
        ],
        .qwen: [
            "qwen-max-latest",
            "qwen-max",
            "qwen-plus-latest",
            "qwen-plus",
            "qwen-flash",
            "qwen-turbo-latest",
            "qwen-turbo",
            "qwen-long-latest",
            "qwen-long",
            "qwen3-max",
            "qwen3-max-preview",
        ],
        .doubao: [
            "doubao-seed-1-8-251228",
            "doubao-seed-1-6-251015",
            "doubao-seed-1-6-250615",
            "doubao-seed-1-6-flash-250828",
            "doubao-seed-1-6-flash-250715",
            "doubao-seed-1-6-lite-251015",
            "doubao-seed-1-6-thinking-250715",
            "doubao-seed-1-6-vision-250815",
            "doubao-1-5-pro-32k-250115",
            "doubao-1-5-lite-32k-250115",
        ],
    ]

    static let vendorDefaultBaseURL: [ProviderVendor: String] = [
        .openai: "https://api.openai.com/v1",
        .gemini: "https://generativelanguage.googleapis.com",
        .deepseek: deepSeekDefaultBaseURL,
        .qwen: "https://dashscope.aliyuncs.com/compatible-mode/v1",
        .doubao: "https://ark.cn-beijing.volces.com/api/v3",
    ]

    static func modelPresets(for vendor: ProviderVendor) -> [String] {
        vendorModelPresets[vendor] ?? []
    }

    static func defaultBaseURL(for vendor: ProviderVendor) -> String {
        vendorDefaultBaseURL[vendor] ?? ""
    }

    private func apiKeyAccount(for vendor: ProviderVendor) -> String {
        "vendor.\(vendor.rawValue).api_key"
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(config) {
            defaults.set(data, forKey: defaultsKeyV2)
            defaults.set(data, forKey: defaultsKey)
        }
        bumpRevision()
        writeConfigSnapshot()
        objectWillChange.send()
    }

    private func bumpRevision() {
        configRevision &+= 1
    }

    private func writeConfigSnapshot() {
        do {
            try FileManager.default.createDirectory(at: configSnapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(config)
            try data.write(to: configSnapshotURL)
        } catch {
            // 配置快照写入失败不阻断主流程。
        }
    }

    private static func configSnapshotPath() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/InsightKit/runtime_config_v1.json")
    }

    private func syncActiveASRModel() {
        config.asr.model = currentASRModel()
    }

    private func normalizeCorruptedAnalysisProfilesIfNeeded() -> Bool {
        let repaired = Self.repairCorruptedAnalysisProfiles(in: config)
        config = repaired.config
        return repaired.changed
    }

    static func repairCorruptedAnalysisProfiles(in input: RuntimeConfigV2) -> (config: RuntimeConfigV2, changed: Bool) {
        var config = input
        let defaultsByVendor = Dictionary(uniqueKeysWithValues: Self.defaultConfig().analysis.providers.map { ($0.vendor, $0) })
        var changed = false

        let originalProviders = config.analysis.providers
        let originalVendors = config.analysis.providers.map(\.vendor)
        let duplicateVendors = Set(
            originalVendors.filter { vendor in
                originalVendors.filter { $0 == vendor }.count > 1
            }
        )
        if !duplicateVendors.isEmpty {
            changed = true
        }

        var providers: [ProviderProfile] = []
        for vendor in ProviderVendor.allCases {
            guard let defaults = defaultsByVendor[vendor] else { continue }
            var profile = config.analysis.providers.first(where: { $0.vendor == vendor }) ?? defaults
            if config.analysis.providers.first(where: { $0.vendor == vendor }) == nil {
                changed = true
            }

            if profile.apiKeyRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                profile.apiKeyRef = defaults.apiKeyRef
                changed = true
            }

            let baseURL = profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let modelID = profile.modelID.trimmingCharacters(in: .whitespacesAndNewlines)

            if baseURL.isEmpty {
                profile.baseURL = defaults.baseURL
                changed = true
            }
            if modelID.isEmpty {
                profile.modelID = defaults.modelID
                changed = true
            }

            let normalizedBaseURL = profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedModelID = profile.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            for (defaultVendor, defaultProfile) in defaultsByVendor where defaultVendor != vendor {
                if normalizedBaseURL == defaultProfile.baseURL,
                   normalizedModelID == defaultProfile.modelID
                {
                    profile.baseURL = defaults.baseURL
                    profile.modelID = defaults.modelID
                    changed = true
                    break
                }
            }

            if vendor == .deepseek {
                let deepSeekBaseURL = profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                let deepSeekModelID = profile.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
                if deepSeekBaseURL == Self.deepSeekLegacyBaseURL {
                    profile.baseURL = Self.deepSeekDefaultBaseURL
                    changed = true
                }
                if Self.deepSeekLegacyModels.contains(deepSeekModelID) {
                    profile.modelID = Self.deepSeekDefaultModel
                    changed = true
                }
            }

            providers.append(profile)
        }

        if providers != originalProviders {
            changed = true
        }
        config.analysis.providers = providers

        guard let activeProfile = config.analysis.providers.first(where: { $0.vendor == config.analysis.selectedVendor }) else {
            return (config, changed)
        }

        let sameAsActive = config.analysis.providers.filter {
            $0.vendor != config.analysis.selectedVendor
                && $0.baseURL == activeProfile.baseURL
                && $0.modelID == activeProfile.modelID
        }
        // Heuristic: if 2+ non-active vendors are overwritten with exactly the active vendor endpoint/model,
        // this is highly likely a cross-write bug side effect.
        if sameAsActive.count >= 2 {
            for idx in config.analysis.providers.indices {
                let vendor = config.analysis.providers[idx].vendor
                if vendor == config.analysis.selectedVendor { continue }
                guard let defaultProfile = defaultsByVendor[vendor] else { continue }
                let profile = config.analysis.providers[idx]
                if profile.baseURL == activeProfile.baseURL && profile.modelID == activeProfile.modelID {
                    config.analysis.providers[idx].baseURL = defaultProfile.baseURL
                    config.analysis.providers[idx].modelID = defaultProfile.modelID
                    changed = true
                }
            }
        }

        return (config, changed)
    }

    private static func defaultConfig() -> RuntimeConfigV2 {
        let modelDir = isUITestMode
            ? "/tmp/InsightKit/models"
            : FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/InsightKit/models")
                .path

        let providers: [ProviderProfile] = [
            ProviderProfile(
                vendor: .openai,
                baseURL: "https://api.openai.com/v1",
                modelID: "gpt-4.1-mini",
                apiKeyRef: "vendor.openai.api_key",
                extraHeaders: [:]
            ),
            ProviderProfile(
                vendor: .gemini,
                baseURL: "https://generativelanguage.googleapis.com",
                modelID: "gemini-2.5-flash",
                apiKeyRef: "vendor.gemini.api_key",
                extraHeaders: [:]
            ),
            ProviderProfile(
                vendor: .deepseek,
                baseURL: deepSeekDefaultBaseURL,
                modelID: deepSeekDefaultModel,
                apiKeyRef: "vendor.deepseek.api_key",
                extraHeaders: [:]
            ),
            ProviderProfile(
                vendor: .qwen,
                baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
                modelID: "qwen-plus-latest",
                apiKeyRef: "vendor.qwen.api_key",
                extraHeaders: [:]
            ),
            ProviderProfile(
                vendor: .doubao,
                baseURL: "https://ark.cn-beijing.volces.com/api/v3",
                modelID: "doubao-seed-1-6-250615",
                apiKeyRef: "vendor.doubao.api_key",
                extraHeaders: [:]
            ),
        ]

        return RuntimeConfigV2(
            asr: RuntimeConfigV2.ASR(
                engine: .whisper,
                model: "large-v3",
                modelDir: modelDir,
                vadEnabled: true,
                diarizationEnabled: true,
                whisperProfile: .init(model: "large-v3"),
                funasrProfile: .init(model: "iic/speech_paraformer-large-vad-punc_asr_nat-zh-cn-16k-common-vocab8404-pytorch"),
                qwenProfile: .init(model: "Qwen3-ASR-1.7B-MLX-4bit"),
                appleSpeechPrototypeEnabled: false
            ),
            analysis: RuntimeConfigV2.Analysis(
                selectedVendor: .deepseek,
                providers: providers
            ),
            strict: RuntimeConfigV2.Strict(strictMode: true),
            download: RuntimeConfigV2.Download(autoBootstrapEnabled: true)
        )
    }

    private static var isUITestMode: Bool {
        ProcessInfo.processInfo.environment["INSIGHTKIT_UI_TEST_MODE"] == "1"
    }
}
