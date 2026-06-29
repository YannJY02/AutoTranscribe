import Foundation

enum PythonRuntimeEnvironment {
    static func prepared(from base: [String: String], runtimeRoot: String? = nil) -> [String: String] {
        var env = base
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["PATH"] = mergedExecutablePath(existing: env["PATH"])

        guard let runtimeRoot, !runtimeRoot.isEmpty else {
            return env
        }

        env["INSIGHTKIT_RUNTIME_ROOT"] = runtimeRoot
        let existingPythonPath = env["PYTHONPATH", default: ""]
        let mergedPythonPath = [runtimeRoot, existingPythonPath]
            .filter { !$0.isEmpty }
            .joined(separator: ":")
        env["PYTHONPATH"] = mergedPythonPath
        return env
    }

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
