import Foundation
import Darwin

struct SidecarStatus: Equatable {
    let running: Bool
    let socketPath: String
    let pid: Int32?
}

final class SidecarManager {
    enum SidecarError: LocalizedError {
        case scriptMissing(String)
        case failedToStart(String)
        case startupTimeout(String)

        var errorDescription: String? {
            switch self {
            case .scriptMissing(let path):
                return "未找到 sidecar 脚本: \(path)"
            case .failedToStart(let message):
                return "Insight sidecar 启动失败: \(message)"
            case .startupTimeout(let socket):
                return "Insight sidecar 启动超时，socket 未就绪: \(socket)"
            }
        }
    }

    private let pythonBinary: String
    private let socketPath: String
    private let startupTimeoutSec: Int
    private let sidecarLogPath: String
    private let sidecarLogHandle: FileHandle?
    private var process: Process?
    private let lifecycleLock = NSRecursiveLock()
    private let probeTimeoutSec: Int = 1
    private var didAttemptBuildRecovery = false

    // Python 候选列表的懒加载缓存——首次 startIfNeeded（在后台 Task 中执行）时才真正扫描，
    // 避免在主线程/init 中同步启动大量子进程导致 UI 卡顿。
    private var _cachedCandidates: [String]?
    private let _candidatesLock = NSLock()

    init(
        pythonBinary: String = SidecarManager.resolveConfiguredPythonBinary(),
        socketPath: String = InsightRuntimeDefaults.socketPath,
        startupTimeoutSec: Int = Int(ProcessInfo.processInfo.environment["INSIGHTKIT_SIDECAR_START_TIMEOUT"] ?? "8") ?? 8
    ) {
        self.pythonBinary = pythonBinary
        // NOTE: 不在 init 中扫描 Python 候选列表；改为首次 startIfNeeded 时懒加载。
        self.socketPath = socketPath
        self.startupTimeoutSec = max(3, startupTimeoutSec)
        self.sidecarLogPath = SidecarManager.resolveLogPath()
        self.sidecarLogHandle = SidecarManager.openLogHandle(at: self.sidecarLogPath)
    }

    deinit {
        stop()
    }

    func startIfNeeded(ensureReady: (() throws -> Void)? = nil) throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        if canConnectToSocket() {
            do {
                try waitForApplicationReady(ensureReady)
                if try rebootstrapIfBuildMismatch(ensureReady: ensureReady) {
                    return
                }
                return
            } catch {
                // A running old sidecar can keep the socket alive but miss newly introduced RPCs.
                // Only replace it after the sidecar proves that no work is active.
                if shouldResetForHandshakeError(error) {
                    _ = try requestRemoteShutdown(timeoutSec: 1, requireIdle: true)
                    resetSocketPath()
                } else {
                    throw error
                }
            }
            if try rebootstrapIfBuildMismatch(ensureReady: ensureReady) {
                return
            }
        }

        removeStaleSocketIfNeeded()

        if let process, process.isRunning {
            try waitForSocketReady()
            try waitForApplicationReady(ensureReady)
            if try rebootstrapIfBuildMismatch(ensureReady: ensureReady) {
                return
            }
            return
        }

        let sidecarScript = try resolveSidecarScriptPath()
        let runtimeRoot = runtimeRootPath(from: sidecarScript)
        var launchErrors: [String] = []
        let candidates = resolvedPythonCandidates()

        for candidate in candidates {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = [candidate, sidecarScript]
            p.standardInput = FileHandle.nullDevice

            var env = PythonRuntimeEnvironment.prepared(
                from: ProcessInfo.processInfo.environment,
                runtimeRoot: runtimeRoot
            )
            env["INSIGHTKIT_SOCKET"] = socketPath
            env["INSIGHTKIT_PYTHON_RESOLVED"] = candidate
            env["INSIGHTKIT_RECORDS_ROOT"] = RecordsIndexService.currentRootDirectory().path
            if let appBuild = appBuildVersion() {
                env["INSIGHTKIT_BUILD"] = appBuild
            }
            for (key, value) in AppConfigStore.shared.sidecarEnvironment() {
                env[key] = value
            }

            p.environment = env

            p.standardOutput = sidecarLogHandle ?? FileHandle.nullDevice
            p.standardError = sidecarLogHandle ?? FileHandle.nullDevice

            do {
                try p.run()
            } catch {
                launchErrors.append("[\(candidate)] run failed: \(error.localizedDescription)")
                continue
            }

            process = p

            do {
                try waitForSocketReady()
                try waitForApplicationReady(ensureReady)
                if try rebootstrapIfBuildMismatch(ensureReady: ensureReady) {
                    return
                }
                return
            } catch {
                stop()
                let tail = SidecarManager.tailLog(path: sidecarLogPath, maxBytes: 2000)
                if !tail.isEmpty {
                    launchErrors.append("[\(candidate)] \(error.localizedDescription)\n日志片段:\n\(tail)")
                } else {
                    launchErrors.append("[\(candidate)] \(error.localizedDescription) (日志: \(sidecarLogPath))")
                }
                removeStaleSocketIfNeeded()
            }
        }

        throw SidecarError.failedToStart(launchErrors.joined(separator: "\n---\n"))
    }

    static func shouldRebootstrapForBuildMismatch(sidecarBuild: String, appBuild: String) -> Bool {
        let lhs = sidecarBuild.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = appBuild.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lhs.isEmpty, !rhs.isEmpty else {
            return false
        }
        return lhs != rhs
    }

    static func bestEffortShutdownSocketOwner(
        socketPath: String = InsightRuntimeDefaults.socketPath,
        timeoutSec: Int = 1
    ) {
        let manager = SidecarManager(socketPath: socketPath, startupTimeoutSec: 3)
        _ = try? manager.requestRemoteShutdown(timeoutSec: max(1, timeoutSec))
        Thread.sleep(forTimeInterval: 0.1)
        manager.removeStaleSocketIfNeeded()
    }

    func rebootstrap(ensureReady: (() throws -> Void)? = nil, requireIdle: Bool = true) throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        // Force detach any stale socket owner and relaunch bundled/runtime sidecar.
        if requireIdle, canConnectToSocket() {
            _ = try requestRemoteShutdown(timeoutSec: 1, requireIdle: true)
        } else {
            _ = try? requestRemoteShutdown(timeoutSec: 1)
        }
        resetSocketPath()
        try startIfNeeded(ensureReady: ensureReady)
    }

    private func shouldResetForHandshakeError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("method not found: sidecar.ensure_ready")
            || message.contains("method not found: transcription.status")
    }

    private func rebootstrapIfBuildMismatch(ensureReady: (() throws -> Void)?) throws -> Bool {
        guard let appBuild = appBuildVersion() else {
            return false
        }
        let version: [String: Any]
        do {
            version = try callSocketMethod(method: "sidecar.version", params: [:], timeoutSec: 2)
        } catch {
            return false
        }
        let sidecarBuild = (version["build"] as? String) ?? ""
        guard Self.shouldRebootstrapForBuildMismatch(sidecarBuild: sidecarBuild, appBuild: appBuild) else {
            didAttemptBuildRecovery = false
            return false
        }
        if didAttemptBuildRecovery {
            return false
        }
        _ = try requestRemoteShutdown(timeoutSec: 1, requireIdle: true)
        didAttemptBuildRecovery = true
        resetSocketPath()
        try startIfNeeded(ensureReady: ensureReady)
        return true
    }

    private func appBuildVersion() -> String? {
        let fromBundle = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let trimmed = fromBundle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return trimmed
        }
        return nil
    }

    private func resetSocketPath() {
        if let process, process.isRunning {
            stop()
        }
        if socketFileExists() {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
    }

    func stop() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        guard let process else {
            return
        }

        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.3)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }

        self.process = nil
    }

    func status() -> SidecarStatus {
        let pid = process?.isRunning == true ? process?.processIdentifier : nil
        return SidecarStatus(running: canConnectToSocket(), socketPath: socketPath, pid: pid)
    }

    private func waitForSocketReady() throws {
        let deadline = Date().addingTimeInterval(TimeInterval(startupTimeoutSec))
        while Date() < deadline {
            if canConnectToSocket() {
                return
            }
            if let process, !process.isRunning {
                throw SidecarError.failedToStart("sidecar process exited before socket became ready")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw SidecarError.startupTimeout(socketPath)
    }

    private func waitForApplicationReady(_ ensureReady: (() throws -> Void)?) throws {
        guard let ensureReady else { return }
        let deadline = Date().addingTimeInterval(TimeInterval(startupTimeoutSec))
        var lastError: Error?
        while Date() < deadline {
            do {
                try ensureReady()
                return
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        if let lastError {
            throw SidecarError.failedToStart("sidecar handshake failed: \(lastError.localizedDescription)")
        }
        throw SidecarError.startupTimeout(socketPath)
    }

    private func socketFileExists() -> Bool {
        var st = stat()
        let exists = socketPath.withCString { cstr in
            lstat(cstr, &st) == 0
        }
        guard exists else {
            return false
        }
        return (st.st_mode & S_IFMT) == S_IFSOCK
    }

    private func canConnectToSocket() -> Bool {
        guard socketFileExists() else {
            return false
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return false
        }
        defer { _ = close(fd) }

        var tv = timeval(tv_sec: probeTimeoutSec, tv_usec: 0)
        withUnsafePointer(to: &tv) { ptr in
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = socketPath.utf8CString
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        if pathBytes.count > capacity {
            return false
        }

        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            buffer.initializeMemory(as: CChar.self, repeating: 0)
            _ = pathBytes.withUnsafeBytes { src in
                memcpy(buffer.baseAddress, src.baseAddress, min(buffer.count, src.count))
            }
        }

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddr in
                Darwin.connect(fd, sockAddr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return connectResult == 0
    }

    private func requestRemoteShutdown(timeoutSec: Int, requireIdle: Bool = false) throws -> [String: Any] {
        if requireIdle {
            let version = try callSocketMethod(method: "sidecar.version", params: [:], timeoutSec: timeoutSec)
            guard Self.acceptsGuardedShutdownResponse(version) else {
                throw SidecarError.failedToStart("sidecar does not support guarded restart")
            }
        }
        let response = try callSocketMethod(
            method: "sidecar.shutdown",
            params: requireIdle ? ["require_idle": true] : [:],
            timeoutSec: timeoutSec
        )
        if requireIdle, !Self.acceptsGuardedShutdownResponse(response) {
            throw SidecarError.failedToStart("sidecar does not support guarded restart")
        }
        return response
    }

    static func acceptsGuardedShutdownResponse(_ response: [String: Any]) -> Bool {
        (response["idle_shutdown_guard"] as? String) == "accepted-v1"
            || (response["idle_guard"] as? String) == "accepted-v1"
    }

    private func callSocketMethod(method: String, params: [String: Any], timeoutSec: Int) throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SidecarError.failedToStart("socket create failed")
        }
        defer { _ = close(fd) }

        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var tv = timeval(tv_sec: timeoutSec, tv_usec: 0)
        withUnsafePointer(to: &tv) { ptr in
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        if pathBytes.count > capacity {
            throw SidecarError.failedToStart("socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            buffer.initializeMemory(as: CChar.self, repeating: 0)
            _ = pathBytes.withUnsafeBytes { src in
                memcpy(buffer.baseAddress, src.baseAddress, min(buffer.count, src.count))
            }
        }
        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddr in
                Darwin.connect(fd, sockAddr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw SidecarError.failedToStart("sidecar socket connect failed")
        }

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": Int.random(in: 1...Int(Int32.max)),
            "method": method,
            "params": params,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let sent = data.withUnsafeBytes { bytes in
            Darwin.write(fd, bytes.baseAddress, bytes.count)
        }
        guard sent > 0 else {
            throw SidecarError.failedToStart("sidecar socket write failed")
        }
        _ = Darwin.shutdown(fd, SHUT_WR)

        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let readN = Darwin.read(fd, &buffer, buffer.count)
            if readN <= 0 {
                break
            }
            responseData.append(buffer, count: readN)
        }
        guard !responseData.isEmpty else {
            return [:]
        }
        guard let root = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw SidecarError.failedToStart("sidecar shutdown invalid response")
        }
        if let err = root["error"] as? [String: Any] {
            let msg = (err["message"] as? String) ?? "unknown"
            throw SidecarError.failedToStart(msg)
        }
        return root["result"] as? [String: Any] ?? [:]
    }

    private func removeStaleSocketIfNeeded() {
        guard socketFileExists() else {
            return
        }
        guard !canConnectToSocket() else {
            return
        }
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func resolveSidecarScriptPath() throws -> String {
        if let env = ProcessInfo.processInfo.environment["INSIGHTKIT_SIDECAR_SCRIPT"], !env.isEmpty {
            return env
        }

        if let runtimeRoot = ProcessInfo.processInfo.environment["INSIGHTKIT_RUNTIME_ROOT"], !runtimeRoot.isEmpty {
            let candidate = URL(fileURLWithPath: runtimeRoot)
                .appendingPathComponent("scripts/insight_sidecar.py")
                .path
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }

        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL
                .appendingPathComponent("insightkit_runtime/scripts/insight_sidecar.py")
                .path
            if FileManager.default.fileExists(atPath: bundled) {
                return bundled
            }
        }

        let cwdCandidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts/insight_sidecar.py")
            .path
        if FileManager.default.fileExists(atPath: cwdCandidate) {
            return cwdCandidate
        }

        throw SidecarError.scriptMissing(cwdCandidate)
    }

    private func runtimeRootPath(from sidecarScript: String) -> String {
        let scriptURL = URL(fileURLWithPath: sidecarScript)
        return scriptURL.deletingLastPathComponent().deletingLastPathComponent().path
    }

    private static func resolveConfiguredPythonBinary() -> String {
        if let env = ProcessInfo.processInfo.environment["INSIGHTKIT_PYTHON"], !env.isEmpty {
            return env
        }
        return ""
    }

    /// 返回已排序的 Python 候选列表（懒加载 + 缓存）。
    /// 仅在 startIfNeeded（后台线程中调用）时第一次执行扫描，后续复用缓存。
    private func resolvedPythonCandidates() -> [String] {
        _candidatesLock.lock()
        defer { _candidatesLock.unlock() }
        if let cached = _cachedCandidates {
            return cached
        }
        let built = SidecarManager.buildPythonCandidates(preferred: pythonBinary)
        _cachedCandidates = built
        return built
    }

    private static func buildPythonCandidates(preferred: String) -> [String] {
        if let env = ProcessInfo.processInfo.environment["INSIGHTKIT_PYTHON"], !env.isEmpty {
            return [env]
        }
        var ordered: [String] = []
        if !preferred.isEmpty {
            ordered.append(preferred)
        }
        for candidate in rankedPythonBinaries() where !ordered.contains(candidate) {
            ordered.append(candidate)
        }
        if !ordered.contains("python3") {
            ordered.append("python3")
        }
        return ordered
    }

    private static func rankedPythonBinaries() -> [String] {
        let fileManager = FileManager.default
        let home = NSHomeDirectory()
        let searchDirs = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/miniconda3/bin",
            "\(home)/anaconda3/bin",
            "\(home)/.pyenv/shims",
            "/usr/bin",
        ]
        let preferredPaths = [
            "\(home)/miniconda3/envs/transcribe/bin/python",
            "\(home)/anaconda3/envs/transcribe/bin/python",
        ]

        let pattern = try? NSRegularExpression(pattern: #"^python3(\.\d+)?$"#)
        var candidates: Set<String> = ["python3"]
        for path in preferredPaths where fileManager.isExecutableFile(atPath: path) {
            candidates.insert(path)
        }

        for dir in searchDirs {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: dir) else {
                continue
            }
            for name in entries {
                let range = NSRange(location: 0, length: name.utf16.count)
                guard pattern?.firstMatch(in: name, options: [], range: range) != nil else {
                    continue
                }
                let fullPath = URL(fileURLWithPath: dir).appendingPathComponent(name).path
                if fileManager.isExecutableFile(atPath: fullPath) {
                    candidates.insert(fullPath)
                }
            }
        }

        let ranked = candidates.compactMap { cmd -> (cmd: String, version: (Int, Int, Int), hasASRDeps: Bool)? in
            guard let version = pythonVersion(for: cmd) else {
                return nil
            }
            let hasASRDeps = pythonHasASRDeps(for: cmd)
            return (cmd: cmd, version: version, hasASRDeps: hasASRDeps)
        }

        return ranked.sorted(by: { lhs, rhs in
            if lhs.hasASRDeps != rhs.hasASRDeps { return lhs.hasASRDeps && !rhs.hasASRDeps }
            let lhsRank = versionRank(lhs.version)
            let rhsRank = versionRank(rhs.version)
            if lhsRank != rhsRank { return lhsRank > rhsRank }
            if lhs.version.2 != rhs.version.2 { return lhs.version.2 > rhs.version.2 }
            return lhs.cmd < rhs.cmd
        }).map(\.cmd)
    }

    private static func versionRank(_ version: (Int, Int, Int)) -> Int {
        let (major, minor, _) = version
        guard major == 3 else { return 0 }
        switch minor {
        case 11: return 100
        case 12: return 95
        case 10: return 90
        case 13: return 80
        case 14: return 60
        default: return 50
        }
    }

    private static func pythonHasASRDeps(for command: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            command,
            "-c",
            "import importlib.util as u; print('1' if (u.find_spec('faster_whisper') and u.find_spec('silero_vad')) else '0')",
        ]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return false }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
        return text == "1"
    }

    private static func pythonVersion(for command: String) -> (Int, Int, Int)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            command,
            "-c",
            "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}.{sys.version_info[2]}')",
        ]

        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else {
            return nil
        }

        let parts = text.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else {
            return nil
        }
        let major = parts[0]
        let minor = parts[1]
        let patch = parts.count > 2 ? parts[2] : 0
        guard major >= 3 else {
            return nil
        }
        return (major, minor, patch)
    }

    private static func resolveLogPath() -> String {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/InsightKit")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("sidecar.log").path
    }

    private static func openLogHandle(at path: String) -> FileHandle? {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: path) {
            fileManager.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else {
            return nil
        }
        do {
            try handle.seekToEnd()
        } catch {
            return nil
        }
        return handle
    }

    private static func tailLog(path: String, maxBytes: Int) -> String {
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else {
            return ""
        }
        let slice: Data
        if data.count > maxBytes {
            slice = data.suffix(maxBytes)
        } else {
            slice = data
        }
        return String(data: slice, encoding: .utf8) ?? ""
    }
}
