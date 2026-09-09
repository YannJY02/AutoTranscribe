import Darwin
import Foundation

extension LiveSessionViewModel {
    /// Portable native-proof fixture: both the old and progressive pipelines use
    /// their normal processChunk/RPC path against the test app's local socket.
    /// It deliberately depends only on APIs present before progressive delivery.
    func startDelayedSummaryUITestScenario(meetingID: String) {
        guard UITestLaunchOptions.isEnabled,
              ProcessInfo.processInfo.environment["INSIGHTKIT_UI_TEST_SCENARIO"] == "live-delayed-summary",
              let storage = UITestStorageContext.current else { return }
        stopDelayedSummaryUITestScenario()
        do {
            delayedSummaryUITestFixture = try DelayedSummarySocketFixture(socketPath: storage.socketPath)
        } catch {
            publishError(error)
            return
        }
        transcriptSegments = []
        metrics = LiveSessionMetrics()
        captureHealth.sessionStartedAt = Date()
        recordingDuration = 0
        transcriptPipeline.reset()
        pipelineQueue.async { [weak self] in
            guard let self else { return }
            for index in 0..<2 {
                guard self.isRunning else { return }
                let chunk = AudioChunk(index: index,
                    url: URL(fileURLWithPath: "/tmp/insightkit-ui-synthetic-\(index).wav"),
                    startMs: index * 2_000, endMs: (index + 1) * 2_000, rms: 0.2)
                do { _ = try self.processChunk(chunk, meetingID: meetingID) }
                catch { self.publishError(error); return }
            }
        }
    }

    func stopDelayedSummaryUITestScenario() {
        delayedSummaryUITestFixture?.stop()
        delayedSummaryUITestFixture = nil
    }
}

/// A bounded fixture owned by the UI-test app. The sandboxed UI runner only
/// operates the interface; all calls still pass through the normal RPC client.
/// It uses no model, microphone, provider, or user data.
final class DelayedSummarySocketFixture: @unchecked Sendable {
    private let socketPath: String
    private let lock = NSLock()
    private var descriptor: Int32 = -1

    init(socketPath: String) throws {
        self.socketPath = socketPath
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw fixtureError("socket", errorCode: errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < pathCapacity else {
            Darwin.close(fd)
            throw fixtureError("path", errorCode: ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) {
                _ = strcpy($0, socketPath)
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let failure = fixtureError("bind", errorCode: errno)
            Darwin.close(fd)
            throw failure
        }
        guard Darwin.listen(fd, 8) == 0 else {
            let failure = fixtureError("listen", errorCode: errno)
            Darwin.close(fd)
            try? FileManager.default.removeItem(atPath: socketPath)
            throw failure
        }
        descriptor = fd
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.acceptConnections() }
    }

    func stop() {
        let fd = lock.withLock { () -> Int32 in
            let fd = descriptor
            descriptor = -1
            return fd
        }
        if fd >= 0 {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            try? FileManager.default.removeItem(atPath: socketPath)
        }
    }

    private func acceptConnections() {
        while true {
            let fd = lock.withLock { descriptor }
            guard fd >= 0 else { return }
            let client = Darwin.accept(fd, nil, nil)
            guard client >= 0 else { return }
            DispatchQueue.global(qos: .utility).async { Self.respond(to: client) }
        }
    }

    private static func respond(to client: Int32) {
        defer { Darwin.close(client) }
        var noSignal: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 8, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var input = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.read(client, &buffer, buffer.count)
            if count <= 0 { break }
            input.append(contentsOf: buffer.prefix(count))
            if input.count > 64_000 { return }
        }
        guard let request = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else { return }
        let method = request["method"] as? String ?? ""
        let params = request["params"] as? [String: Any] ?? [:]
        let result: [String: Any]
        switch method {
        case "asr.transcribe_chunk", "asr.transcribe_live_chunk":
            let start = params["offset_ms"] as? Int ?? 0
            result = ["segments": [["start_ms": start, "end_ms": start + 2_000,
                "speaker": "", "confidence": 1, "source": params["source"] as? String ?? "mic",
                "text": start == 0 ? "第一句话应该立即显示。" : "第二句话应该继续显示，不必等待摘要。"]]]
        case "transcript.delta":
            result = ["ingested": (params["segments"] as? [Any])?.count ?? 0]
        case "asr.enrich_live_chunk":
            result = ["meeting_id": params["meeting_id"] as? String ?? "", "status": "pending", "updates": []]
        case "insight.refresh_live":
            Thread.sleep(forTimeInterval: 6)
            result = ["provider": "local", "provider_model": "ui-delayed-fixture", "needs_review_count": 0,
                "insight_package": ["session_overview": ["title": "测试", "overview": "延迟摘要已完成", "topics": []],
                    "highlight_insights": [], "speaker_perspectives": [], "decision_ledger": [],
                    "action_tracks": [], "timeline_beats": [], "provenance_links": []]]
        default:
            result = [:]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["id": request["id"] ?? 0, "result": result]) else { return }
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let count = Darwin.write(client, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if count <= 0 { break }
                sent += count
            }
        }
    }
}

private func fixtureError(_ operation: String, errorCode: Int32) -> NSError {
    NSError(domain: "LiveDelayedSummaryFixture", code: Int(errorCode), userInfo: [
        NSLocalizedDescriptionKey: "UI delayed-summary fixture \(operation): \(String(cString: strerror(errorCode)))"
    ])
}
