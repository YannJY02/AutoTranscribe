import Foundation

final class AppConfigStore: ObservableObject {
    static let shared = AppConfigStore()

    @Published private(set) var config: RuntimeConfigV2
    @Published private(set) var configRevision: Int = 0

    private let defaultsKey = "insightkit.runtime.config.v1"
    private let defaultsKeyV2 = "insightkit.runtime.config.v2"
    private let defaults = UserDefaults.standard
    private let keychain = KeychainService()

    private init() {
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
        ((try? keychain.readSecret(account: apiKeyAccount(for: vendor))) ?? "").isEmpty == false
    }

    func apiKeyValue(for vendor: ProviderVendor) -> String {
        (try? keychain.readSecret(account: apiKeyAccount(for: vendor))) ?? ""
    }

    func sidecarEnvironment() -> [String: String] {
        var env: [String: String] = [:]

        let activeVendor = config.analysis.selectedVendor
        let activeProfile = profile(for: activeVendor)
        env["INSIGHTKIT_PROVIDER_VENDOR"] = activeVendor.rawValue
        env["INSIGHTKIT_PROVIDER_MODEL"] = activeProfile.modelID
        env["INSIGHTKIT_STRICT_MODE"] = config.strict.strictMode ? "1" : "0"

        env["INSIGHTKIT_ASR_ENGINE"] = config.asr.engine.rawValue
        env["INSIGHTKIT_ASR_MODEL"] = currentASRModel()
        env["INSIGHTKIT_MODEL_DIR"] = config.asr.modelDir
        env["INSIGHTKIT_VAD_ENABLED"] = config.asr.vadEnabled ? "1" : "0"
        env["INSIGHTKIT_DIARIZATION_ENABLED"] = config.asr.diarizationEnabled ? "1" : "0"
        env["INSIGHTKIT_ASR_STRICT_LOCAL_ONLY"] = "1"
        env["INSIGHTKIT_FUNASR_ASR_MODEL"] = config.asr.funasrProfile.model
        env["INSIGHTKIT_WHISPER_MODEL"] = config.asr.whisperProfile.model

        for profile in config.analysis.providers {
            switch profile.vendor {
            case .openai:
                env["OPENAI_BASE_URL"] = profile.baseURL
                env["OPENAI_MODEL"] = profile.modelID
                env["OPENAI_API_KEY"] = ((try? keychain.readSecret(account: apiKeyAccount(for: .openai))) ?? "")
            case .gemini:
                env["GEMINI_BASE_URL"] = profile.baseURL
                env["GEMINI_MODEL"] = profile.modelID
                env["GEMINI_API_KEY"] = ((try? keychain.readSecret(account: apiKeyAccount(for: .gemini))) ?? "")
            case .deepseek:
                env["DEEPSEEK_BASE_URL"] = profile.baseURL
                env["DEEPSEEK_MODEL"] = profile.modelID
                env["DEEPSEEK_API_KEY"] = ((try? keychain.readSecret(account: apiKeyAccount(for: .deepseek))) ?? "")
            case .qwen:
                env["QWEN_BASE_URL"] = profile.baseURL
                env["QWEN_MODEL"] = profile.modelID
                env["QWEN_API_KEY"] = ((try? keychain.readSecret(account: apiKeyAccount(for: .qwen))) ?? "")
            case .doubao:
                env["DOUBAO_BASE_URL"] = profile.baseURL
                env["DOUBAO_MODEL"] = profile.modelID
                env["DOUBAO_API_KEY"] = ((try? keychain.readSecret(account: apiKeyAccount(for: .doubao))) ?? "")
            }
        }

        if let token = ProcessInfo.processInfo.environment["HF_TOKEN"], !token.isEmpty {
            env["HF_TOKEN"] = token
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
        switch config.asr.engine {
        case .whisper:
            return config.asr.whisperProfile.model
        case .funasr:
            return config.asr.funasrProfile.model
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
        "iic/speech_paraformer-large-vad-punc_asr_nat-zh-cn-16k-common-vocab8404-pytorch",
        "iic/speech_seaco_paraformer_large_asr_nat-zh-cn-16k-common-vocab8404-pytorch",
        "iic/speech_paraformer-large-contextual_asr_nat-zh-cn-16k-common-vocab8404",
    ]

    func defaultModelName(for engine: LocalASREngine) -> String {
        switch engine {
        case .whisper:
            return config.asr.whisperProfile.model.isEmpty ? "large-v3" : config.asr.whisperProfile.model
        case .funasr:
            return config.asr.funasrProfile.model.isEmpty
                ? "iic/speech_paraformer-large-vad-punc_asr_nat-zh-cn-16k-common-vocab8404-pytorch"
                : config.asr.funasrProfile.model
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
        .deepseek: ["deepseek-chat", "deepseek-reasoner"],
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
        .deepseek: "https://api.deepseek.com/v1",
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
        let path = Self.configSnapshotPath()
        do {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(config)
            try data.write(to: path)
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
        let activeVendor = config.analysis.selectedVendor
        guard let activeProfile = config.analysis.providers.first(where: { $0.vendor == activeVendor }) else {
            return false
        }

        let nonActive = config.analysis.providers.filter { $0.vendor != activeVendor }
        let sameAsActive = nonActive.filter {
            $0.baseURL == activeProfile.baseURL && $0.modelID == activeProfile.modelID
        }
        // Heuristic: if 2+ non-active vendors are overwritten with exactly the active vendor endpoint/model,
        // this is highly likely a cross-write bug side effect.
        let defaultsByVendor = Dictionary(uniqueKeysWithValues: Self.defaultConfig().analysis.providers.map { ($0.vendor, $0) })
        var changed = false

        if sameAsActive.count >= 2 {
            for idx in config.analysis.providers.indices {
                let vendor = config.analysis.providers[idx].vendor
                if vendor == activeVendor { continue }
                guard let defaultProfile = defaultsByVendor[vendor] else { continue }
                let profile = config.analysis.providers[idx]
                if profile.baseURL == activeProfile.baseURL && profile.modelID == activeProfile.modelID {
                    config.analysis.providers[idx].baseURL = defaultProfile.baseURL
                    config.analysis.providers[idx].modelID = defaultProfile.modelID
                    changed = true
                }
            }
        }

        // Repair empty endpoint/model fields that make provider probe always fail.
        for idx in config.analysis.providers.indices {
            let vendor = config.analysis.providers[idx].vendor
            guard let defaults = defaultsByVendor[vendor] else { continue }

            if config.analysis.providers[idx].baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                config.analysis.providers[idx].baseURL = defaults.baseURL
                changed = true
            }
            if config.analysis.providers[idx].modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                config.analysis.providers[idx].modelID = defaults.modelID
                changed = true
            }
        }
        return changed
    }

    private static func defaultConfig() -> RuntimeConfigV2 {
        let modelDir = FileManager.default.homeDirectoryForCurrentUser
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
                baseURL: "https://api.deepseek.com/v1",
                modelID: "deepseek-chat",
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
                funasrProfile: .init(model: "iic/speech_paraformer-large-vad-punc_asr_nat-zh-cn-16k-common-vocab8404-pytorch")
            ),
            analysis: RuntimeConfigV2.Analysis(
                selectedVendor: .deepseek,
                providers: providers
            ),
            strict: RuntimeConfigV2.Strict(strictMode: true),
            download: RuntimeConfigV2.Download(autoBootstrapEnabled: true)
        )
    }
}
