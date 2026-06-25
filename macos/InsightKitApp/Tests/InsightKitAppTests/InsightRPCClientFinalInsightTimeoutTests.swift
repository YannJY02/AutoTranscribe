import Darwin
import Foundation
import XCTest
@testable import InsightKitApp

final class InsightRPCClientFinalInsightTimeoutTests: XCTestCase {
    func testBuildFinalUsesDedicatedFinalInsightTimeout() throws {
        let socketPath = "/tmp/insightkit-final-\(UUID().uuidString).sock"
        let sidecar = DelayedBuildFinalSidecar(socketPath: socketPath, responseDelay: 2.0)
        try sidecar.start()
        defer { sidecar.stop() }

        let client = InsightRPCClient(config: InsightRPCClient.Config(
            socketPath: socketPath,
            timeoutSec: 1,
            asrChunkTimeoutSec: 120,
            providerProbeTimeoutSec: 6,
            finalInsightTimeoutSec: 3,
            maxRetries: 0,
            breakerThreshold: 4,
            breakerCooldownSec: 10
        ))

        let result = try client.buildFinal(meetingID: "live-final-timeout-regression")

        XCTAssertEqual(result.package.sessionOverview.title, "Final Insight Ready")
        XCTAssertEqual(result.package.sessionOverview.overview, "Final insight completed after a slow provider response.")
        XCTAssertEqual(result.provider, "fake:slow-test")
        XCTAssertEqual(sidecar.receivedMethods, ["insight.build_final"])
    }
}

private final class DelayedBuildFinalSidecar {
    private let socketPath: String
    private let responseDelay: TimeInterval
    private var listenFD: Int32 = -1
    private var serverThread: Thread?
    private let lock = NSLock()
    private var methods: [String] = []
    private let finished = DispatchSemaphore(value: 0)

    init(socketPath: String, responseDelay: TimeInterval) {
        self.socketPath = socketPath
        self.responseDelay = responseDelay
    }

    var receivedMethods: [String] {
        lock.lock()
        defer { lock.unlock() }
        return methods
    }

    func start() throws {
        _ = Darwin.unlink(socketPath)
        _ = Darwin.signal(SIGPIPE, SIG_IGN)

        listenFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw posixError("socket") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= capacity else {
            Darwin.close(listenFD)
            listenFD = -1
            throw NSError(domain: "DelayedBuildFinalSidecar", code: Int(ENAMETOOLONG), userInfo: [
                NSLocalizedDescriptionKey: "Socket path is too long.",
            ])
        }

        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            buffer.initializeMemory(as: CChar.self, repeating: 0)
            _ = pathBytes.withUnsafeBytes { src in
                memcpy(buffer.baseAddress, src.baseAddress, min(buffer.count, src.count))
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddr in
                Darwin.bind(listenFD, sockAddr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let error = posixError("bind")
            Darwin.close(listenFD)
            listenFD = -1
            throw error
        }

        guard Darwin.listen(listenFD, 1) == 0 else {
            let error = posixError("listen")
            Darwin.close(listenFD)
            listenFD = -1
            throw error
        }

        serverThread = Thread { [weak self] in
            self?.run()
        }
        serverThread?.start()
    }

    func stop() {
        let fd = listenFD
        if fd >= 0 {
            listenFD = -1
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            _ = Darwin.close(fd)
        }
        _ = Darwin.unlink(socketPath)
        if serverThread != nil {
            _ = finished.wait(timeout: .now() + 1.0)
            serverThread = nil
        }
    }

    deinit {
        stop()
    }

    private func run() {
        defer { finished.signal() }
        let clientFD = Darwin.accept(listenFD, nil, nil)
        guard clientFD >= 0 else { return }
        handle(clientFD)
    }

    private func handle(_ clientFD: Int32) {
        defer { Darwin.close(clientFD) }

        var requestData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(clientFD, &buffer, buffer.count)
            if count > 0 {
                requestData.append(buffer, count: count)
                continue
            }
            break
        }

        var responseID: Any = 1
        if let request = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any] {
            responseID = request["id"] ?? 1
            if let method = request["method"] as? String {
                lock.lock()
                methods.append(method)
                lock.unlock()
            }
        }

        Thread.sleep(forTimeInterval: responseDelay)

        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": responseID,
            "result": [
                "insight_package": [
                    "session_overview": [
                        "title": "Final Insight Ready",
                        "overview": "Final insight completed after a slow provider response.",
                        "topics": ["manual QA"],
                    ],
                    "highlight_insights": [],
                    "speaker_perspectives": [],
                    "decision_ledger": [],
                    "action_tracks": [],
                    "timeline_beats": [],
                    "provenance_links": [],
                ],
                "updated_at": "2026-06-25T10:00:00Z",
                "provider_vendor": "fake",
                "provider_model": "slow-test",
                "needs_review_count": 0,
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: response) else { return }
        _ = data.withUnsafeBytes { bytes in
            Darwin.write(clientFD, bytes.baseAddress, bytes.count)
        }
    }

    private func posixError(_ operation: String) -> NSError {
        NSError(domain: "DelayedBuildFinalSidecar", code: Int(errno), userInfo: [
            NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(errno)))",
        ])
    }
}
