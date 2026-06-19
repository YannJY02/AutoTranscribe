import Foundation

enum PythonRuntimeEnvironment {
    static func prepared(from base: [String: String], runtimeRoot: String? = nil) -> [String: String] {
        var env = base
        env["PYTHONDONTWRITEBYTECODE"] = "1"

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
}
