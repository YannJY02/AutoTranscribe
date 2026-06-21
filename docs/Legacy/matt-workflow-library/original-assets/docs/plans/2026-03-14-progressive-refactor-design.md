# InsightKit 渐进式重构设计文档

日期：2026-03-14
状态：已确认

## 背景

InsightKit 从自动转录脚本演变为 macOS 产品应用，开发过程中积累了以下结构性问题：

- `server.py` 单文件 1300+ 行，职责过载
- `LiveSessionViewModel.swift` 1800+ 行，状态管理复杂
- `Models.swift` 850 行，所有模型堆在一个文件
- IPC 层每次调用创建新 socket 连接，实时场景效率低
- Swift 端手动解析 `[String: Any]`，无类型安全
- 打包依赖 conda 环境，分发困难
- 前端交互逻辑混乱，WorkflowCoordinator 职责过载

## 方案选择

**选定方案：渐进式重构（方案 A）**

保留 SwiftUI + Python sidecar 双进程架构，自底向上分层修复。

否决方案：
- 全 Swift 重写：工作量 3-4 倍，且失去 FunASR 中文 ASR 优势
- 换框架重写（Electron/Tauri）：失去 native 体验，系统音频采集支持差

## 重构阶段

### Phase 1：Python sidecar 拆分

**目标：** 把 `server.py` 拆成职责清晰的模块，不改 RPC 协议，Swift 端零改动。

**拆分方案：**

```
insightkit/ipc/
├── server.py          # 瘦入口：socket 监听 + 请求路由（<200 行）
├── session_handler.py # session.start / session.stop / transcript.delta / transcript.list
├── asr_dispatcher.py  # asr.runtime.* / asr.prewarm / asr.transcribe_chunk
├── job_queue.py       # transcription.import_file / transcription.status / transcription.cancel_job
├── insight_coord.py   # insight.refresh_live / insight.build_final / document.export
└── watch_bridge.py    # transcription.watch.start / transcription.watch.stop（已存在）
```

**验收标准：**
- 所有现有 51 个 Python 测试通过
- 新增每个模块的单元测试（目标覆盖率 80%+）
- RPC 协议不变，Swift 端无需任何修改

**测试路径：**
```bash
# 自动化回归
python3 -m pytest tests/ -x --tb=short

# RPC 冒烟测试（新增）
python3 scripts/smoke_test_rpc.py

# 手动验证：启动 sidecar 确认所有方法可调用
python3 scripts/insight_sidecar.py
```

---

### Phase 2：IPC 层升级

**目标：** 从短连接 JSON-RPC 改为长连接，引入类型安全。

**Python 端改动：**
- server.py 支持长连接模式：客户端连接后保持，用换行符分隔 JSON 消息
- 向后兼容：同时支持短连接（旧客户端）和长连接（新客户端）

**Swift 端改动：**
- 新建 `Services/RPCTransport.swift`：管理长连接、自动重连、消息帧解析
- 新建 `Services/RPCCodec.swift`：用 Codable 替代手动 `[String: Any]` 解析
- `InsightRPCClient.swift` 改为调用 RPCTransport，不再直接操作 socket

**验收标准：**
- Swift 测试 + Python 测试全量通过
- 实时转录场景 RPC 延迟降低（对比 BottomStatusBar debug 面板的 latencyMs）

**测试路径：**
```bash
# 终端 1：启动 sidecar
python3 scripts/insight_sidecar.py

# 终端 2：构建并运行 app
swift build --package-path macos/InsightKitApp
./macos/InsightKitApp/.build/debug/InsightKitApp

# 自动化回归
python3 -m pytest tests/ -x --tb=short
swift test --package-path macos/InsightKitApp
```

---

### Phase 3：Swift 状态管理重构

**目标：** 拆分巨型 ViewModel，简化状态管理。

**拆分方案：**

```
ViewModels/
├── LiveSessionViewModel.swift      # 瘦身：仅保留 session 生命周期
├── LiveCaptureController.swift     # 音频采集 + chunk 管理
├── LiveASRController.swift         # ASR 预热 + 转写调度
├── LiveInsightController.swift     # insight 刷新 + 展示
├── TranscriptionSessionViewModel.swift  # 保持（已较合理）
└── WorkflowCoordinator.swift       # 瘦身：仅路由 + 子 VM 协调

Models/
├── TranscriptModels.swift          # TranscriptSegment, EvidenceRange
├── InsightModels.swift             # InsightPackageV1, WorkbenchItem, InsightTab
├── SessionModels.swift             # CaptureState, SessionHandle, Metrics
├── TranscriptionModels.swift       # TranscriptionJob, TranscriptionJobState
├── ProviderModels.swift            # ProviderVendor, ProviderProfile, ProbeResult
├── RuntimeModels.swift             # ASR 相关状态模型
└── UIModels.swift                  # BannerMessage, BottomStatusPayload, WorkflowRoute
```

**验收标准：**
- Swift 测试全量通过
- UI 行为与重构前一致

**测试路径：**
```bash
# 自动化回归
swift test --package-path macos/InsightKitApp

# 手动验证：同 Phase 2 的启动方式，走查核心流程
```

---

### Phase 4：前端交互重设计

**目标：** 重新设计导航流程和状态展示，对齐飞书妙记的交互模式。

**改动范围：**
- 重新设计 WorkflowHomeView：清晰的入口卡片（实时转录 / 导入转录）
- 实时转录流程：准备 → 录制中 → 会后定稿，每个阶段有明确的 UI 状态
- 导入转录流程：选择文件 → 处理中（进度条）→ 总结定稿
- 统一错误展示和恢复引导
- SettingsView 简化：减少暴露给用户的技术细节

**验收标准：**
- 完整用户流程走查通过
- 启动 → 实时转录 → 停止 → 总结 → 导出
- 导入文件 → 转录 → 总结 → 导出

**测试路径：**
```bash
# 自动化回归
swift test --package-path macos/InsightKitApp

# 手动 E2E 走查（用真实音频文件）
# 1. 启动 sidecar + app
# 2. 走查实时转录全流程
# 3. 走查导入转录全流程
```

---

### Phase 5：打包与分发

**目标：** 生成可双击运行的 .app，无需用户安装 Python/conda。

**方案：**
- 用 PyInstaller 把 Python sidecar + 所有依赖打成单个可执行文件
- 嵌入 .app bundle 的 `Contents/Resources/` 目录
- Swift 端的 SidecarManager 改为从 bundle 内启动 sidecar 二进制
- 代码签名 + notarization

**验收标准：**
- `scripts/package_insightkit_app.sh` 产出的 .app 可在干净 macOS 上双击运行
- 实时转录和导入转录全流程正常

**测试路径：**
```bash
# 打包
bash scripts/package_insightkit_app.sh --clean

# 在干净环境测试（或当前机器）
open dist/macos/InsightKit.app

# 全流程 E2E 走查
```

## 通用开发期测试命令

每个阶段都可以用以下命令快速验证：

```bash
# Python 回归
python3 -m pytest tests/ -x --tb=short

# Swift 回归
swift test --package-path macos/InsightKitApp

# 启动完整系统（两个终端）
# 终端 1:
python3 scripts/insight_sidecar.py
# 终端 2:
swift build --package-path macos/InsightKitApp && ./macos/InsightKitApp/.build/debug/InsightKitApp
```

## 风险与缓解

| 风险 | 缓解措施 |
|------|----------|
| Phase 2 长连接引入新 bug | 向后兼容短连接，可随时回退 |
| Phase 3 拆分 ViewModel 导致 UI 回归 | 先写测试再拆分，每步验证 |
| Phase 5 PyInstaller 打包 FunASR 模型体积大 | 模型按需下载，不打入 bundle |
| 跨阶段依赖导致某阶段阻塞 | 每阶段独立可交付，可跳过或并行 |
