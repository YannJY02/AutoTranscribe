# Phase 2: IPC 层升级设计文档

日期：2026-03-15
状态：已确认

## 背景

Phase 1 完成了 `server.py` 的模块拆分。Phase 2 升级 IPC 传输层：

- 从短连接（每次 RPC 新建 socket）改为长连接（持久化 socket）
- 引入服务端推送（server push）能力
- Swift 端用 Codable 替代手动 `[String: Any]` 解析
- 向后兼容旧短连接模式

## 协议设计

### 传输协议：NDJSON over persistent Unix socket

每条消息为一行 JSON + `\n`（换行符分隔 JSON，即 NDJSON）。

### 握手流程

```
客户端连接 → 发送: {"insightkit":"1.0"}\n
服务端回复: {"insightkit":"1.0","push":true}\n
此后双向通信
```

### 向后兼容检测

服务端 `accept()` 后读取第一条消息：
- 如果 JSON 对象包含 `"insightkit"` 字段 → 进入长连接模式
- 否则按旧逻辑处理（recv → dispatch → sendall → close）

### 消息类型

```json
// 请求（客户端→服务端）：有 method + id
{"id": 1, "method": "sidecar.status", "params": {}}

// 响应（服务端→客户端）：有 id（匹配请求）
{"id": 1, "result": {"running": true}}

// 错误响应：有 id + error
{"id": 1, "error": {"code": -32601, "message": "method not found"}}

// 推送事件（服务端→客户端）：有 event，无 id
{"event": "transcription.progress", "data": {"job_id": "xxx", "progress": 42}}
```

### 推送事件（初期支持）

| 事件名 | 触发条件 | data 字段 |
|--------|---------|-----------|
| `transcription.progress` | 转写进度变更 | `job_id`, `progress`, `stage` |
| `transcription.completed` | 转写完成 | `job_id`, `meeting_id`, `state` |
| `asr.warm.state_changed` | ASR 预热状态变化 | `engine`, `state`, `ready` |

## Python 端改动

### server.py — 连接处理改造

`_handle_conn` 改为双模式：

```python
def _handle_conn(self, conn):
    with conn:
        reader = conn.makefile("rb")
        first_line = reader.readline()
        if not first_line:
            return
        first_msg = json.loads(first_line)
        if "insightkit" in first_msg:
            self._handle_persistent(conn, reader, first_msg)
        else:
            self._handle_legacy(conn, first_msg)
```

`_handle_legacy` — 旧逻辑（recv 剩余数据 → dispatch → sendall → close），行为与现有完全一致。

`_handle_persistent` — 新增：
1. 发送握手确认
2. 注册到 push_broker
3. 循环 `reader.readline()` 读取请求
4. dispatch 后写回 `json + \n`
5. 连接断开时从 push_broker 注销

### 新文件：insightkit/ipc/push_broker.py

管理所有活跃长连接客户端，提供推送能力：

```python
class PushBroker:
    def __init__(self):
        self._clients: dict[int, socket.socket] = {}  # fd → conn
        self._lock = threading.Lock()

    def register(self, conn: socket.socket) -> None: ...
    def unregister(self, conn: socket.socket) -> None: ...
    def emit(self, event: str, data: dict) -> None: ...
```

`emit()` 向所有注册客户端发送 `{"event": ..., "data": ...}\n`。发送失败时静默移除该客户端。

### job_queue.py — 接入推送

`_update_progress` 和 `_worker_loop` 中调用 `push_broker.emit()` 发送进度/完成事件。

## Swift 端改动

### 新文件：Services/RPCTransport.swift

管理持久化 Unix socket 连接：

- `connect()` — 建立连接 + 发送握手
- `send(request:)` — 发送请求，返回 `id`
- `receive()` — 从缓冲区读取下一条完整消息
- `disconnect()` — 关闭连接
- 请求/响应匹配：维护 `pendingRequests: [Int: CheckedContinuation]`
- 推送事件回调：`onEvent: ((String, [String: Any]) -> Void)?`
- 自动重连：连接断开后自动重建（指数退避）
- 读取循环在专用 `DispatchQueue` 上运行

### 新文件：Services/RPCCodec.swift

用 Codable 替代手动 `[String: Any]` 解析：

```swift
struct RPCRequest<P: Encodable>: Encodable {
    let id: Int
    let method: String
    let params: P
}

struct RPCResponse<R: Decodable>: Decodable {
    let id: Int?
    let result: R?
    let error: RPCErrorPayload?
}

struct RPCEvent: Decodable {
    let event: String
    let data: AnyCodable  // 或用具体类型
}
```

为高频方法定义类型化请求/响应：

```swift
// 示例：sidecar.status
struct SidecarStatusResult: Decodable {
    let running: Bool
    let pid: Int
    let version: String
    let build: String
    let socketPath: String
    let uptimeSec: Int
    let liveSessions: Int
    let ready: Bool
    // ...
}
```

### 改造：InsightRPCClient.swift

- `callSync` 改为通过 RPCTransport 发送（长连接模式）
- 保留 `InsightRPCClientProtocol` 接口不变
- 逐步将 decode 方法替换为 Codable 解码
- 保留 circuit breaker 和 retry 逻辑

## 测试策略

### Python 端

- `tests/test_persistent_conn.py` — 握手、多请求序列、推送事件接收、旧模式兼容
- `tests/test_push_broker.py` — 注册/注销、emit 广播、断连清理
- 现有 77+ 测试全部通过（短连接路径不变）

### Swift 端

- `RPCTransportTests.swift` — 连接、重连、帧解析、推送回调
- `RPCCodecTests.swift` — Codable 编解码正确性
- 现有 27 测试全部通过

### 冒烟测试

`scripts/smoke_test_rpc.py` 增加长连接测试路径。

## 验收标准

- 所有现有 Python 测试（77+）通过
- 所有现有 Swift 测试（27）通过
- 新增测试覆盖长连接 + 推送 + Codable
- 实时转录场景 RPC 延迟降低（对比旧短连接模式）
- 向后兼容：旧短连接调用仍正常工作
