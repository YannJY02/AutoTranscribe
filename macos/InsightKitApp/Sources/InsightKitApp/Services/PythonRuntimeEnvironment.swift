import Foundation

enum PythonRuntimeEnvironment {
    static func prepared(
        from base: [String: String],
        runtimeRoot: String? = nil,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> [String: String] {
        var env = base
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["PATH"] = mergedExecutablePath(existing: env["PATH"])

        if let runtimeRoot, !runtimeRoot.isEmpty {
            env["INSIGHTKIT_RUNTIME_ROOT"] = runtimeRoot
            let existingPythonPath = env["PYTHONPATH", default: ""]
            let mergedPythonPath = [runtimeRoot, existingPythonPath]
                .filter { !$0.isEmpty }
                .joined(separator: ":")
            env["PYTHONPATH"] = mergedPythonPath
        }
        return isolatedForUITesting(from: env, arguments: arguments)
    }

    static func isolatedForUITesting(
        from environment: [String: String],
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> [String: String] {
        guard let context = UITestStorageContext.resolve(environment: environment, arguments: arguments)
        else { return environment }

        // Every Python entry point shares this boundary. Call it again after any
        // config overlay so operator credentials cannot re-enter a test child.
        var isolated = environment.filter { uiTestChildEnvironmentKeys.contains($0.key) }
        isolated["INSIGHTKIT_UI_TEST_MODE"] = "1"
        isolated[UITestStorageContext.sessionIDEnvironmentKey] = context.sessionID.uuidString
        isolated["INSIGHTKIT_SOCKET"] = context.socketPath
        isolated["INSIGHTKIT_RECORDS_ROOT"] = context.recordsDirectory.path
        isolated["INSIGHTKIT_UI_TEST_CAPTURE_ROOT"] = context.captureDirectory.path
        isolated["INSIGHTKIT_DB_PATH"] = context.rootDirectory.appendingPathComponent("data/insightkit.db").path
        let huggingFaceHome = context.rootDirectory.appendingPathComponent("cache/huggingface", isDirectory: true)
        isolated["HF_HOME"] = huggingFaceHome.path
        isolated["HF_TOKEN_PATH"] = huggingFaceHome.appendingPathComponent("token").path
        return isolated
    }

    private static let uiTestChildEnvironmentKeys: Set<String> = [
        "PATH", "PYTHONPATH", "PYTHONDONTWRITEBYTECODE", "PYTHONIOENCODING", "PYTHONUNBUFFERED",
        "LANG", "LC_ALL", "LC_CTYPE", "TZ", "TMPDIR", "TMP", "TEMP",
        "INSIGHTKIT_RUNTIME_ROOT", "INSIGHTKIT_PYTHON_RESOLVED", "INSIGHTKIT_BUILD", "INSIGHTKIT_VERSION",
        "INSIGHTKIT_PROVIDER_VENDOR", "INSIGHTKIT_ANALYSIS_MODE", "INSIGHTKIT_PROVIDER_MODEL", "INSIGHTKIT_STRICT_MODE",
        "INSIGHTKIT_ASR_ENGINE", "INSIGHTKIT_ASR_MODEL", "INSIGHTKIT_MODEL_DIR", "INSIGHTKIT_VAD_ENABLED",
        "INSIGHTKIT_DIARIZATION_ENABLED", "INSIGHTKIT_DIARIZATION_ENGINE", "INSIGHTKIT_ASR_STRICT_LOCAL_ONLY",
        "INSIGHTKIT_FUNASR_ASR_MODEL", "INSIGHTKIT_WHISPER_MODEL", "INSIGHTKIT_QWEN_MLX_MODEL", "INSIGHTKIT_QWEN_ASR_MODEL",
        "INSIGHTKIT_QWEN_FORCED_ALIGNER_MODEL", "INSIGHTKIT_QWEN_RETURN_TIMESTAMPS", "INSIGHTKIT_APPLE_SPEECH_PROTOTYPE_ENABLED",
        "INSIGHTKIT_FLUIDAUDIO_CLI", "OPENAI_BASE_URL", "OPENAI_MODEL", "GEMINI_BASE_URL", "GEMINI_MODEL",
        "DEEPSEEK_BASE_URL", "DEEPSEEK_MODEL", "QWEN_BASE_URL", "QWEN_MODEL", "DOUBAO_BASE_URL", "DOUBAO_MODEL",
    ]

    private static func mergedExecutablePath(existing: String?) -> String {
        let fallbackPaths = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        let candidates = (existing ?? "")
            .split(separator: ":")
            .map(String.init) + fallbackPaths
        var seen = Set<String>()
        return candidates
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
            .joined(separator: ":")
    }
}
