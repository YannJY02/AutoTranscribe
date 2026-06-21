# Phase 2: IPC 层升级实施计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将 IPC 从短连接 JSON-RPC 升级为 NDJSON 长连接 + 服务端推送 + Swift Codable 类型安全。

**Architecture:** Python 端 server.py 的 `_handle_conn` 改为双模式（检测握手帧选择长/短连接）。新增 `PushBroker` 管理推送。Swift 端新增 `RPCTransport`（持久连接管理）和 `RPCCodec`（Codable 编解码），`InsightRPCClient` 改为调用 transport 层。

**Tech Stack:** Python 3.11 (socket, threading, json), Swift 5.9 (Foundation, Codable, DispatchQueue)

---

### Task 1: PushBroker — Python 推送管理器

**Files:**
- Create: `insightkit/ipc/push_broker.py`
- Test: `tests/test_push_broker.py`

**Step 1: Write the failing test**

创建 `tests/test_push_broker.py`：

```python
"""Tests for PushBroker push event manager."""
import json
import socket
import threading
import unittest

from insightkit.ipc.push_broker import PushBroker


class TestPushBroker(unittest.TestCase):
    def test_register_and_emit(self):
        """emit sends NDJSON event to all registered clients."""
        broker = PushBroker()
        server_sock, client_sock = socket.socketpair()
        try:
            broker.register(server_sock)
            broker.emit("test.event", {"key": "value"})
            raw = client_sock.recv(4096)
            msg = json.loads(raw.decode("utf-8").strip())
            self.assertEqual(msg["event"], "test.event")
            self.assertEqual(msg["data"]["key"], "value")
        finally:
            broker.unregister(server_sock)
            server_sock.close()
            client_sock.close()

    def test_unregister_removes_client(self):
        """After unregister, emit does not send to that client."""
        broker = PushBroker()
        server_sock, client_sock = socket.socketpair()
        try:
            broker.register(server_sock)
            broker.unregister(server_sock)
            broker.emit("test.event", {"key": "value"})
            client_sock.settimeout(0.1)
            with self.assertRaises(socket.timeout):
                client_sock.recv(4096)
        finally:
            server_sock.close()
            client_sock.close()

    def test_emit_broken_client_auto_removes(self):
        """If a client's socket is broken, emit silently removes it."""
        broker = PushBroker()
        server_sock, client_sock = socket.socketpair()
        client_sock.close()  # Break the receiving end
        broker.register(server_sock)
        broker.emit("test.event", {"key": "value"})  # Should not raise
        self.assertEqual(broker.client_count, 0)
        server_sock.close()

    def test_emit_multiple_clients(self):
        """emit broadcasts to all registered clients."""
        broker = PushBroker()
        pairs = [socket.socketpair() for _ in range(3)]
        try:
            for s, _ in pairs:
                broker.register(s)
            broker.emit("broadcast", {"n": 42})
            for _, c in pairs:
                raw = c.recv(4096)
                msg = json.loads(raw.decode("utf-8").strip())
                self.assertEqual(msg["event"], "broadcast")
                self.assertEqual(msg["data"]["n"], 42)
        finally:
            for s, c in pairs:
                broker.unregister(s)
                s.close()
                c.close()
```

**Step 2: Run test to verify it fails**

Run: `python3 -m pytest tests/test_push_broker.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'insightkit.ipc.push_broker'`

**Step 3: Write minimal implementation**

创建 `insightkit/ipc/push_broker.py`：

```python
"""Push event broker for persistent IPC connections."""

from __future__ import annotations

import json
import logging
import socket
import threading
from typing import Any

logger = logging.getLogger(__name__)


class PushBroker:
    """Manages persistent client connections and broadcasts push events."""

    def __init__(self) -> None:
        self._clients: dict[int, socket.socket] = {}
        self._lock = threading.Lock()

    @property
    def client_count(self) -> int:
        with self._lock:
            return len(self._clients)

    def register(self, conn: socket.socket) -> None:
        with self._lock:
            self._clients[conn.fileno()] = conn

    def unregister(self, conn: socket.socket) -> None:
        with self._lock:
            self._clients.pop(conn.fileno(), None)

    def emit(self, event: str, data: dict[str, Any]) -> None:
        message = json.dumps(
            {"event": event, "data": data},
            ensure_ascii=False,
            separators=(",", ":"),
        ) + "\n"
        payload = message.encode("utf-8")
        dead: list[int] = []
        with self._lock:
            for fd, conn in self._clients.items():
                try:
                    conn.sendall(payload)
                except (BrokenPipeError, ConnectionResetError, OSError):
                    dead.append(fd)
            for fd in dead:
                self._clients.pop(fd, None)
                logger.debug("push_broker: removed dead client fd=%d", fd)
```

**Step 4: Run test to verify it passes**

Run: `python3 -m pytest tests/test_push_broker.py -v`
Expected: 4 PASS

**Step 5: Run full regression**

Run: `python3 -m pytest tests/ -x --tb=short`
Expected: 81 tests passed (77 existing + 4 new)

---

### Task 2: Python 长连接处理 — server.py 双模式

**Files:**
- Modify: `insightkit/ipc/server.py`
- Test: `tests/test_persistent_conn.py`

**Step 1: Write the failing test**

创建 `tests/test_persistent_conn.py`：

```python
"""Tests for persistent NDJSON connection mode."""
import json
import socket
import tempfile
import threading
import time
import unittest
from pathlib import Path

from insightkit.ipc.server import InsightRPCServer


class TestPersistentConnection(unittest.TestCase):
    def setUp(self):
        self.sock_path = Path(tempfile.mktemp(suffix=".sock"))
        self.server = InsightRPCServer(socket_path=self.sock_path)
        self.server_thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.server_thread.start()
        for _ in range(50):
            if self.sock_path.exists():
                break
            time.sleep(0.05)

    def tearDown(self):
        self.server.shutdown()
        self.server_thread.join(timeout=2)

    def _connect(self) -> socket.socket:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(5)
        conn.connect(str(self.sock_path))
        return conn

    def _send_line(self, conn: socket.socket, obj: dict) -> None:
        line = json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n"
        conn.sendall(line.encode("utf-8"))

    def _recv_line(self, conn: socket.socket) -> dict:
        reader = conn.makefile("rb")
        raw = reader.readline()
        return json.loads(raw.decode("utf-8"))

    def test_handshake(self):
        """Client sends handshake, server replies with confirmation."""
        conn = self._connect()
        try:
            self._send_line(conn, {"insightkit": "1.0"})
            reply = self._recv_line(conn)
            self.assertEqual(reply["insightkit"], "1.0")
            self.assertTrue(reply.get("push"))
        finally:
            conn.close()

    def test_multiple_requests_one_connection(self):
        """Multiple RPC calls over a single persistent connection."""
        conn = self._connect()
        try:
            self._send_line(conn, {"insightkit": "1.0"})
            self._recv_line(conn)  # handshake reply

            reader = conn.makefile("rb")
            for i in range(3):
                self._send_line(conn, {"id": i + 1, "method": "sidecar.status", "params": {}})
                raw = reader.readline()
                resp = json.loads(raw.decode("utf-8"))
                self.assertEqual(resp["id"], i + 1)
                self.assertIn("result", resp)
                self.assertTrue(resp["result"]["running"])
        finally:
            conn.close()

    def test_legacy_mode_still_works(self):
        """Without handshake, old-style single-shot RPC still works."""
        conn = self._connect()
        try:
            req = json.dumps({"id": 1, "method": "sidecar.status", "params": {}}).encode("utf-8")
            conn.sendall(req)
            conn.shutdown(socket.SHUT_WR)
            data = b""
            while True:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                data += chunk
            resp = json.loads(data.decode("utf-8"))
            self.assertEqual(resp["id"], 1)
            self.assertTrue(resp["result"]["running"])
        finally:
            conn.close()

    def test_push_event_received(self):
        """Server push events reach persistent clients."""
        conn = self._connect()
        try:
            self._send_line(conn, {"insightkit": "1.0"})
            self._recv_line(conn)  # handshake reply

            # Trigger a push from the broker
            self.server._push_broker.emit("test.ping", {"ts": 123})

            reader = conn.makefile("rb")
            raw = reader.readline()
            msg = json.loads(raw.decode("utf-8"))
            self.assertEqual(msg["event"], "test.ping")
            self.assertEqual(msg["data"]["ts"], 123)
        finally:
            conn.close()

    def test_error_response_persistent(self):
        """Unknown method returns error in persistent mode."""
        conn = self._connect()
        try:
            self._send_line(conn, {"insightkit": "1.0"})
            self._recv_line(conn)  # handshake reply

            reader = conn.makefile("rb")
            self._send_line(conn, {"id": 99, "method": "no.such.method", "params": {}})
            raw = reader.readline()
            resp = json.loads(raw.decode("utf-8"))
            self.assertEqual(resp["id"], 99)
            self.assertIn("error", resp)
        finally:
            conn.close()
```

**Step 2: Run test to verify it fails**

Run: `python3 -m pytest tests/test_persistent_conn.py -v`
Expected: FAIL — handshake test fails (server doesn't support persistent mode yet)

**Step 3: Implement persistent connection in server.py**

Modify `insightkit/ipc/server.py`:

1. Add import: `from insightkit.ipc.push_broker import PushBroker`
2. In `__init__`: add `self._push_broker = PushBroker()`
3. Replace `_handle_conn` with dual-mode logic:

```python
def _handle_conn(self, conn: socket.socket) -> None:
    with conn:
        try:
            reader = conn.makefile("rb")
            first_line = reader.readline()
            if not first_line:
                return
            first_msg = json.loads(first_line.decode("utf-8"))

            if "insightkit" in first_msg:
                self._handle_persistent(conn, reader, first_msg)
            else:
                self._handle_legacy(conn, first_msg)
        except Exception as exc:
            logger.debug("connection handler error: %s", exc)

def _handle_legacy(self, conn: socket.socket, first_msg: dict[str, Any]) -> None:
    """Handle old-style single-shot RPC (recv all → dispatch → sendall → close)."""
    try:
        response = self._dispatch(first_msg)
    except Exception as exc:
        self._last_error_code = "bad_request"
        response = {"id": None, "error": {"code": -32000, "message": str(exc)}}
    try:
        conn.sendall(json.dumps(response, ensure_ascii=False).encode("utf-8"))
    except (BrokenPipeError, ConnectionResetError, OSError):
        logger.debug("legacy client disconnected before response send")

def _handle_persistent(
    self,
    conn: socket.socket,
    reader: Any,
    handshake: dict[str, Any],
) -> None:
    """Handle persistent NDJSON connection."""
    # Send handshake confirmation
    ack = json.dumps(
        {"insightkit": handshake.get("insightkit", "1.0"), "push": True},
        ensure_ascii=False, separators=(",", ":"),
    ) + "\n"
    conn.sendall(ack.encode("utf-8"))

    self._push_broker.register(conn)
    try:
        while self._active:
            line = reader.readline()
            if not line:
                break
            try:
                req = json.loads(line.decode("utf-8"))
            except (json.JSONDecodeError, UnicodeDecodeError) as exc:
                err_resp = json.dumps(
                    {"id": None, "error": {"code": -32700, "message": str(exc)}},
                    ensure_ascii=False, separators=(",", ":"),
                ) + "\n"
                conn.sendall(err_resp.encode("utf-8"))
                continue
            response = self._dispatch(req)
            resp_line = json.dumps(
                response, ensure_ascii=False, separators=(",", ":"),
            ) + "\n"
            conn.sendall(resp_line.encode("utf-8"))
    except (BrokenPipeError, ConnectionResetError, OSError):
        logger.debug("persistent client disconnected")
    finally:
        self._push_broker.unregister(conn)
```

4. In `shutdown`: add `self._push_broker` shutdown.

**Step 4: Run test to verify it passes**

Run: `python3 -m pytest tests/test_persistent_conn.py -v`
Expected: 5 PASS

**Step 5: Run full regression**

Run: `python3 -m pytest tests/ -x --tb=short`
Expected: 86 tests passed (77 existing + 4 push_broker + 5 persistent_conn)

---

### Task 3: JobQueue 接入推送 — 进度和完成事件

**Files:**
- Modify: `insightkit/ipc/job_queue.py`
- Modify: `insightkit/ipc/server.py` (传入 push_broker)
- Test: `tests/test_job_queue_push.py`

**Step 1: Write the failing test**

创建 `tests/test_job_queue_push.py`：

```python
"""Tests for JobQueue push event integration."""
import threading
import unittest
from unittest import mock

from insightkit.ipc.push_broker import PushBroker
from insightkit.ipc.job_queue import JobQueue


class TestJobQueuePush(unittest.TestCase):
    def test_update_progress_emits_event(self):
        """_update_progress calls push_broker.emit with transcription.progress."""
        broker = mock.create_autospec(PushBroker, instance=True)
        store = mock.MagicMock()
        store.upsert_transcription_job = mock.MagicMock()
        insight = mock.MagicMock()
        watch = mock.MagicMock()
        jq = JobQueue(store=store, insight_service=insight, watch_bridge=watch, push_broker=broker)

        # Inject a fake running job
        jq._jobs["j1"] = {
            "id": "j1", "meeting_id": "m1", "source_path": "/tmp/f.mp4",
            "title": "test", "state": "running", "progress": 10,
            "stage": "transcribing", "error": "", "reason": "",
            "started_at": "", "ended_at": "",
        }
        jq._update_progress("j1", 50, "transcribing")

        broker.emit.assert_called_once_with(
            "transcription.progress",
            {"job_id": "j1", "progress": 50, "stage": "transcribing"},
        )

    def test_no_push_if_no_broker(self):
        """If push_broker is None, _update_progress still works."""
        store = mock.MagicMock()
        store.upsert_transcription_job = mock.MagicMock()
        insight = mock.MagicMock()
        watch = mock.MagicMock()
        jq = JobQueue(store=store, insight_service=insight, watch_bridge=watch, push_broker=None)

        jq._jobs["j1"] = {
            "id": "j1", "meeting_id": "m1", "source_path": "/tmp/f.mp4",
            "title": "test", "state": "running", "progress": 10,
            "stage": "transcribing", "error": "", "reason": "",
            "started_at": "", "ended_at": "",
        }
        jq._update_progress("j1", 50, "transcribing")  # Should not raise
        self.assertEqual(jq._jobs["j1"]["progress"], 50)
```

**Step 2: Run test to verify it fails**

Run: `python3 -m pytest tests/test_job_queue_push.py -v`
Expected: FAIL — `TypeError: __init__() got unexpected keyword argument 'push_broker'`

**Step 3: Implement**

Modify `insightkit/ipc/job_queue.py`:

1. `__init__` 新增可选参数 `push_broker: PushBroker | None = None`
2. `self._push_broker = push_broker`
3. `_update_progress` 尾部添加推送：
```python
if self._push_broker is not None:
    self._push_broker.emit("transcription.progress", {
        "job_id": job_id, "progress": job["progress"], "stage": stage,
    })
```
4. `_worker_loop` 中 job 完成时添加推送：
```python
if self._push_broker is not None:
    self._push_broker.emit("transcription.completed", {
        "job_id": j["id"], "meeting_id": j.get("meeting_id", ""), "state": j["state"],
    })
```

Modify `insightkit/ipc/server.py`:
- 传入 `push_broker=self._push_broker` 给 `JobQueue`

**Step 4: Run test to verify it passes**

Run: `python3 -m pytest tests/test_job_queue_push.py -v`
Expected: 2 PASS

**Step 5: Run full regression**

Run: `python3 -m pytest tests/ -x --tb=short`
Expected: 88 tests passed

---

### Task 4: Swift RPCTransport — 持久连接管理

**Files:**
- Create: `macos/InsightKitApp/Sources/InsightKitApp/Services/RPCTransport.swift`
- Test: `macos/InsightKitApp/Tests/InsightKitAppTests/RPCTransportTests.swift`

**Step 1: Write the failing test**

创建 `RPCTransportTests.swift`：

```swift
import XCTest
@testable import InsightKitApp

final class RPCTransportTests: XCTestCase {
    func testFrameSplitting() {
        // Test NDJSON frame parsing
        let buffer = RPCFrameBuffer()
        let data = "{\"id\":1,\"result\":{}}\n{\"event\":\"test\"}\n".data(using: .utf8)!
        let frames = buffer.append(data)
        XCTAssertEqual(frames.count, 2)
    }

    func testPartialFrame() {
        let buffer = RPCFrameBuffer()
        let part1 = "{\"id\":1,".data(using: .utf8)!
        let part2 = "\"result\":{}}\n".data(using: .utf8)!
        let frames1 = buffer.append(part1)
        XCTAssertEqual(frames1.count, 0, "Partial frame should not produce output")
        let frames2 = buffer.append(part2)
        XCTAssertEqual(frames2.count, 1)
    }

    func testEmptyLine() {
        let buffer = RPCFrameBuffer()
        let data = "\n\n{\"id\":1}\n\n".data(using: .utf8)!
        let frames = buffer.append(data)
        XCTAssertEqual(frames.count, 1, "Empty lines should be skipped")
    }

    func testHandshakeMessage() {
        let handshake = RPCHandshake(version: "1.0")
        let data = try! JSONEncoder().encode(handshake)
        let decoded = try! JSONDecoder().decode(RPCHandshake.self, from: data)
        XCTAssertEqual(decoded.insightkit, "1.0")
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --package-path macos/InsightKitApp --filter RPCTransportTests 2>&1 | tail -5`
Expected: FAIL — compilation error, types don't exist

**Step 3: Implement RPCTransport.swift**

创建 `macos/InsightKitApp/Sources/InsightKitApp/Services/RPCTransport.swift`：

```swift
import Foundation
import Darwin

// MARK: - NDJSON Frame Buffer

final class RPCFrameBuffer {
    private var buffer = Data()

    func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        let newline = UInt8(ascii: "\n")
        while let idx = buffer.firstIndex(of: newline) {
            let line = buffer[buffer.startIndex..<idx]
            buffer = Data(buffer[(idx + 1)...])
            if line.isEmpty { continue }
            frames.append(Data(line))
        }
        return frames
    }

    func reset() {
        buffer = Data()
    }
}

// MARK: - Handshake

struct RPCHandshake: Codable {
    let insightkit: String
    var push: Bool?

    init(version: String = "1.0", push: Bool? = nil) {
        self.insightkit = version
        self.push = push
    }
}

// MARK: - Transport

protocol RPCTransportDelegate: AnyObject {
    func transportDidConnect(_ transport: RPCTransport)
    func transportDidDisconnect(_ transport: RPCTransport, error: Error?)
    func transport(_ transport: RPCTransport, didReceiveEvent event: String, data: [String: Any])
}

final class RPCTransport {
    enum TransportError: LocalizedError {
        case notConnected
        case handshakeFailed
        case socketError(String)
        case timeout(String)

        var errorDescription: String? {
            switch self {
            case .notConnected: return "Transport 未连接。"
            case .handshakeFailed: return "握手失败。"
            case .socketError(let r): return "Socket 错误: \(r)"
            case .timeout(let m): return "超时: \(m)"
            }
        }
    }

    private let socketPath: String
    private let ioQueue = DispatchQueue(label: "InsightKit.RPCTransport.IO", qos: .userInitiated)
    private let stateQueue = DispatchQueue(label: "InsightKit.RPCTransport.State")
    private var fd: Int32 = -1
    private var isConnected = false
    private var readSource: DispatchSourceRead?
    private let frameBuffer = RPCFrameBuffer()
    private var pendingRequests: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var nextID = 1
    weak var delegate: RPCTransportDelegate?

    init(socketPath: String = InsightRuntimeDefaults.socketPath) {
        self.socketPath = socketPath
    }

    func connect() throws {
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { throw TransportError.socketError("socket() failed") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= capacity else {
            Darwin.close(sock)
            throw TransportError.socketError("socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            buffer.initializeMemory(as: CChar.self, repeating: 0)
            _ = pathBytes.withUnsafeBytes { src in
                memcpy(buffer.baseAddress, src.baseAddress, min(buffer.count, src.count))
            }
        }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddr in
                Darwin.connect(sock, sockAddr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(sock)
            throw TransportError.socketError("connect failed: \(reason)")
        }

        self.fd = sock

        // Send handshake
        let handshake = RPCHandshake(version: "1.0")
        let handshakeData = try JSONEncoder().encode(handshake)
        var line = handshakeData
        line.append(UInt8(ascii: "\n"))
        let sent = line.withUnsafeBytes { Darwin.write(sock, $0.baseAddress, $0.count) }
        guard sent > 0 else {
            Darwin.close(sock)
            throw TransportError.handshakeFailed
        }

        // Read handshake response
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        withUnsafePointer(to: &tv) { ptr in
            _ = setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }

        var buf = [UInt8](repeating: 0, count: 4096)
        let readN = Darwin.read(sock, &buf, buf.count)
        guard readN > 0 else {
            Darwin.close(sock)
            throw TransportError.handshakeFailed
        }
        let responseData = Data(buf[0..<readN])
        let frames = frameBuffer.append(responseData)
        guard let firstFrame = frames.first,
              let ack = try? JSONSerialization.jsonObject(with: firstFrame) as? [String: Any],
              ack["insightkit"] != nil else {
            Darwin.close(sock)
            throw TransportError.handshakeFailed
        }

        stateQueue.sync { isConnected = true }
        startReadLoop()
        delegate?.transportDidConnect(self)
    }

    func disconnect() {
        stateQueue.sync { isConnected = false }
        readSource?.cancel()
        readSource = nil
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
        frameBuffer.reset()
        // Cancel all pending requests
        let pending = pendingRequests
        pendingRequests.removeAll()
        for (_, cont) in pending {
            cont.resume(throwing: TransportError.notConnected)
        }
    }

    func call(method: String, params: [String: Any], timeoutSec: Int = 8) async throws -> [String: Any] {
        guard stateQueue.sync(execute: { isConnected }) else {
            throw TransportError.notConnected
        }

        let requestID = stateQueue.sync { () -> Int in
            let id = nextID
            nextID += 1
            return id
        }

        let payload: [String: Any] = [
            "id": requestID,
            "method": method,
            "params": params,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        var line = data
        line.append(UInt8(ascii: "\n"))

        return try await withCheckedThrowingContinuation { continuation in
            stateQueue.sync {
                pendingRequests[requestID] = continuation
            }
            ioQueue.async { [self] in
                let sent = line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                if sent <= 0 {
                    stateQueue.sync {
                        if let cont = pendingRequests.removeValue(forKey: requestID) {
                            cont.resume(throwing: TransportError.socketError("write failed"))
                        }
                    }
                }
            }

            // Timeout
            ioQueue.asyncAfter(deadline: .now() + .seconds(timeoutSec)) { [self] in
                stateQueue.sync {
                    if let cont = pendingRequests.removeValue(forKey: requestID) {
                        cont.resume(throwing: TransportError.timeout(method))
                    }
                }
            }
        }
    }

    private func startReadLoop() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        source.setEventHandler { [weak self] in
            self?.readAvailable()
        }
        source.setCancelHandler { [weak self] in
            self?.delegate?.transportDidDisconnect(self!, error: nil)
        }
        source.resume()
        readSource = source
    }

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 8192)
        let readN = Darwin.read(fd, &buf, buf.count)
        if readN <= 0 {
            disconnect()
            return
        }
        let data = Data(buf[0..<readN])
        let frames = frameBuffer.append(data)
        for frame in frames {
            processFrame(frame)
        }
    }

    private func processFrame(_ frame: Data) {
        guard let msg = try? JSONSerialization.jsonObject(with: frame) as? [String: Any] else {
            return
        }
        // Push event
        if let event = msg["event"] as? String {
            let eventData = msg["data"] as? [String: Any] ?? [:]
            delegate?.transport(self, didReceiveEvent: event, data: eventData)
            return
        }
        // Response
        if let id = msg["id"] as? Int {
            stateQueue.sync {
                if let cont = pendingRequests.removeValue(forKey: id) {
                    if let error = msg["error"] as? [String: Any] {
                        let message = error["message"] as? String ?? "unknown error"
                        cont.resume(throwing: InsightRPCClient.RPCError.remoteError(message))
                    } else if let result = msg["result"] as? [String: Any] {
                        cont.resume(returning: result)
                    } else {
                        cont.resume(throwing: InsightRPCClient.RPCError.invalidResponse)
                    }
                }
            }
        }
    }
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --package-path macos/InsightKitApp --filter RPCTransportTests 2>&1 | tail -5`
Expected: 4 PASS

**Step 5: Run full Swift regression**

Run: `swift test --package-path macos/InsightKitApp`
Expected: All tests pass (27 existing + 4 new)

---

### Task 5: Swift RPCCodec — Codable 请求/响应类型

**Files:**
- Create: `macos/InsightKitApp/Sources/InsightKitApp/Services/RPCCodec.swift`
- Test: `macos/InsightKitApp/Tests/InsightKitAppTests/RPCCodecTests.swift`

**Step 1: Write the failing test**

创建 `RPCCodecTests.swift`：

```swift
import XCTest
@testable import InsightKitApp

final class RPCCodecTests: XCTestCase {
    func testEncodeSidecarStatusRequest() throws {
        let req = RPCRequest(id: 1, method: "sidecar.status", params: EmptyParams())
        let data = try JSONEncoder().encode(req)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["id"] as? Int, 1)
        XCTAssertEqual(obj["method"] as? String, "sidecar.status")
    }

    func testDecodeSidecarStatusResponse() throws {
        let json = """
        {"id":1,"result":{"running":true,"pid":123,"version":"0.1.0","build":"20260315","socket_path":"/tmp/test.sock","uptime_sec":60,"live_sessions":0,"ready":true,"python_executable":"/usr/bin/python3","python_version":"3.11.0","last_error_code":"","last_latency_ms":5}}
        """.data(using: .utf8)!
        let response = try RPCCodec.decode(SidecarStatusResponse.self, from: json)
        XCTAssertTrue(response.running)
        XCTAssertEqual(response.pid, 123)
        XCTAssertEqual(response.version, "0.1.0")
        XCTAssertTrue(response.ready)
    }

    func testDecodeTranscriptionProgressEvent() throws {
        let json = """
        {"event":"transcription.progress","data":{"job_id":"j1","progress":42,"stage":"transcribing"}}
        """.data(using: .utf8)!
        let event = try RPCCodec.decodeEvent(from: json)
        XCTAssertEqual(event.name, "transcription.progress")
        let progress = try RPCCodec.decode(TranscriptionProgressEvent.self, from: JSONSerialization.data(withJSONObject: event.data))
        XCTAssertEqual(progress.jobId, "j1")
        XCTAssertEqual(progress.progress, 42)
    }

    func testDecodeErrorResponse() throws {
        let json = """
        {"id":1,"error":{"code":-32601,"message":"method not found"}}
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(RPCRawResponse.self, from: json)
        XCTAssertNotNil(response.error)
        XCTAssertEqual(response.error?.message, "method not found")
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --package-path macos/InsightKitApp --filter RPCCodecTests 2>&1 | tail -5`
Expected: FAIL — types don't exist

**Step 3: Implement RPCCodec.swift**

创建 `macos/InsightKitApp/Sources/InsightKitApp/Services/RPCCodec.swift`：

```swift
import Foundation

// MARK: - Request/Response Envelope

struct RPCRequest<P: Encodable>: Encodable {
    let id: Int
    let method: String
    let params: P
}

struct EmptyParams: Codable {}

struct RPCRawResponse: Decodable {
    let id: Int?
    let result: AnyCodableValue?
    let error: RPCErrorPayload?
}

struct RPCErrorPayload: Decodable {
    let code: Int
    let message: String
}

struct RPCEventEnvelope {
    let name: String
    let data: [String: Any]
}

// MARK: - Codec

enum RPCCodec {
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }

    static func decodeEvent(from data: Data) throws -> RPCEventEnvelope {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = obj["event"] as? String else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not an event"))
        }
        let eventData = obj["data"] as? [String: Any] ?? [:]
        return RPCEventEnvelope(name: event, data: eventData)
    }
}

// MARK: - Typed Response Models

struct SidecarStatusResponse: Decodable {
    let running: Bool
    let pid: Int
    let version: String
    let build: String
    let socketPath: String
    let uptimeSec: Int
    let liveSessions: Int
    let ready: Bool
    let pythonExecutable: String
    let pythonVersion: String
    let lastErrorCode: String
    let lastLatencyMs: Int
}

// MARK: - Push Event Models

struct TranscriptionProgressEvent: Decodable {
    let jobId: String
    let progress: Int
    let stage: String
}

struct TranscriptionCompletedEvent: Decodable {
    let jobId: String
    let meetingId: String
    let state: String
}

// MARK: - AnyCodableValue for raw JSON

enum AnyCodableValue: Decodable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case dictionary([String: AnyCodableValue])
    case array([AnyCodableValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let v = try? container.decode(Bool.self) { self = .bool(v); return }
        if let v = try? container.decode(Int.self) { self = .int(v); return }
        if let v = try? container.decode(Double.self) { self = .double(v); return }
        if let v = try? container.decode(String.self) { self = .string(v); return }
        if let v = try? container.decode([String: AnyCodableValue].self) { self = .dictionary(v); return }
        if let v = try? container.decode([AnyCodableValue].self) { self = .array(v); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type")
    }
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --package-path macos/InsightKitApp --filter RPCCodecTests 2>&1 | tail -5`
Expected: 4 PASS

**Step 5: Run full Swift regression**

Run: `swift test --package-path macos/InsightKitApp`
Expected: All tests pass

---

### Task 6: InsightRPCClient 改造 — 接入 RPCTransport

**Files:**
- Modify: `macos/InsightKitApp/Sources/InsightKitApp/Services/InsightRPCClient.swift`
- Test: existing tests should continue to pass

**Step 1: Add transport mode to InsightRPCClient**

修改 `InsightRPCClient.swift`：

1. 添加 `RPCTransport` 属性和 `usePersistentConnection` 配置
2. `init` 中创建 transport 实例（但不立即连接）
3. 新增 `connectPersistent()` 方法——调用 `transport.connect()`
4. 修改 `callSync` 逻辑：如果 transport 已连接，通过 transport 发送；否则走旧短连接路径
5. 保持所有 public API 不变——`InsightRPCClientProtocol` 零改动

关键改动：
```swift
// 新增属性
private var transport: RPCTransport?
private var usePersistent: Bool = false

// 新增方法
func connectPersistent() throws {
    let t = RPCTransport(socketPath: config.socketPath)
    try t.connect()
    self.transport = t
    self.usePersistent = true
}

func disconnectPersistent() {
    transport?.disconnect()
    transport = nil
    usePersistent = false
}

// 修改 callSync
private func callSync(method: String, params: [String: Any], timeoutSec: Int? = nil) throws -> [String: Any] {
    if usePersistent, let transport {
        // 通过 persistent transport 发送
        return try callViaPersistentTransport(transport: transport, method: method, params: params, timeoutSec: timeoutSec)
    }
    // 旧短连接路径（保持不变）
    // ... existing code ...
}
```

**Step 2: Run full regression**

Run: `swift test --package-path macos/InsightKitApp`
Expected: All existing tests pass（mock 不使用 transport，不受影响）

**Step 3: 验证 Python 回归**

Run: `python3 -m pytest tests/ -x --tb=short`
Expected: All tests pass

---

### Task 7: 冒烟测试升级

**Files:**
- Modify: `scripts/smoke_test_rpc.py`

**Step 1: 在 smoke_test_rpc.py 中新增长连接测试路径**

添加 `test_persistent_connection()` 函数：
- 建立长连接（发送握手）
- 在同一连接上发送多个请求
- 验证响应正确

**Step 2: Run smoke test**

Run: `python3 scripts/smoke_test_rpc.py` (需要先启动 sidecar)

---

### Task 8: 全量回归验证

**Step 1: Python 全量测试**

Run: `python3 -m pytest tests/ -x --tb=short`
Expected: All tests pass

**Step 2: Swift 全量测试**

Run: `swift test --package-path macos/InsightKitApp`
Expected: All tests pass

**Step 3: 检查代码质量**

- `server.py` 仍 < 500 行
- 新文件 `push_broker.py` < 50 行
- `RPCTransport.swift` < 300 行
- `RPCCodec.swift` < 150 行
- 无硬编码值，无未处理的错误
