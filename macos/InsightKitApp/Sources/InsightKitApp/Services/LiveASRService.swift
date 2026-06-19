import Foundation
import Darwin

final class LiveASRService {
    enum ASRError: LocalizedError {
        case scriptMissing(String)
        case processFailed(String)
        case processTimeout(Int)
        case invalidJSON

        var errorDescription: String? {
            switch self {
            case .scriptMissing(let path):
                return "未找到 live ASR 脚本: \(path)"
            case .processFailed(let message):
                return "实时转写失败: \(message)"
            case .processTimeout(let sec):
                return "实时转写超时(>\(sec)s)。"
            case .invalidJSON:
                return "实时转写输出解析失败。"
            }
        }
    }

    private let pythonBinary: String
    private let scriptPath: String
    private let timeoutSec: Int
    private let maxRetries: Int

    init(
        pythonBinary: String = ProcessInfo.processInfo.environment["INSIGHTKIT_PYTHON"] ?? "python3",
        scriptPath: String = LiveASRService.defaultScriptPath(),
        timeoutSec: Int = Int(ProcessInfo.processInfo.environment["INSIGHTKIT_ASR_TIMEOUT_SEC"] ?? "25") ?? 25,
        maxRetries: Int = Int(ProcessInfo.processInfo.environment["INSIGHTKIT_ASR_MAX_RETRIES"] ?? "1") ?? 1
    ) {
        self.pythonBinary = pythonBinary
        self.scriptPath = scriptPath
        self.timeoutSec = max(5, timeoutSec)
        self.maxRetries = max(0, maxRetries)
    }

    func transcribe(chunk: AudioChunk, source: String) throws -> [RPCSegmentDelta] {
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            throw ASRError.scriptMissing(scriptPath)
        }

        var lastError: Error?
        for attempt in 0...(maxRetries) {
            do {
                return try run(
                    wavPath: chunk.url.path,
                    offsetMs: chunk.startMs,
                    source: source
                )
            } catch {
                lastError = error
                if attempt >= maxRetries {
                    break
                }
            }
        }

        throw lastError ?? ASRError.processFailed("unknown error")
    }

    private func run(wavPath: String, offsetMs: Int, source: String) throws -> [RPCSegmentDelta] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")

        let args = [pythonBinary, scriptPath, "--wav", wavPath, "--offset-ms", "\(offsetMs)"]
        process.arguments = args
        process.environment = PythonRuntimeEnvironment.prepared(from: ProcessInfo.processInfo.environment)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        try waitUntilExit(process)

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let message = stderr.isEmpty ? "exit=\(process.terminationStatus)" : stderr
            throw ASRError.processFailed(message)
        }

        guard let data = stdout.data(using: .utf8), !data.isEmpty else {
            throw ASRError.invalidJSON
        }

        let object = try JSONSerialization.jsonObject(with: data)
        guard let payload = object as? [String: Any] else {
            throw ASRError.invalidJSON
        }

        if let err = payload["error"] as? String, !err.isEmpty {
            throw ASRError.processFailed(err)
        }

        guard let rawSegments = payload["segments"] as? [[String: Any]] else {
            return []
        }

        return rawSegments.compactMap { seg in
            guard
                let text = seg["text"] as? String,
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return nil
            }

            let startMs = (seg["start_ms"] as? Int) ?? 0
            let endMs = (seg["end_ms"] as? Int) ?? (startMs + 1000)
            let speaker = (seg["speaker"] as? String) ?? ""
            let confidence = (seg["confidence"] as? Double) ?? 0.0

            return RPCSegmentDelta(
                startMs: startMs,
                endMs: endMs,
                speaker: speaker,
                text: text,
                confidence: confidence,
                source: source
            )
        }
    }

    private func waitUntilExit(_ process: Process) throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSec))
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                Thread.sleep(forTimeInterval: 0.25)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                throw ASRError.processTimeout(timeoutSec)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private static func defaultScriptPath() -> String {
        if let env = ProcessInfo.processInfo.environment["INSIGHTKIT_ASR_SCRIPT"], !env.isEmpty {
            return env
        }

        if let runtimeRoot = ProcessInfo.processInfo.environment["INSIGHTKIT_RUNTIME_ROOT"], !runtimeRoot.isEmpty {
            let p = URL(fileURLWithPath: runtimeRoot)
                .appendingPathComponent("scripts/live_chunk_asr.py")
                .path
            if FileManager.default.fileExists(atPath: p) {
                return p
            }
        }

        if let bundled = bundledScriptPath() {
            return bundled
        }

        let cwdPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts/live_chunk_asr.py")
            .path
        if FileManager.default.fileExists(atPath: cwdPath) {
            return cwdPath
        }

        // Final fallback: resolve relative to executable location.
        let exeDir = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .deletingLastPathComponent()
        return exeDir
            .appendingPathComponent("../../../../scripts/live_chunk_asr.py")
            .standardized.path
    }

    private static func bundledScriptPath() -> String? {
        guard let resourceURL = Bundle.main.resourceURL else {
            return nil
        }

        let candidates = [
            resourceURL.appendingPathComponent("insightkit_runtime/scripts/live_chunk_asr.py").path,
            resourceURL.appendingPathComponent("scripts/live_chunk_asr.py").path,
        ]

        for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
        return nil
    }
}
