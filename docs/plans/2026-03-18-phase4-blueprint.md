# Phase 4 前端交互重设计 — 实施蓝图

日期：2026-03-18
设计文档：`docs/plans/2026-03-18-phase4-frontend-redesign.md`
仓库：`YannJY02/AutoTranscribe` (main)
工作流：Git 分支 + PR

## 依赖图

```
Step 1 (设计系统)
  ↓
Step 2 (协议层)
  ↓
Step 3 (骨架组件)
  ↓
Step 4 (首页 + 路由)
  ↓
Step 5a (视频采集基础设施)
  ↓
Step 5b (实时转写视图层)
  ↓
Step 5c (实时转写 ViewModel)
  ↓
Step 6 (导入转写)
  ↓
Step 7 (记录管理)
  ↓
Step 8 (集成测试与清理)
```

注意：Step 5 拆分为 5a/5b/5c 三个子步骤（审查发现原 Step 5 过大）。
Step 5 和 Step 6 改为串行（审查发现共享 ContentView.swift、WorkflowCoordinator.swift、TranscriptStreamView.swift）。

## 审查修复记录

基于对抗性审查（2026-03-18）修复以下问题：
- CRITICAL-01：MediaPlayerView 合并到 VideoPlayerView（同时支持视频+纯音频波形）
- CRITICAL-02：TranscriptionSessionViewModel 删除前移到 Step 6，明确级联引用更新
- CRITICAL-03/04：取消 Step 5/6 并行，改为串行
- CRITICAL-05：Step 5a 增加 ScreenCaptureKit 权限处理
- HIGH-01：设计文档中 AudioCaptureService 实为 MicCaptureService + SystemAudioCaptureService
- HIGH-02：BottomStatusBarView 加入 Step 1 和 Step 6 改造清单
- HIGH-04/05：Step 5/6 上下文简报补充扩展文件和线程模型信息
- HIGH-06：Step 5 拆分为 5a/5b/5c
- HIGH-07：Step 5a 明确线程模型
- HIGH-08：SessionShell 增加 HSplitView 备选方案说明
- MEDIUM-01：Step 7 增加缩略图生成逻辑
- MEDIUM-02：Step 2 不动 WorkflowRoute，推迟到 Step 4
- MEDIUM-03：Step 1 列出完整引用更新文件清单

---

## Step 1：设计系统重写

分支：`phase4/step1-design-system`
模型层级：default
预计文件：1 重写 + 9 引用更新
回滚：`git revert`

### 上下文简报

InsightKit 是 macOS SwiftUI 应用，源码位于 `macos/InsightKitApp/Sources/InsightKitApp/`。当前设计系统定义在 `Theme.swift`（47行），包含暖色调色板（背景 #F3EEE0、面板 #FBFAF8、强调色 #5A80A8）、14pt 圆角、`QuietCardModifier`。

Phase 4 要求切换到 Notion 冷灰白风格，并扩展设计系统覆盖字体、间距、阴影、动效。

### 任务

1. 完全重写 `Theme.swift`，替换为新色板：
   - 背景层次：canvas `#F0F0EF`、surface `#FFFFFF`、surfaceAlt `#F7F6F3`、elevated `#FFFFFF`
   - 文字：textPrimary `#37352F`、textSecondary `#787774`、textTertiary `#B4B4B0`
   - 强调色：accent `#2F80ED`、accentHover `#2B6CC4`、accentLight `#E8F0FE`、accentMuted `#F0F5FF`
   - 边框：border `#E8E8E8`、borderLight `#F0F0EF`、borderFocus `#2F80ED`
   - 状态色：success `#0F7B6C`、warning `#CB912F`、error `#E03E3E`、recording `#E03E3E`
   - 圆角降为 8pt
2. 新增 `InsightTypography` enum（title 20pt semibold、heading 16pt semibold、body 14pt regular、bodyMedium 14pt medium、caption 12pt regular、small 11pt regular、transcript 14pt、noteBody 14pt、noteTimestamp 11pt medium）
3. 新增 `InsightSpacing` enum（xs 4、sm 8、md 12、lg 16、xl 24、xxl 32、panelPadding 20、cardPadding 16、panelGap 1）
4. 新增 `InsightShadow` enum（card、cardHover、elevated）
5. 新增 `InsightAnimation` enum（phaseTransition、listAppear、hover、sheetPresent、chapterAppend、noteHighlight、recordingPulse）
6. 更新 `QuietCardModifier` 使用新色值和 8pt 圆角
7. 添加 `Color(hex:)` 扩展（如果不存在）
8. 全局搜索所有引用旧 `InsightTheme` 属性名的文件，逐一更新：
   - `background` → `canvas`：WorkflowHomeView.swift (L12), LiveWorkspaceView.swift
   - `panel` → `surface`：Theme.swift QuietCardModifier (L28)
   - `panelElevated` → `elevated`：WorkflowHomeView.swift (L12, L33, L89)
   - 完整受影响文件清单：WorkflowHomeView.swift, LiveWorkspaceView.swift, TranscriptionWorkspaceView.swift, ContentView.swift, BottomStatusBarView.swift, InsightWorkbenchView.swift, ExecutionPanelView.swift, TranscriptStreamView.swift, SettingsView.swift, SystemAudioPickerSheet.swift

### 验证

```bash
cd macos/InsightKitApp && swift build 2>&1 | tail -20
```

### 退出标准

- `swift build` 零错误
- 所有旧色值引用已更新
- 无硬编码颜色值（grep 验证）

---

## Step 2：面板解耦协议层

分支：`phase4/step2-protocols`
依赖：Step 1
模型层级：default
预计文件：2 新增、1 改造
回滚：`git revert`

### 上下文简报

Phase 4 的三栏布局（章节摘要 | 视频+转写 | 笔记）要求每个面板通过 Protocol 解耦，不直接依赖 ViewModel。这样面板可独立测试、独立替换，且 Live/Import/Records 三个工作区可复用同一套面板组件。

当前代码中 `UIModels.swift` 定义了路由和状态枚举。需要扩展路由、新增面板协议、新增支撑数据模型。

### 任务

1. 新建 `Protocols/PanelDataSources.swift`，定义三个协议：
   ```swift
   protocol ChapterSidebarDataSource: ObservableObject {
       var chapters: [ChapterSummary] { get }
       var smartMinutes: SmartMinutes? { get }
       var canGenerateMinutes: Bool { get }
       func onChapterTapped(_ chapter: ChapterSummary)
       func onGenerateMinutes()
   }

   protocol CenterStageDataSource: ObservableObject {
       var phase: SessionPhase { get }
       var capturePreview: CapturePreviewProvider? { get }
       var transcriptEntries: [TranscriptEntry] { get }
       var recordingDuration: TimeInterval { get }
       var mediaURL: URL? { get }
       func onStartRecording()
       func onStopRecording()
       func onPauseRecording()
       func onTranscriptEntryTapped(_ entry: TranscriptEntry)
       func onSeek(to time: TimeInterval)
   }

   protocol NotesEditorDataSource: ObservableObject {
       var notes: [TimestampedNote] { get }
       var currentPlaybackTime: TimeInterval? { get }
       var isEditable: Bool { get }
       func onNoteCreated(_ text: String, at time: TimeInterval)
       func onNoteUpdated(_ note: TimestampedNote)
       func onNoteTapped(_ note: TimestampedNote)
   }
   ```
2. 新建 `Models/PhaseModels.swift`，定义支撑类型：
   ```swift
   enum SessionPhase { case preparing, running, postSession, reviewing }
   struct ChapterSummary: Identifiable { ... }
   struct SmartMinutes: Identifiable { ... }
   struct TimestampedNote: Identifiable { ... }
   protocol CapturePreviewProvider { ... }
   ```
3. 改造 `UIModels.swift`：
   - `WorkspacePhase` 新增 `.liveReviewing`、`.importSelecting`、`.importProcessing`、`.importReviewing`
   - 保持向后兼容（旧 case 保留，标记 deprecated 或映射）
   - 注意：`WorkflowRoute` 的新增 case（`.importMedia`、`.records`）推迟到 Step 4，避免 ContentView.swift switch 编译断裂

### 验证

```bash
cd macos/InsightKitApp && swift build 2>&1 | tail -20
```

### 退出标准

- `swift build` 零错误
- 三个 Protocol 定义完整，所有方法签名与设计文档一致
- WorkspacePhase 包含新增 case

---

## Step 3：骨架组件

分支：`phase4/step3-shell-components`
依赖：Step 2
模型层级：default
预计文件：9 新增
回滚：`git revert`

### 上下文简报

Step 2 定义了面板协议和数据模型。本步骤创建 `SessionShell` 泛型三栏骨架和所有共享面板组件的空壳实现，确保编译通过但不含业务逻辑。

源码目录：`macos/InsightKitApp/Sources/InsightKitApp/`。需要新建 `Views/Components/` 子目录。

注意：HSplitView 在 macOS 上存在已知问题（分隔条拖拽不稳定、minWidth 约束不严格、不支持动画过渡）。SessionShell 应考虑备选方案：使用 `GeometryReader` + `HStack` + 自定义拖拽分隔条，或保留 HSplitView 但增加 `.layoutPriority()` 确保中栏优先级最高。对于 RecordsView 的嵌套场景（双栏内嵌三栏预览），内层三栏不使用 HSplitView，改用固定比例 HStack。

### 任务

1. 新建 `Views/Components/SessionShell.swift`：
   - 泛型 `<Left: View, Center: View, Right: View>`
   - HSplitView 三栏，左 260-360pt、中 480pt+、右 280-380pt
   - 背景色使用 InsightTheme
   - 中栏 `.layoutPriority(1)` 确保优先分配空间
   - 提供 `SessionShellFixed` 变体（HStack 固定比例，用于嵌套场景）
2. 新建 `Views/Components/ChapterSidebarView.swift`：
   - 接收 `any ChapterSidebarDataSource`
   - 空壳：显示章节列表占位 + 智能纪要区域占位
3. 新建 `Views/Components/TimestampNotesEditor.swift`：
   - 接收 `any NotesEditorDataSource`
   - 空壳：Markdown 编辑区占位 + 时间戳显示
4. 新建 `Views/Components/SourceToggleBar.swift`：
   - 四个输入源 toggle（麦克风、摄像头、屏幕、系统音频）
   - 点击切换开关，长按/右键弹出设备选择（占位）
5. 新建 `Views/Components/SmartMinutesSheet.swift`：
   - 会后弹窗，显示纪要内容列表 + 跳过/生成按钮
6. 新建 `Views/Components/FileDropZoneView.swift`：
   - 拖放区域 + 文件选择按钮
   - 支持格式提示
7. 新建 `Views/Components/TranscriptionProgressView.swift`：
   - 进度条 + 百分比 + 已转写时长
8. 新建 `Views/Components/RecordSearchBar.swift`：
   - 搜索输入框，Notion 风格
9. 新建 `Views/Components/MediaPlayerView.swift`：
   - NSViewRepresentable 包装 `AVPlayer`
   - 同时支持视频播放和纯音频波形可视化（根据媒体类型自动切换）
   - 播放控制：播放/暂停、进度条、时间显示
   - seek 回调：点击进度条或外部调用跳转
   - 使用 `Coordinator` 持有 AVPlayer 实例，避免随 SwiftUI view 重建
   - 空壳：基本框架 + AVPlayer 初始化，详细实现在 Step 5a

### 验证

```bash
cd macos/InsightKitApp && swift build 2>&1 | tail -20
```

### 退出标准

- `swift build` 零错误
- 所有 9 个组件文件存在且可编译
- SessionShell 正确使用 HSplitView + InsightTheme 背景色 + layoutPriority
- SessionShellFixed 变体使用 HStack 固定比例
- 每个组件有基本的 SwiftUI Preview

---

## Step 4：首页改造

分支：`phase4/step4-home`
依赖：Step 3
模型层级：default
预计文件：4 改造、1 新增
回滚：`git revert`

### 上下文简报

当前 `WorkflowHomeView.swift`（97行）显示 2 张卡片（实时语音总结、转写总结），使用旧暖色调。需要改为 3 卡片 + 最近记录列表，Notion 风格。

`ContentView.swift` 是主容器，route switch 分发视图。`WorkflowCoordinator.swift` 管理路由和状态。两者都需要新增 `.importMedia` 和 `.records` 路由分支。

注意：`WorkflowRoute` 的新增 case 在本步骤完成（Step 2 推迟了此改动），同时在 `ContentView.swift` 中添加占位分支，确保编译通过。

### 任务

1. 改造 `UIModels.swift`：
   - `WorkflowRoute` 新增 `.importMedia` 和 `.records` case
2. 重写 `Views/WorkflowHomeView.swift`：
   - 3 张等宽卡片：实时转写（音频+视频）、导入转写（音频+视频）、转写记录（标签管理）
   - 每张卡片：SF Symbol 图标（32pt 灰色）、标题、副标题、操作按钮
   - 卡片样式：白底 `surface`、1px `border` 边框、hover 微弱阴影、8pt 圆角
   - 下方"最近记录"区域：紧凑列表，最多 3 条，显示文件夹名+标签 pill+时长
   - 背景改为 `canvas`，移除渐变
   - 新增回调：`onOpenImport`、`onOpenRecords`
3. 改造 `ContentView.swift`：
   - route switch 新增 `.importMedia` → 占位视图（Step 6 实现）
   - route switch 新增 `.records` → 占位视图（Step 7 实现）
   - 更新 toolbar 和 banner 逻辑中对旧 `.transcription` case 的引用
4. 改造 `ViewModels/WorkflowCoordinator.swift`：
   - 新增 `openImport()` 方法
   - 新增 `openRecords()` 方法
   - 更新 route 切换逻辑
5. 新增 `Services/RecordsIndexService.swift` 空壳：
   - 预定义完整接口（供 Step 5/6 调用）：
     ```swift
     func recentRecords(limit: Int) -> [RecordMetadata]  // 首页最近记录
     func saveRecord(_ metadata: RecordMetadata, at path: URL)  // 保存记录
     func deleteRecord(id: String)  // 删除记录
     func searchRecords(query: String) -> [RecordMetadata]  // 全文搜索
     func filterRecords(tags: [String], type: MediaType?) -> [RecordMetadata]  // 筛选
     var rootDirectory: URL { get set }  // 存储根目录
     ```
   - 所有方法返回空数组或空操作（Step 7 填充实现）

### 验证

```bash
cd macos/InsightKitApp && swift build 2>&1 | tail -20
```

### 退出标准

- `swift build` 零错误
- 首页显示 3 张卡片
- 点击每张卡片正确切换路由
- 最近记录区域存在（即使数据为空）

---

## Step 5a：视频采集基础设施

分支：`phase4/step5a-video-capture`
依赖：Step 4
模型层级：strongest（涉及 AVFoundation + ScreenCaptureKit）
预计文件：2 新增
回滚：`git revert`

### 上下文简报

InsightKit 当前只有音频采集能力。音频管线架构：
- `MicCaptureService.swift`：麦克风采集，使用 `AVCaptureSession` + `AVAudioEngine`
- `SystemAudioCaptureService.swift`：系统音频采集，使用 `ScreenCaptureKit` 的音频流
- `AudioMixBus.swift`：混合麦克风和系统音频
- `ChunkAssembler.swift`：将音频流切分为固定大小的 chunk
- `LiveASRService.swift`：将 chunk 发送到 Python sidecar 进行 ASR

现有 ViewModel 使用专用 GCD 队列 `pipelineQueue` 处理音频缓冲区。

本步骤新增视频采集服务和视频预览组件，作为纯基础设施层，可独立测试。

### 任务

1. 新建 `Services/VideoCaptureService.swift`：
   - 摄像头采集：`AVCaptureSession` + `AVCaptureDeviceInput` + `AVCaptureVideoDataOutput`
   - 屏幕捕获：`SCShareableContent` + `SCStream`（ScreenCaptureKit）
   - 设备枚举：列出可用摄像头（`AVCaptureDevice.DiscoverySession`）和可共享屏幕/窗口（`SCShareableContent.excludingDesktopWindows`）
   - 录制输出：`AVAssetWriter` 写入 mp4 文件
   - 预览帧提供：通过 `AVCaptureVideoDataOutput` delegate 或 `SCStreamOutput` 提供帧
   - 与音频采集同步：共享 `CMClock` 时间基准
   - 线程模型：
     - `AVCaptureSession` 配置和启停在专用 `captureSessionQueue` 上执行
     - 视频帧回调在 `videoOutputQueue` 上处理
     - `AVAssetWriter` 输入追加在 writer 专用队列上执行
     - 所有 Published 属性更新通过 `DispatchQueue.main.async`
   - ScreenCaptureKit 权限处理：
     - 检查屏幕录制权限状态
     - 首次调用时触发系统权限请求
     - 权限被拒时提供 `openScreenRecordingSettings()` 方法引导到系统偏好设置
     - 确认 `Info.plist` 中存在 `NSScreenCaptureUsageDescription`
   - 摄像头权限处理：
     - 延迟请求：仅在用户激活摄像头 toggle 时请求 `AVCaptureDevice.requestAccess(for: .video)`
     - 权限被拒时在 UI 显示引导
2. 新建 `Views/Components/VideoPreviewView.swift`：
   - NSViewRepresentable 包装 `AVCaptureVideoPreviewLayer`
   - 支持切换摄像头/屏幕捕获预览源
   - REC 指示灯 overlay（红点脉冲 + 时长文字）
   - 使用 `Coordinator` 持有 `AVCaptureVideoPreviewLayer` 实例，避免随 SwiftUI view identity 变化重建
   - 在 `updateNSView` 中处理数据源切换，而非重建整个 NSView

### 验证

```bash
cd macos/InsightKitApp && swift build 2>&1 | tail -20
```

单元测试：
- VideoCaptureService 设备枚举返回非空列表（有摄像头时）
- 权限检查方法正确返回状态

### 退出标准

- `swift build` 零错误
- VideoCaptureService 可独立初始化和枚举设备
- VideoPreviewView 可在 SwiftUI Preview 中渲染（空白预览）
- 权限请求流程完整（检查→请求→拒绝引导）

---

## Step 5b：实时转写视图层

分支：`phase4/step5b-live-views`
依赖：Step 5a
模型层级：default
预计文件：2 新增、2 改造
回滚：`git revert`

### 上下文简报

Step 5a 完成了视频采集基础设施（VideoCaptureService + VideoPreviewView）。Step 3 创建了 SessionShell 骨架和面板组件空壳（ChapterSidebarView、TimestampNotesEditor、SourceToggleBar、MediaPlayerView 等）。

本步骤创建 LiveCenterView（实时转写中栏）并重写 LiveWorkspaceView，将三栏组装起来。此时 ViewModel 层尚未改造，视图使用 mock 数据源。

现有 `TranscriptStreamView.swift` 位于 `macos/InsightKitApp/Sources/InsightKitApp/TranscriptStreamView.swift`（注意不在 Views/ 子目录），需要适配新的数据源接口。

### 任务

1. 新建 `Views/Components/LiveCenterView.swift`：
   - 接收 `any CenterStageDataSource`
   - 根据 phase 切换内容：
     - preparing：VideoPreviewView + SourceToggleBar + 开始录制按钮
     - running：VideoPreviewView（带 REC 指示灯）+ TranscriptStreamView + 停止/暂停按钮
     - postSession：触发 SmartMinutesSheet
     - reviewing：MediaPlayerView + 转写全文（可搜索、点击跳转）+ 导出/返回按钮
2. 重写 `Views/LiveWorkspaceView.swift`：
   - 使用 SessionShell 组装三栏
   - 暂时使用 mock 数据源（Step 5c 接入真实 ViewModel）
3. 改造 `TranscriptStreamView.swift`：
   - 适配新的 `[TranscriptEntry]` 数据源
   - 点击条目回调时间戳
   - 保持向后兼容（旧接口标记 deprecated）
4. 完善 Step 3 创建的 `MediaPlayerView.swift` 空壳：
   - 实现 AVPlayer 包装的完整逻辑
   - 视频播放 + 纯音频波形可视化自动切换
   - 播放控制、进度条、seek 回调
   - Coordinator 持有 AVPlayer 实例

### 验证

```bash
cd macos/InsightKitApp && swift build 2>&1 | tail -20
```

### 退出标准

- `swift build` 零错误
- LiveWorkspaceView 使用 SessionShell 三栏布局
- LiveCenterView 四个 phase 的 UI 切换正常（使用 mock 数据）
- MediaPlayerView 可播放本地视频文件

---

## Step 5c：实时转写 ViewModel 层

分支：`phase4/step5c-live-viewmodel`
依赖：Step 5b
模型层级：strongest
预计文件：2 改造
回滚：`git revert`

### 上下文简报

Step 5b 完成了视图层（LiveCenterView + LiveWorkspaceView 重写），使用 mock 数据源。本步骤改造 LiveSessionViewModel 及其扩展，接入真实数据。

`LiveSessionViewModel.swift`（561行）是核心 ViewModel，4 个扩展文件：
- `LiveSessionViewModel+Capture.swift`（~362行）：音频采集管线核心，管理 MicCaptureService、SystemAudioCaptureService、AudioMixBus、ChunkAssembler 的生命周期和数据流
- `LiveSessionViewModel+Warmup.swift`：ASR 引擎预热生命周期管理
- `LiveSessionViewModel+Insight.swift`：洞察刷新（调用 RPC insight.refresh_live / insight.build_final）
- `LiveSessionViewModel+Runtime.swift`：运行时环境检查和诊断

现有 ViewModel 使用专用 GCD 队列 `pipelineQueue` 执行阻塞 RPC I/O，通过 `DispatchQueue.main.async` 回调更新 UI。新改造必须沿用此模式，不要使用 Swift structured concurrency 调用 RPC 方法。

### 任务

1. 改造 `ViewModels/LiveSessionViewModel.swift`：
   - 新增 `sessionPhase: SessionPhase` published 属性
   - 实现 `ChapterSidebarDataSource` 适配（chapters 数组、smartMinutes、实时更新）
   - 实现 `CenterStageDataSource` 适配（phase、capturePreview、transcriptEntries、录制控制）
   - 实现 `NotesEditorDataSource` 适配（notes 数组、时间戳绑定、当前播放时间）
   - 新增笔记管理：`notes: [TimestampedNote]`，每个字符绑定输入时刻的 `recordingDuration`
   - 新增章节摘要管理：`chapters: [ChapterSummary]`，从 RPC insight.refresh_live 响应中提取
   - 暴露三个数据源属性供 LiveWorkspaceView 使用
2. 改造 `ViewModels/LiveSessionViewModel+Capture.swift`：
   - 集成 VideoCaptureService（Step 5a 创建）
   - 音视频同步启停：startSession 时同时启动音频和视频采集
   - 视频录制输出路径管理
   - 录制完成后保存到 Records 目录（调用 RecordsIndexService.saveRecord 空壳）

### 验证

```bash
cd macos/InsightKitApp && swift build 2>&1 | tail -20
```

手动验证：
- 启动应用 → 进入实时转写 → Green Room 显示摄像头预览
- 切换输入源 toggle → 预览正确切换
- 开始录制 → 视频预览 + 转写文本流同时工作
- 停止录制 → 弹出智能纪要弹窗
- 进入 reviewing → 视频可回放、转写文本可点击跳转

### 退出标准

- `swift build` 零错误
- 四个 phase 切换正常，使用真实数据
- 视频预览（摄像头 + 屏幕捕获）正常显示
- 音视频同步录制输出 mp4 文件
- 面板通过 Protocol 解耦，不直接引用 ViewModel
- LiveSessionViewModel 行数 < 800 行（含新增逻辑）

---

## Step 6：导入转写工作区

分支：`phase4/step6-import-workspace`
依赖：Step 5c
模型层级：default
预计文件：3 新增、4 改造、2 删除
回滚：`git revert`（注意：本步骤删除 2 个文件，revert 可恢复）

### 上下文简报

当前 `Views/TranscriptionWorkspaceView.swift` 使用 HSplitView 三栏：左 job 列表+导入控件、中 InsightWorkbenchView、右 ExecutionPanelView。需要完全替换为 `ImportWorkspaceView`，使用 SessionShell 骨架，三栏：ChapterSidebarView | ImportCenterView | TimestampNotesEditor。

`TranscriptionSessionViewModel.swift`（699行）管理转写 job 队列和文件监听。需要简化为单文件导入流程，改造为 `ImportSessionViewModel`。

阶段状态机：selecting → processing → reviewing。

关键架构约束：现有 ViewModel 使用专用 GCD 队列 `rpcQueue` 执行阻塞 RPC I/O，通过 `DispatchQueue.main.async` 回调更新 UI，使用 `fetchLock` 防重入。新 `ImportSessionViewModel` 必须沿用此模式，不要使用 Swift structured concurrency 调用 RPC 方法。

级联引用说明：`WorkflowCoordinator.swift` 第 12 行持有 `transcriptionViewModel: TranscriptionSessionViewModel`。`ContentView.swift` 多处引用 `coordinator.transcriptionViewModel`。`BottomStatusBarView.swift` 引用 `transcriptionPhase` 和 `transcriptionViewModel`。本步骤必须同时更新所有这些引用。

### 任务

1. 新建 `Views/Components/ImportCenterView.swift`：
   - 接收 `any CenterStageDataSource`
   - 根据 phase 切换：
     - selecting：FileDropZoneView（拖放 + 点击选择，支持 mp3/m4a/wav/mp4/mov/mkv）
     - processing：MediaPlayerView（上部，可边播放边等待）+ TranscriptionProgressView（中部）+ 转写文本实时追加（下部）
     - reviewing：MediaPlayerView + 转写全文 + 导出/返回按钮 + "在访达中显示"按钮
2. 新建 `Views/ImportWorkspaceView.swift`：
   - 使用 SessionShell 组装三栏
   - 从 ImportSessionViewModel 获取三个面板数据源
3. 新建 `ViewModels/ImportSessionViewModel.swift`：
   - 基于现有 `TranscriptionSessionViewModel` 简化
   - 移除 job 队列和文件监听逻辑
   - 单文件导入流程：选择文件 → 调用 RPC 转写 → 接收进度 → 完成
   - 实现三个面板 Protocol 适配器
   - 管理 sessionPhase（selecting/processing/reviewing）
   - 笔记管理：时间戳绑定播放时间点
   - 转写完成后一次性生成章节摘要
   - 沿用 GCD `rpcQueue` + `DispatchQueue.main.async` 模式
4. 改造 `ContentView.swift`：
   - `.importMedia` 路由分支从占位视图替换为 `ImportWorkspaceView`
   - 更新所有 `coordinator.transcriptionViewModel` 引用为 `coordinator.importViewModel`
   - 更新 banner 逻辑中对旧 `.transcription` case 的引用
5. 改造 `ViewModels/WorkflowCoordinator.swift`：
   - `importViewModel: ImportSessionViewModel` 替换 `transcriptionViewModel: TranscriptionSessionViewModel`
   - 更新 init、bridgeChildObjectChanges、bindStates 中的引用
   - 更新 `transcriptionPhase` → `importPhase`
   - 更新所有能力检查（canBuildTranscriptionFinal → canBuildImportFinal 等）
6. 改造 `Views/BottomStatusBarView.swift`：
   - 更新对 `transcriptionPhase`、`transcriptionViewModel` 的引用
   - `.transcription` 分支改为 `.importMedia`
7. 删除 `Views/TranscriptionWorkspaceView.swift`
8. 删除 `ViewModels/TranscriptionSessionViewModel.swift`

### 验证

```bash
cd macos/InsightKitApp && swift build 2>&1 | tail -20
```

手动验证：
- 首页 → 导入转写 → 显示文件拖放区
- 拖入视频文件 → 播放器显示 + 转写进度条
- 转写完成 → 章节摘要填充 + 智能纪要弹窗
- reviewing → 视频回放 + 笔记高亮跟随

### 退出标准

- `swift build` 零错误
- 三个 phase 切换正常
- 文件拖放和选择器正常工作
- 转写进度实时更新
- 面板通过 Protocol 解耦

---

## Step 7：转写记录管理

分支：`phase4/step7-records`
依赖：Step 6
模型层级：default
预计文件：7 新增、2 改造
回滚：`git revert`

### 上下文简报

Phase 4 新增转写记录管理功能。记录以文件夹形式平铺存储在用户指定的根目录下（默认 `~/Documents/InsightKit/Records/`），每个文件夹包含 metadata.json、recording.mp4/m4a、transcript.json、notes.md、minutes.json。

RecordsView 采用双栏布局：左侧筛选栏（搜索+标签+类型+自动标签）、右侧主内容区（列表/卡片视图，选中后切换为三栏预览）。三栏预览复用 SessionShell + 所有面板组件。

### 任务

1. 新建 `Models/RecordMetadata.swift`：
   - `RecordMetadata` struct（id、createdAt、duration、mediaType、source、userTags、autoTags、summaryPreview）
   - `MediaType` enum（audio/video）
   - `RecordSource` enum（live/imported）
   - JSON Codable 支持
2. 完善 `Services/RecordsIndexService.swift`（Step 4 创建的空壳）：
   - 扫描根目录，解析每个子文件夹的 metadata.json
   - 建立内存索引
   - 标签管理：获取所有标签、新增标签、删除标签
   - 筛选：按标签、类型、时间范围
   - 全文搜索：搜索转写文本、笔记、纪要内容
   - 存储根目录配置（UserDefaults，默认 ~/Documents/InsightKit/Records/）
   - `recentRecords(limit:)` 实现
   - 缩略图生成：视频文件使用 `AVAssetImageGenerator` 提取首帧，纯音频生成波形缩略图，异步生成并缓存到记录文件夹内 `thumbnail.png`
3. 新建 `Views/RecordsView.swift`：
   - 双栏布局：NavigationSplitView 或 HSplitView
   - 左侧 RecordsSidebarView
   - 右侧：未选中时显示记录列表/卡片，选中后显示三栏预览
   - 三栏预览使用 SessionShell + RecordReviewDataSource
4. 新建 `Views/Components/RecordsSidebarView.swift`：
   - 搜索框
   - 全部记录计数
   - 用户标签 pills（多选筛选）
   - 类型筛选 radio（全部/音频/视频）
   - 自动标签（本周/本月/更早）
   - 新建标签按钮
5. 新建 `Views/Components/RecordListItemView.swift`：
   - 类型图标 + 文件夹名 + 元信息 + 标签 pills + 摘要预览
   - hover 操作按钮
   - 右键菜单（打开、在访达中显示、编辑标签、删除）
6. 新建 `Views/Components/RecordGridItemView.swift`：
   - 缩略图（视频首帧/音频波形）+ 名称 + 时长 + 标签
7. 新建 `ViewModels/RecordReviewDataSource.swift`：
   - 从文件夹加载数据
   - 适配 ChapterSidebarDataSource、CenterStageDataSource、NotesEditorDataSource
   - 笔记可编辑，自动保存回文件夹
   - 无智能纪要时提供"现在生成"能力
8. 改造 `ContentView.swift`：
   - `.records` 路由分支从占位视图替换为 `RecordsView`
9. 改造 `Views/SettingsView.swift`：
   - 新增存储根目录选择器
   - "在 Finder 中打开"按钮
   - 存储空间统计

### 验证

```bash
cd macos/InsightKitApp && swift build 2>&1 | tail -20
```

手动验证：
- 首页 → 转写记录 → 显示记录列表
- 标签筛选正常工作
- 搜索返回匹配结果
- 点击记录 → 三栏预览正常显示
- 笔记可编辑并自动保存
- "在访达中显示"打开正确文件夹

### 退出标准

- `swift build` 零错误
- 记录列表/卡片视图切换正常
- 标签筛选和全文搜索正常
- 三栏预览复用 SessionShell 和面板组件
- 笔记编辑自动保存

---

## Step 8：集成测试与清理

分支：`phase4/step8-integration`
依赖：Step 7
模型层级：default
预计文件：3 删除、若干修复
回滚：`git revert`

### 上下文简报

Steps 1-7 完成后，所有新功能已实现。本步骤进行全流程集成测试、删除废弃文件、修复遗留问题。

需要删除的废弃文件：
- `InsightWorkbenchView.swift`（6-tab 系统，被 ChapterSidebarView 替代）
- `ExecutionPanelView.swift`（被 ChapterSidebarView 替代）

注意：`TranscriptionWorkspaceView.swift` 和 `TranscriptionSessionViewModel.swift` 已在 Step 6 删除。

### 任务

1. 删除废弃文件：
   - `InsightWorkbenchView.swift`
   - `ExecutionPanelView.swift`
   - 确认 `TranscriptionWorkspaceView.swift` 已在 Step 6 删除
   - 确认 `TranscriptionSessionViewModel.swift` 已在 Step 6 删除
2. 全局搜索清理：
   - grep 所有对已删除文件/类型的引用，修复或移除
   - grep 硬编码颜色值，替换为 InsightTheme
   - grep 旧 InsightTheme 属性名（background、panel、panelElevated），确认全部更新
3. 全流程测试：
   - 首页 → 3 卡片显示正确，最近记录加载
   - 实时转写完整流程：Green Room → 录制 → 停止 → 智能纪要 → 回看
   - 导入转写完整流程：文件选择 → 转写 → 智能纪要 → 回看
   - 记录管理：列表/卡片切换、标签筛选、搜索、三栏预览
   - 跨功能：实时转写完成后在记录管理中可见
   - 笔记时间戳：录制中记笔记 → 回看时点击跳转 → 播放时自动高亮
4. 边界情况：
   - 无摄像头设备时的 Green Room 降级
   - 屏幕捕获权限未授予时的提示
   - 空记录目录时的空状态显示
   - 大文件导入时的内存和性能
   - 存储目录不存在或无写入权限时的错误处理
5. 性能检查：
   - 视频预览帧率是否流畅
   - 转写文本流自动滚动是否卡顿
   - 记录列表大量记录时的滚动性能

### 验证

```bash
cd macos/InsightKitApp && swift build 2>&1 | tail -20
# 确认零 warning（除第三方库）
```

### 退出标准

- `swift build` 零错误、零新增 warning
- 所有废弃文件已删除，无悬空引用
- 四条主流程（首页、实时、导入、记录）全部走通
- 无硬编码颜色值
- 边界情况有合理的错误处理或降级

---

## 不变量（每个 Step 完成后验证）

1. `swift build` 零错误
2. 现有功能不回退（音频采集、RPC 通信、ASR 转写）
3. 所有颜色通过 InsightTheme 引用，无硬编码
4. 面板组件通过 Protocol 解耦，不直接依赖 ViewModel
5. 文件行数 < 400 行（新文件）、< 800 行（改造文件）

## 计划变更协议

如需修改本蓝图：
- **拆分步骤**：在原步骤后插入子步骤（如 5a、5b），更新依赖图
- **跳过步骤**：标记为 SKIPPED + 原因，确认下游步骤不受影响
- **插入步骤**：分配新编号，更新依赖图
- **放弃步骤**：标记为 ABANDONED + 原因，回滚已完成的部分
