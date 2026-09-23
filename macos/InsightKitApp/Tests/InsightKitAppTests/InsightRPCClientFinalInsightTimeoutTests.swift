import Darwin
import Foundation
import XCTest
@testable import InsightKitApp

final class InsightRPCClientFinalInsightTimeoutTests: XCTestCase {
    func testRefreshLiveSurvivesGenericRPCTimeout() throws {
        let socketPath = "/tmp/insightkit-live-\(UUID().uuidString).sock"
        let sidecar = DelayedInsightSidecar(socketPath: socketPath, responseDelay: 2.0)
        try sidecar.start()
        defer { sidecar.stop() }

        let client = makeClient(socketPath: socketPath)

        let result = try client.refreshLive(meetingID: "live-timeout-regression")

        XCTAssertEqual(result.provider, "fake:slow-test")
        XCTAssertFalse(result.package.sessionOverview.overview.isEmpty)
        XCTAssertEqual(sidecar.receivedMethods, ["insight.refresh_live"])
    }

    func testBuildFinalUsesDedicatedFinalInsightTimeout() throws {
        let socketPath = "/tmp/insightkit-final-\(UUID().uuidString).sock"
        let sidecar = DelayedInsightSidecar(socketPath: socketPath, responseDelay: 2.0)
        try sidecar.start()
        defer { sidecar.stop() }

        let client = makeClient(socketPath: socketPath)

        let result = try client.buildFinal(meetingID: "live-final-timeout-regression")

        XCTAssertEqual(result.package.sessionOverview.title, "Final Insight Ready")
        XCTAssertEqual(result.package.sessionOverview.overview, "Final insight completed after a slow provider response.")
        XCTAssertEqual(result.provider, "fake:slow-test")
        XCTAssertEqual(sidecar.receivedMethods, ["smart_minutes.generate"])
    }

    func testRefreshLiveHonorsItsOwnTimeout() throws {
        let socketPath = "/tmp/insightkit-live-deadline-\(UUID().uuidString).sock"
        let sidecar = DelayedInsightSidecar(socketPath: socketPath, responseDelay: 2.0)
        try sidecar.start()
        defer { sidecar.stop() }
        let client = makeClient(socketPath: socketPath, timeoutSec: 3, liveInsightTimeoutSec: 1)

        XCTAssertThrowsError(try client.refreshLive(meetingID: "live-deadline")) { error in
            guard case InsightRPCClient.RPCError.timeout("insight.refresh_live") = error else {
                return XCTFail("Expected the live insight deadline, got \(error)")
            }
        }
        XCTAssertEqual(sidecar.receivedMethods, ["insight.refresh_live"])
    }

    func testRefreshLiveDoesNotAutomaticallyRetryProviderFailure() throws {
        let socketPath = "/tmp/insightkit-live-no-retry-\(UUID().uuidString).sock"
        let sidecar = DelayedInsightSidecar(
            socketPath: socketPath,
            responseDelay: 0,
            maximumRequests: 3,
            responseError: "provider temporarily unavailable"
        )
        try sidecar.start()
        defer { sidecar.stop() }
        let client = makeClient(socketPath: socketPath, maxRetries: 2)

        XCTAssertThrowsError(try client.refreshLive(meetingID: "live-no-retry")) { error in
            guard case InsightRPCClient.RPCError.remoteError("provider temporarily unavailable") = error else {
                return XCTFail("Expected the provider error, got \(error)")
            }
        }
        XCTAssertEqual(sidecar.receivedMethods, ["insight.refresh_live"])
    }

    func testSessionStartKeepsGenericRPCTimeout() throws {
        let socketPath = "/tmp/insightkit-generic-deadline-\(UUID().uuidString).sock"
        let sidecar = DelayedInsightSidecar(socketPath: socketPath, responseDelay: 2.0)
        try sidecar.start()
        defer { sidecar.stop() }
        let client = makeClient(socketPath: socketPath)

        XCTAssertThrowsError(try client.sessionStart(meetingID: "generic-deadline", title: "Test", source: "mic")) { error in
            guard case InsightRPCClient.RPCError.timeout("session.start") = error else {
                return XCTFail("Expected the generic RPC deadline, got \(error)")
            }
        }
        XCTAssertEqual(sidecar.receivedMethods, ["session.start"])
    }

    private func makeClient(
        socketPath: String,
        timeoutSec: Int = 1,
        liveInsightTimeoutSec: Int = 3,
        maxRetries: Int = 0
    ) -> InsightRPCClient {
        InsightRPCClient(config: InsightRPCClient.Config(
            socketPath: socketPath,
            timeoutSec: timeoutSec,
            asrChunkTimeoutSec: 120,
            asrMediaTimeoutSec: 900,
            providerProbeTimeoutSec: 6,
            finalInsightTimeoutSec: 3,
            liveInsightTimeoutSec: liveInsightTimeoutSec,
            maxRetries: maxRetries,
            breakerThreshold: 4,
            breakerCooldownSec: 10
        ))
    }
}

private final class DelayedInsightSidecar {
    private let socketPath: String
    private let responseDelay: TimeInterval
    private let maximumRequests: Int
    private let responseError: String?
    private var listenFD: Int32 = -1
    private var serverThread: Thread?
    private let lock = NSLock()
    private var methods: [String] = []
    private let finished = DispatchSemaphore(value: 0)

    init(socketPath: String, responseDelay: TimeInterval, maximumRequests: Int = 1, responseError: String? = nil) {
        self.socketPath = socketPath
        self.responseDelay = responseDelay
        self.maximumRequests = maximumRequests
        self.responseError = responseError
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
            throw NSError(domain: "DelayedInsightSidecar", code: Int(ENAMETOOLONG), userInfo: [
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

        let serverFD = listenFD
        serverThread = Thread { [weak self] in
            self?.run(serverFD: serverFD)
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

    private func run(serverFD: Int32) {
        defer { finished.signal() }
        for _ in 0..<maximumRequests {
            let clientFD = Darwin.accept(serverFD, nil, nil)
            guard clientFD >= 0 else { return }
            handle(clientFD)
        }
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

        var response: [String: Any] = [
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
        if let responseError {
            response.removeValue(forKey: "result")
            response["error"] = ["code": -32000, "message": responseError]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: response) else { return }
        _ = data.withUnsafeBytes { bytes in
            Darwin.write(clientFD, bytes.baseAddress, bytes.count)
        }
    }

    private func posixError(_ operation: String) -> NSError {
        NSError(domain: "DelayedInsightSidecar", code: Int(errno), userInfo: [
            NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(errno)))",
        ])
    }
}
