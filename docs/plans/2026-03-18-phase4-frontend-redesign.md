# Phase 4：前端交互重设计

日期：2026-03-18
状态：已确认
依赖：Phase 1-3 完成

## 概述

InsightKit 前端从文本转写工具升级为完整的音视频会议记录平台。核心变化：

- 新增视频采集能力（摄像头 + 屏幕捕获）
- 三栏工作区：章节摘要+智能纪要 | 视频+转写 | 时间戳笔记
- 废弃 InsightWorkbench 6-tab 系统，用章节摘要 + 智能纪要替代
- 新增转写记录管理（标签筛选 + 全文搜索）
- 设计风格从暖色调切换到 Notion 冷灰白

## 架构方案：混合方案（方案 C）

轻量 `SessionShell` 提供三栏骨架布局，具体内容通过 ViewBuilder 注入，由 `LiveWorkspaceView` 和 `ImportWorkspaceView` 各自组装。

```swift
struct SessionShell<Left: View, Center: View, Right: View>: View {
    let left: Left
    let center: Center
    let right: Right

    var body: some View {
        HSplitView {
            left.frame(minWidth: 260, maxWidth: 360)
                .background(InsightTheme.surface)
            center.frame(minWidth: 480)
                .background(InsightTheme.surfaceAlt)
            right.frame(minWidth: 280, maxWidth: 380)
                .background(InsightTheme.surface)
        }
        .background(InsightTheme.canvas)
    }
}
```

优势：
- 布局一致性由 SessionShell 保证，不承担业务逻辑
- 各 workspace 保持独立，不互相污染
- 共享组件自然复用
- 与现有架构改造摩擦最小

---

## 1. 首页 HomeView

### 布局

三张等宽卡片水平排列 + 最近记录列表：

```
┌──────────────────────────────────────────────────────┐
│                    InsightKit                         │
│                                                      │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐           │
│  │ 实时转写  │  │ 导入转写  │  │ 转写记录  │           │
│  │ 音频+视频 │  │ 音频+视频 │  │ 标签管理  │           │
│  └──────────┘  └──────────┘  └──────────┘           │
│                                                      │
│  最近记录（最多3条）                                    │
│  ┌─────────────────────────────────────┐             │
│  │ 2026_3_18_01_video  标签: 周会  32min│             │
│  │ 2026_3_17_03_audio  标签: 访谈  18min│             │
│  └─────────────────────────────────────┘             │
└──────────────────────────────────────────────────────┘
```

### 路由

```swift
enum WorkflowRoute {
    case home
    case live          // 实时转写
    case importMedia   // 导入转写
    case records       // 转写记录
}
```

### 改造点

- `WorkflowHomeView.swift`：从 2 卡片扩展为 3 卡片 + 最近记录列表
- `WorkflowCoordinator`：新增 `openImport()` 和 `openRecords()`
- `ContentView.swift`：route switch 新增 `.importMedia` 和 `.records`
- `UIModels.swift`：WorkflowRoute 新增两个 case

---

## 2. 实时转写工作区 LiveWorkspaceView

### 阶段状态机

```
preparing → running → postSession → reviewing
```

### preparing 阶段 — Green Room

中栏主体为摄像头实时预览，下方一排图标 toggle 按钮：

```
┌─────────────┬────────────────────────────┬──────────────┐
│  章节摘要     │   ┌──────────────────────┐  │   笔记        │
│  (空状态)    │   │   摄像头实时预览画面    │  │  (空状态)     │
│             │   └──────────────────────┘  │              │
│             │   🎤  📷  🖥️  🔊          │              │
│             │   on  on  off  on          │              │
│             │       [ ● 开始录制 ]        │              │
└─────────────┴────────────────────────────┴──────────────┘
```

输入源 toggle 交互：
- 🎤 麦克风（默认开）、📷 摄像头（默认开）、🖥️ 屏幕捕获（默认关）、🔊 系统音频（默认关）
- 点击 = 开关切换，长按/右键 = 弹出设备选择下拉菜单
- 激活态 `accent` 蓝色，关闭态 `textTertiary` 灰色
- 摄像头关闭 + 屏幕捕获开启 → 预览区显示屏幕缩略图
- 全部关闭（纯音频）→ 预览区显示音频电平波形

### running 阶段

```
┌─────────────┬────────────────────────────┬──────────────┐
│  章节摘要     │  ┌──────────────────────┐  │   笔记编辑器   │
│ ▸ 00:00     │  │   视频预览画面         │  │  每字符绑定    │
│   开场介绍   │  │  ● REC 03:42         │  │  录制时间戳    │
│ ▸ 03:15     │  └──────────────────────┘  │              │
│   技术方案   │  实时转写文本流             │  ┌──────────┐ │
│             │  ┌──────────────────────┐  │  │需要调研公 │ │
│             │  │张三: 我觉得这个方案.. │  │  │司背景资料 │ │
│             │  │李四: 对，第一个是..   │  │  └──────────┘ │
│             │  └──────────────────────┘  │  03:42 ⏱     │
│             │  ■ 停止  ⏸ 暂停           │              │
└─────────────┴────────────────────────────┴──────────────┘
```

- 中栏上半：视频预览 + REC 指示灯 + 时长
- 中栏下半：转写文本流，自动滚动，发言人标识
- 左栏：章节摘要实时更新，点击跳转转写文本
- 右栏：Markdown 笔记，每字符绑定输入时刻的录制时间戳

### postSession 阶段

录制停止后弹出 sheet：

```
┌─────────────────────────────┐
│   录制已完成 (32:15)         │
│   是否生成智能纪要？          │
│                             │
│   智能纪要将包含：            │
│   · 结构化总结               │
│   · 会议金句                 │
│   · 发言人总结               │
│   · 关键决策                 │
│   · 待办事项                 │
│   · 智能章节                 │
│                             │
│   [ 跳过 ]    [ 生成纪要 ]   │
└─────────────────────────────┘
```

### reviewing 阶段

- 中栏：视频回放播放器 + 完整转写文本（点击句子跳转视频）
- 左栏：章节摘要 + 智能纪要各模块（可折叠）
- 右栏：笔记随播放进度自动高亮滚动
- 底部：导出（PDF/Markdown）、返回首页

### 面板解耦

所有面板通过 Protocol 解耦：

```swift
protocol ChapterSidebarDataSource {
    var chapters: [ChapterSummary] { get }
    var smartMinutes: SmartMinutes? { get }
    func onChapterTapped(_ chapter: ChapterSummary)
}

protocol CenterStageDataSource {
    var phase: SessionPhase { get }
    var capturePreview: CapturePreviewProvider? { get }
    var transcriptEntries: [TranscriptEntry] { get }
    var recordingDuration: TimeInterval { get }
    func onStartRecording()
    func onStopRecording()
    func onTranscriptEntryTapped(_ entry: TranscriptEntry)
}

protocol NotesEditorDataSource {
    var notes: [TimestampedNote] { get }
    var currentPlaybackTime: TimeInterval? { get }
    func onNoteCreated(_ text: String, at time: TimeInterval)
    func onNoteTapped(_ note: TimestampedNote)
}
```

组装：

```swift
struct LiveWorkspaceView: View {
    @ObservedObject var viewModel: LiveSessionViewModel

    var body: some View {
        SessionShell(
            left: ChapterSidebarView(dataSource: viewModel.chapterDataSource),
            center: LiveCenterView(dataSource: viewModel.centerDataSource),
            right: TimestampNotesEditor(dataSource: viewModel.notesDataSource)
        )
    }
}
```

---

## 3. 导入转写工作区 ImportWorkspaceView

### 阶段状态机

```
selecting → processing → reviewing
```

### selecting 阶段

中栏为拖放区域 + 文件选择按钮：

```
┌─────────────┬────────────────────────────┬──────────────┐
│  章节摘要     │   ┌────────────────────┐   │   笔记        │
│  (空状态)    │   │  📁                │   │  (空状态)     │
│             │   │  拖放文件到此处      │   │              │
│             │   │  或点击选择         │   │              │
│             │   └────────────────────┘   │              │
│             │   支持: mp3 m4a wav        │              │
│             │         mp4 mov mkv        │              │
│             │       [ 选择文件 ]          │              │
└─────────────┴────────────────────────────┴──────────────┘
```

### processing 阶段

- 中栏上部：媒体播放器（视频显示视频，纯音频显示波形），可边播放边等待
- 中栏中部：转写进度条（百分比 + 已转写时长）
- 中栏下部：已转写文本实时追加
- 右栏笔记已激活，时间戳绑定播放时间点
- 左栏空状态，转写完成后一次性生成章节摘要

### 转写完成后

1. 左栏一次性填充章节摘要
2. 弹出 SmartMinutesSheet
3. 进入 reviewing 阶段（与实时转写 reviewing 一致）

### 面板复用

```swift
struct ImportWorkspaceView: View {
    @ObservedObject var viewModel: ImportSessionViewModel

    var body: some View {
        SessionShell(
            left: ChapterSidebarView(dataSource: viewModel.chapterDataSource),
            center: ImportCenterView(dataSource: viewModel.centerDataSource),
            right: TimestampNotesEditor(dataSource: viewModel.notesDataSource)
        )
    }
}
```

### 与现有代码关系

- `TranscriptionWorkspaceView` → 完全重写为 `ImportWorkspaceView`
- `TranscriptionSessionViewModel` → 改造为 `ImportSessionViewModel`
- 现有 job 列表/watcher 功能移除，简化为单文件拖放

---

## 4. 转写记录管理 RecordsView

### 布局：侧栏 + 主内容区（master-detail）

```
┌──────────────────┬───────────────────────────────────┐
│  侧栏 (260pt)     │  主内容区                          │
│                  │                                   │
│  🔍 搜索          │  未选中记录时：列表/卡片视图          │
│  全部记录 (24)    │  选中记录后：三栏预览                │
│                  │                                   │
│  标签筛选         │                                   │
│  ┌────┐┌────┐   │                                   │
│  │周会 ││访谈 │   │                                   │
│  └────┘└────┘   │                                   │
│  + 新建标签      │                                   │
│                  │                                   │
│  类型筛选         │                                   │
│  ○ 全部 ○ 音频    │                                   │
│  ○ 视频          │                                   │
│                  │                                   │
│  自动标签         │                                   │
│  ┌─────┐┌────┐  │                                   │
│  │本周  ││本月 │  │                                   │
│  └─────┘└────┘  │                                   │
└──────────────────┴───────────────────────────────────┘
```

### 记录列表项

每条记录显示：类型图标、文件夹名、元信息（时长·类型·日期）、标签 pills、摘要预览。
支持列表/卡片两种视图模式切换。

### 记录预览（点击卡片后）

复用 SessionShell 三栏布局，在 RecordsView 内展示：

```
┌──────────────────┬───────────────────────────────────────────┐
│  侧栏 (筛选)      │ ┌─────────┬──────────────┬─────────┐      │
│                  │ │ 智能纪要  │  视频 + 转录   │  笔记   │      │
│  🔍 搜索          │ │ 章节摘要 │  ▶ 播放器     │  可编辑  │      │
│  ...             │ │ 总结     │  转写全文      │  自动保存│      │
│                  │ │ 金句     │  点击跳转      │  高亮跟随│      │
│  ● 当前选中:      │ │ 决策     │              │         │      │
│  2026_3_18_01    │ │ 待办     │ [ 在访达中显示 ]│         │      │
│                  │ └─────────┴──────────────┴─────────┘      │
└──────────────────┴───────────────────────────────────────────┘
```

- 三栏复用 `SessionShell` + 所有面板组件，reviewing 只读模式
- 笔记可编辑，自动保存回文件夹
- 侧栏保持可见，可快速切换记录
- 中栏底部"在访达中显示"按钮（`NSWorkspace.shared.selectFile()`）
- 无智能纪要的记录，左栏显示"现在生成纪要"按钮

### 预览面板读写权限

| 面板 | 模式 |
|------|------|
| 左栏 章节摘要 | 只读 |
| 左栏 智能纪要 | 只读（可补充生成） |
| 中栏 视频/音频 | 播放 |
| 中栏 转写文本 | 只读，点击跳转 |
| 右栏 笔记 | 可编辑，自动保存 |

### 搜索

覆盖范围：转写文本、笔记、智能纪要、文件夹名、标签名。
搜索结果高亮匹配文本，点击进入 reviewing 定位到匹配位置。

### 存储结构

```
~/Documents/InsightKit/Records/     ← 可自定义根目录
├── 2026_3_18_01_video/
│   ├── metadata.json
│   ├── recording.mp4
│   ├── transcript.json
│   ├── notes.md
│   └── minutes.json
├── 2026_3_17_03_audio/
│   ├── metadata.json
│   ├── recording.m4a
│   ├── transcript.json
│   ├── notes.md
│   └── minutes.json
└── ...
```

### 数据模型

```swift
struct RecordMetadata: Codable {
    let id: String                    // 文件夹名即 ID
    let createdAt: Date
    let duration: TimeInterval
    let mediaType: MediaType          // .audio / .video
    let source: RecordSource          // .live / .imported
    var userTags: [String]
    var autoTags: [String]
    var summaryPreview: String?
}

enum MediaType: String, Codable { case audio, video }
enum RecordSource: String, Codable { case live, imported }
```

---

## 5. 设计系统

### 色彩（Notion 风格冷灰白）

```swift
enum InsightTheme {
    // 背景层次
    static let canvas      = Color(hex: "#F0F0EF")  // 最底层
    static let surface     = Color(hex: "#FFFFFF")  // 面板/卡片
    static let surfaceAlt  = Color(hex: "#F7F6F3")  // 次级面板
    static let elevated    = Color(hex: "#FFFFFF")  // 弹窗/浮层

    // 文字
    static let textPrimary   = Color(hex: "#37352F")
    static let textSecondary = Color(hex: "#787774")
    static let textTertiary  = Color(hex: "#B4B4B0")

    // 强调色
    static let accent      = Color(hex: "#2F80ED")
    static let accentHover = Color(hex: "#2B6CC4")
    static let accentLight = Color(hex: "#E8F0FE")
    static let accentMuted = Color(hex: "#F0F5FF")

    // 边框
    static let border      = Color(hex: "#E8E8E8")
    static let borderLight = Color(hex: "#F0F0EF")
    static let borderFocus = Color(hex: "#2F80ED")

    // 状态色
    static let success   = Color(hex: "#0F7B6C")
    static let warning   = Color(hex: "#CB912F")
    static let error     = Color(hex: "#E03E3E")
    static let recording = Color(hex: "#E03E3E")

    // 圆角与间距
    static let cornerRadius: CGFloat = 8
    static let cardPadding: CGFloat = 16
    static let panelGap: CGFloat = 1
}
```

### 字体

```swift
enum InsightTypography {
    static let title       = Font.system(size: 20, weight: .semibold)
    static let heading     = Font.system(size: 16, weight: .semibold)
    static let body        = Font.system(size: 14, weight: .regular)
    static let bodyMedium  = Font.system(size: 14, weight: .medium)
    static let caption     = Font.system(size: 12, weight: .regular)
    static let small       = Font.system(size: 11, weight: .regular)
    static let transcript  = Font.system(size: 14, weight: .regular)
    static let noteBody    = Font.system(size: 14, weight: .regular)
    static let noteTimestamp = Font.system(size: 11, weight: .medium)
}
```

行高：正文 1.6、标题 1.3、转写文本 1.7、笔记 1.6。

### 间距

```swift
enum InsightSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let panelPadding: CGFloat = 20
    static let cardPadding: CGFloat = 16
    static let panelGap: CGFloat = 1
}
```

### 圆角

- 按钮（pill）: 20pt
- 卡片/面板: 8pt
- 输入框: 6pt
- 标签 pill: 4pt

### 阴影

```swift
enum InsightShadow {
    static let card      = Shadow(color: .black.opacity(0.04), radius: 2, y: 1)
    static let cardHover = Shadow(color: .black.opacity(0.08), radius: 8, y: 2)
    static let elevated  = Shadow(color: .black.opacity(0.12), radius: 16, y: 4)
}
```

### 动效

| 场景 | 动效 | 时长 |
|------|------|------|
| phase 切换 | crossfade | 0.25s |
| 章节摘要新增 | 滑入 + fade in | 0.2s |
| 转写文本追加 | 即时，自动滚动 | — |
| 笔记时间高亮 | 背景渐变 accentLight | 0.3s |
| 记录切换预览 | crossfade | 0.2s |
| 弹窗 | spring 弹出 | 0.3s |
| 标签筛选 | fade + 重排 | 0.2s |
| REC 指示灯 | 脉冲呼吸 | 0.8s 循环 |
| hover 卡片 | 阴影提升 | 0.12s |

### 图标

统一 SF Symbols。尺寸：16pt（工具栏）、20pt（卡片）、32pt（首页入口）。
激活态 `accent` 蓝色，非激活跟随文字层级。

### 暗色模式

Phase 4 不实现，但所有颜色通过 InsightTheme 集中管理，禁止硬编码，为后续预留。

---

## 6. 文件清单

### 新增文件

**Views:**
- `Views/Components/SessionShell.swift` — 泛型三栏骨架
- `Views/Components/ChapterSidebarView.swift` — 左栏：章节摘要 + 智能纪要
- `Views/Components/TimestampNotesEditor.swift` — 右栏：Markdown 笔记编辑器
- `Views/Components/LiveCenterView.swift` — 实时转写中栏
- `Views/Components/ImportCenterView.swift` — 导入转写中栏
- `Views/Components/VideoPreviewView.swift` — 摄像头/屏幕预览 (NSViewRepresentable)
- `Views/Components/VideoPlayerView.swift` — AVPlayer 回放 (NSViewRepresentable)
- `Views/Components/MediaPlayerView.swift` — 通用媒体播放器
- `Views/Components/SourceToggleBar.swift` — 输入源图标 toggle 栏
- `Views/Components/SmartMinutesSheet.swift` — 会后弹窗
- `Views/Components/FileDropZoneView.swift` — 文件拖放选择区
- `Views/Components/TranscriptionProgressView.swift` — 转写进度条
- `Views/ImportWorkspaceView.swift` — 导入转写工作区
- `Views/RecordsView.swift` — 记录管理主视图
- `Views/Components/RecordsSidebarView.swift` — 记录侧栏筛选
- `Views/Components/RecordListItemView.swift` — 记录列表项
- `Views/Components/RecordGridItemView.swift` — 记录卡片项
- `Views/Components/RecordSearchBar.swift` — 搜索栏

**ViewModels:**
- `ViewModels/ImportSessionViewModel.swift` — 导入转写 ViewModel

**Models:**
- `Models/RecordMetadata.swift` — 记录元数据模型

**Services:**
- `Services/VideoCaptureService.swift` — 视频采集管线（摄像头 + 屏幕捕获）
- `Services/RecordsIndexService.swift` — 文件系统扫描 + 索引 + 全文搜索

**Protocols:**
- `Protocols/PanelDataSources.swift` — 面板解耦协议

### 改造文件

- `Theme.swift` — 完全重写色板 + 新增 Typography/Spacing/Shadow/Animation
- `UIModels.swift` — WorkflowRoute 新增 `.importMedia` / `.records`
- `WorkflowHomeView.swift` — 3 卡片 + 最近记录列表
- `LiveWorkspaceView.swift` — 重写，使用 SessionShell 组装
- `LiveSessionViewModel.swift` — 新增 phase 状态机、视频采集、面板数据源适配
- `ContentView.swift` — route switch 新增分支
- `WorkflowCoordinator.swift` — 新增路由方法
- `AudioCaptureService.swift` — 与视频采集协调同步

### 删除文件

- `Views/TranscriptionWorkspaceView.swift` — 被 ImportWorkspaceView 替代
- `Views/InsightWorkbenchView.swift` — 6-tab 系统废弃
- `Views/ExecutionPanelView.swift` — 被 ChapterSidebarView 替代

---

## 7. 实施顺序建议

1. **设计系统** — Theme.swift 重写（色彩、字体、间距、动效）
2. **协议层** — PanelDataSources.swift 定义面板解耦协议
3. **骨架组件** — SessionShell + 各面板组件空壳
4. **首页** — HomeView 改造（3 卡片 + 路由）
5. **实时转写** — LiveWorkspaceView 重写 + VideoCaptureService
6. **导入转写** — ImportWorkspaceView + ImportSessionViewModel
7. **记录管理** — RecordsView + RecordsIndexService
8. **集成测试** — 全流程走通 + 边界情况处理
