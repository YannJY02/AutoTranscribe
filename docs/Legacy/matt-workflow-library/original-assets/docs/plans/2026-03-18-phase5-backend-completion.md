# Phase 5 Blueprint：后端补全（以前端为基础）

> 目标：Phase 4 完成了 Swift 前端全部 8 步重构。本 Blueprint 补全 Python sidecar 后端，使前端新功能真正可用。

## 依赖图

```
Step 1 (记录持久化管线 + records.save RPC)
  ↓
Step 2 (实时录制集成) ─────→ Step 4 (笔记持久化)
  ↓                              ↓
Step 3 (导入流程补全) ─────→ Step 5 (记录回看接通 RPC)
  ↓
Step 6 (记录搜索 RPC，可选)
  ↓
Step 7 (集成测试与清理)
```

Step 2 和 Step 3 串行（共享 `transcription_runner.py` 和记录写出逻辑）。
Step 4 依赖 Step 2（需要 `saveToRecords` 方法存在）。
Step 5 依赖 Step 3（需要导入流程完成）。
Step 4 和 Step 5 可并行。
Step 6 可选，依赖 Step 1-3。
Step 7 依赖所有前置步骤。

## 审查修复记录

基于对抗性审查（2026-03-18 Opus）修复以下问题：
- CRITICAL-01：metadata.json 日期格式强制使用 `Z` 后缀（`strftime("%Y-%m-%dT%H:%M:%SZ")`），不使用 `isoformat()`
- CRITICAL-02：Step 1 明确要求 `run_transcription_job` 返回值包含 `record_path`
- CRITICAL-03：统一走 Python `RecordWriter`（新增 `records.save` RPC），消除 Swift/Python 双写出逻辑
- HIGH-01：Step 2 拆分 `saveToRecords` 为独立扩展 `LiveSessionViewModel+Records.swift`，控制文件行数
- HIGH-02：纯音频录制改为复用现有 ChunkAssembler 的 WAV 临时文件拼接，不引入 AVAudioFile/AAC 编码
- HIGH-03：Step 3 明确 `transcriptList` 调用在 `rpcQueue` 上执行
- HIGH-04：Step 4 依赖改为 Step 2（不再标记可并行）
- HIGH-05：Step 2 预计文件加入 `WorkflowCoordinator.swift`
- HIGH-06：`RecordReviewDataSource.onGenerateMinutes` 从 Step 7 清理项提升为 Step 5 独立步骤

## 差距分析

| # | 前端期望 | 后端现状 | 差距 |
|---|---------|---------|------|
| G1 | `RecordReviewDataSource` 从文件夹读 `metadata.json`、`transcript.json`、`minutes.json` | `transcription_runner.py` 完成后只写 SQLite，不写文件 | 缺少记录文件夹写出管线 |
| G2 | `LiveSessionViewModel+Capture` 期望录制视频保存到记录文件夹 | `VideoCaptureService.startRecording` 存在但未被调用 | 缺少实时录制→记录文件夹集成 |
| G3 | `ImportSessionViewModel` 轮询 `transcription.status` 获取进度 | 后端 `PushBroker` 已有推送但前端未使用 | 可优化但非阻塞（轮询可工作） |
| G4 | `RecordsIndexService.searchRecords` 搜索 `summaryPreview` 和标签 | 转写文本在 SQLite FTS 中，`transcript.json` 不存在 | 需要写出 `transcript.json` |
| G5 | `TimestampedNote` 在实时/导入流程中只存内存 | `RecordReviewDataSource` 期望从 `notes.md` 读取 | 缺少笔记持久化到记录文件夹 |
| G6 | `RecordReviewDataSource.onGenerateMinutes` 是空壳 | 后端 `insight.build_final` RPC 存在但未被记录回看调用 | 需要接通 RPC |

---

## Step 1：记录持久化管线 + records.save RPC

分支：`phase5/step1-record-persistence`
模型层级：default
预计文件：3 新增（Python）、2 改造（Python）
回滚：`git revert`

### 上下文简报

前端 `RecordReviewDataSource`（`macos/.../ViewModels/RecordReviewDataSource.swift`）从记录文件夹加载数据：
- `metadata.json` → `RecordMetadata`（id, createdAt, duration, mediaType, source, userTags, autoTags, summaryPreview）
- `transcript.json` → `[{start_ms, end_ms, speaker, text}]`
- `minutes.json` → `{structured_summary, highlights, key_decisions, action_items}`
- `notes.md` → 每行 `MM:SS text`
- `recording.mp4` 或 `recording.m4a` → 媒体文件

前端 `RecordsIndexService`（`macos/.../Services/RecordsIndexService.swift`）使用 `JSONDecoder` 的 `.iso8601` 策略解码日期。Swift `ISO8601DateFormatter` 默认只接受 `Z` 后缀（如 `2026-03-18T12:00:00Z`），不接受 `+00:00`。Python `datetime.isoformat()` 生成 `+00:00` 后缀，会导致解码失败。

后端 `transcription_runner.py`（`scripts/transcription_runner.py`）完成转写后返回 `{meeting_id, title, source_path, segments_count, insight_package}`，只写 SQLite，不写文件夹。

### 任务

1. 新建 `insightkit/records/__init__.py`（空）
2. 新建 `insightkit/records/record_writer.py`：
   - `RecordWriter` 类，负责将转写结果写出为记录文件夹
   - 日期格式强制使用 `datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")`，绝不使用 `isoformat()`
   - `write_record(root_dir, meeting_id, title, source_path, segments, insight_package, media_type, record_source, duration_sec) -> Path`：
     - 创建 `{root_dir}/{meeting_id}/` 文件夹
     - 写出 `metadata.json`（字段与 Swift `RecordMetadata` 完全对齐）：
       ```json
       {
         "id": "<meeting_id>",
         "createdAt": "2026-03-18T12:00:00Z",
         "duration": 123.4,
         "mediaType": "audio",
         "source": "imported",
         "userTags": [],
         "autoTags": ["<从 insight_package.session_overview.topics 提取>"],
         "summaryPreview": "<insight_package.session_overview.overview 前 200 字>"
       }
       ```
     - 写出 `transcript.json`：`[{start_ms, end_ms, speaker, text}]`
     - 写出 `minutes.json`：
       ```json
       {
         "structured_summary": "<session_overview.overview>",
         "highlights": ["<highlight_insights[].quote>"],
         "key_decisions": ["<decision_ledger[].decision>"],
         "action_items": ["<action_tracks[].task>"]
       }
       ```
     - 写出空 `notes.md`
     - 复制源媒体文件为 `recording.{ext}`（优先硬链接，失败则 `shutil.copy2`）
     - 返回记录文件夹 Path
   - `detect_media_type(file_path) -> str`：视频扩展名 `.mp4/.mov/.mkv/.avi/.webm` → `"video"`，其余 → `"audio"`
   - `detect_duration(file_path) -> float`：优先从 segments 最大 `end_ms` 推算（`max(end_ms) / 1000.0`），作为零依赖 fallback；如果 `mutagen` 可用则使用它
   - 边界处理：`insight_package` 为 None 或缺少字段时，`minutes.json` 写空结构 `{}`，`autoTags` 和 `summaryPreview` 为空
3. 改造 `scripts/transcription_runner.py`：
   - 导入 `RecordWriter`
   - 在 `progress(100, "completed")` 之前调用 `RecordWriter().write_record(...)`
   - 传入 `record_source="imported"`
   - 记录根目录：`os.getenv("INSIGHTKIT_RECORDS_ROOT", "~/Documents/InsightKit/Records/")`
   - **将 `write_record` 返回的路径加入返回字典**：`result["record_path"] = str(record_folder_path)`
4. 新增 `records.save` RPC（供 Swift 前端调用，统一写出逻辑）：
   - 在 `insightkit/ipc/server.py` 的 `_dispatch` handlers 中注册 `"records.save"`
   - 参数：`meeting_id, title, source_path, segments, insight_package, media_type, record_source, duration_sec, notes_md`
   - 调用 `RecordWriter().write_record(...)` + 可选写入 `notes.md`
   - 返回 `{record_path, ok}`
   - 在 `module.capabilities` 的 `actions` 列表中添加 `"records.save"`
5. 新增测试 `tests/test_record_writer.py`：
   - 测试 `write_record` 生成正确的文件夹结构
   - 测试 `metadata.json` 的 `createdAt` 以 `Z` 结尾（不是 `+00:00`）
   - 测试 `insight_package` 为 None 时的边界处理
   - 测试硬链接失败时 fallback 到复制

### 验证

```bash
cd /Users/yann.jy/Developer/Projects/transcription
python -m pytest tests/test_record_writer.py -v
```

### 退出标准

- 所有测试通过
- `metadata.json` 的 `createdAt` 使用 `Z` 后缀
- `transcription_runner.py` 返回值包含 `record_path`
- `records.save` RPC 可被 Swift 前端调用
- `RecordWriter` 处理 `insight_package=None` 不崩溃

---

## Step 2：实时录制→记录文件夹集成

分支：`phase5/step2-live-record-save`
依赖：Step 1
模型层级：strongest（涉及 AVFoundation 录制 + RPC 调用编排）
预计文件：1 新增（Swift）、3 改造（Swift）
回滚：`git revert`

### 上下文简报

`LiveSessionViewModel`（`macos/.../ViewModels/LiveSessionViewModel.swift`，~601 行）管理实时转写会话。其 `+Capture` 扩展（`LiveSessionViewModel+Capture.swift`，~362 行）处理音频采集管线。

`VideoCaptureService`（`macos/.../Services/VideoCaptureService.swift`，435 行）已实现 `startRecording(to:)` 和 `stopRecording()`，使用 `AVAssetWriter` 写入 mp4。但 `LiveSessionViewModel+Capture` 从未调用这些方法。

`LiveSessionViewModel.swift` 第 ~100 行已有 `let videoCaptureService = VideoCaptureService()`，无需新增。但没有 `RecordsIndexService` 引用——需要从 `WorkflowCoordinator` 传入。

实时会话结束时（`stopLiveSession`），ViewModel 调用 `session.stop` RPC 和 `insight.build_final` RPC，但不会保存记录文件夹。

关键架构决策（CRITICAL-03 修复）：实时流程也通过 `records.save` RPC 调用 Python `RecordWriter`，不在 Swift 端本地写出 JSON 文件。这确保导入和实时两条路径使用同一套写出逻辑，格式永远一致。

纯音频录制方案（HIGH-02 修复）：不引入 `AVAudioFile` + AAC 编码。改为在 `stopLiveSession` 时，将 `ChunkAssembler` 产出的 WAV 临时文件按时间顺序拼接为一个完整 WAV 文件（使用 `AVAudioFile` 顺序写入 PCM 数据，无需编码转换）。如果有视频源，则使用 `VideoCaptureService` 的 mp4 输出。

### 任务

1. 新建 `ViewModels/LiveSessionViewModel+Records.swift`（HIGH-01 修复：独立扩展控制行数）：
   - `saveToRecords()` 方法：
     - 确定媒体文件路径：有视频 → 临时 mp4 路径；无视频 → 拼接 WAV 临时文件
     - 从 `transcriptSegments` 构建 segments 数组（`[[String: Any]]` 格式）
     - 从 `smartMinutesData` 和 `notes` 构建附加数据
     - 在 `rpcQueue` 上调用 `records.save` RPC（传入 meeting_id、segments、insight_package、media_path、notes_md）
     - RPC 返回后在 `DispatchQueue.main.async` 中更新 UI 状态
     - 调用 `recordsService.refreshIndex()`
   - `concatenateWAVChunks(meetingID:) -> URL?`：将临时 WAV 文件拼接为完整文件
2. 改造 `LiveSessionViewModel+Capture.swift`：
   - 在 `startLiveSession` 中（音频采集启动后）：
     - 如果视频源已激活：生成临时路径，调用 `videoCaptureService.startRecording(to: outputURL)`
     - 保留 WAV 临时文件路径列表（ChunkAssembler 已产出的）
   - 在 `stopLiveSession` 中（音频采集停止后）：
     - 调用 `videoCaptureService.stopRecording()`
     - 进入 postSession 阶段后，调用 `saveToRecords()`
3. 改造 `LiveSessionViewModel.swift`：
   - 新增 `var recordsService: RecordsIndexService?` 属性（可选，由 WorkflowCoordinator 注入）
   - 新增 `var temporaryRecordingURL: URL?` 跟踪临时录制文件
4. 改造 `WorkflowCoordinator.swift`：
   - 在 `init` 中将 `recordsService` 传入 `liveViewModel`：`liveViewModel.recordsService = recordsService`

### 验证

```bash
cd macos/InsightKitApp && swift build 2>&1 | tail -20
```

手动验证：
- 启动实时转写 → 录制 → 停止 → 检查 `~/Documents/InsightKit/Records/` 下是否生成记录文件夹
- 记录文件夹包含 `metadata.json`、`transcript.json`、`minutes.json`、`notes.md`、`recording.mp4`（或 `.wav`）

### 退出标准

- `swift build` 零错误
- 实时会话结束后通过 `records.save` RPC 保存记录文件夹
- `LiveSessionViewModel.swift` 行数 < 650 行
- `LiveSessionViewModel+Records.swift` 行数 < 150 行
- `RecordsIndexService.refreshIndex()` 能扫描到新记录

---

## Step 3：导入流程记录保存

分支：`phase5/step3-import-record-save`
依赖：Step 1
模型层级：default
预计文件：2 改造（Swift）、1 改造（Python）
回滚：`git revert`

### 上下文简报

`ImportSessionViewModel`（`macos/.../ViewModels/ImportSessionViewModel.swift`，275 行）管理导入转写流程。用户选择文件 → 调用 `transcription.import_file` RPC → 轮询 `transcription.status` → 完成后进入 reviewing 阶段。

Step 1 已在 `transcription_runner.py` 中集成 `RecordWriter`，后端完成转写后会自动写出记录文件夹并在返回值中包含 `record_path`。

后端 `transcription.status` RPC 返回的 `last_completed` 需要包含 `record_path`（Step 1 已在 `run_transcription_job` 返回值中加入，但 `job_queue.py` 的 `_last_completed` 构建逻辑需要传递它）。

`ImportSessionViewModel` 当前没有持有 `RecordsIndexService` 引用，需要注入。

### 任务

1. 改造 `insightkit/ipc/job_queue.py`：
   - 在 `_worker_loop` 中，job 完成后将 `record_path` 加入 `_last_completed`：
     ```python
     self._last_completed = {
         "job": self._job_view(j),
         "meeting_id": result.get("meeting_id", ""),
         "segments_count": int(result.get("segments_count", 0)),
         "record_path": str(result.get("record_path", "")),
         "updated_at": datetime.now(timezone.utc).isoformat(),
     }
     ```
2. 改造 `ImportSessionViewModel.swift`：
   - 新增 `var recordsService: RecordsIndexService?` 属性
   - 在 `applyStatus` 中，当 `job.state == .completed` 时：
     - 在 `rpcQueue` 上调用 `buildFinalInsight()`（已有方法，内部使用 `rpcQueue.async`，安全）
     - 在 `rpcQueue` 上调用 `rpcClient.transcriptList(meetingID:)` 加载转写文本，结果通过 `DispatchQueue.main.async` 回写到 `transcriptEntries`
     - 调用 `recordsService?.refreshIndex()`
   - 在 `resetToSelecting()` 中调用 `recordsService?.refreshIndex()`
3. 改造 `WorkflowCoordinator.swift`：
   - 在 `init` 中将 `recordsService` 传入 `importViewModel`：`importViewModel.recordsService = recordsService`

### 验证

```bash
cd macos/InsightKitApp && swift build 2>&1 | tail -20
python -m pytest tests/test_transcription_import_rpc.py -v
```

手动验证：
- 导入音频文件 → 转写完成 → 检查记录文件夹生成
- 进入 reviewing → 章节和纪要正确显示
- 返回首页 → 最近记录列表显示新记录

### 退出标准

- `swift build` 零错误
- Python 测试通过
- `job_queue.py` 的 `_last_completed` 包含 `record_path`
- 导入转写完成后 reviewing 阶段正确显示 chapters、smartMinutes、transcriptEntries
- `RecordsIndexService` 能扫描到新记录

---

## Step 4：笔记持久化

分支：`phase5/step4-notes-persistence`
依赖：Step 2（需要 `LiveSessionViewModel+Records.swift` 存在）
模型层级：default
预计文件：1 新增（Swift）、3 改造（Swift）
回滚：`git revert`

### 上下文简报

前端三个 ViewModel 都管理 `notes: [TimestampedNote]`：
- `LiveSessionViewModel`（`+Panels` 扩展）
- `ImportSessionViewModel`
- `RecordReviewDataSource`（已实现 `saveNotes()` 和 `loadNotes()`）

`RecordReviewDataSource.saveNotes()` 将笔记写为 `notes.md`，每行 `MM:SS text`。`loadNotes()` 解析同样格式。

`LiveSessionViewModel` 和 `ImportSessionViewModel` 在会话结束时不会将笔记写出到记录文件夹。

Step 2 新增的 `LiveSessionViewModel+Records.swift` 的 `saveToRecords()` 方法已通过 `records.save` RPC 传入 `notes_md` 参数，但需要将 `[TimestampedNote]` 序列化为 `MM:SS text` 格式。

### 任务

1. 新建 `Utils/NotesFileIO.swift`（轻量工具）：
   - `static func serialize(_ notes: [TimestampedNote]) -> String`：每行 `MM:SS text`
   - `static func parse(_ content: String) -> [TimestampedNote]`
2. 改造 `LiveSessionViewModel+Records.swift`：
   - 在 `saveToRecords()` 中使用 `NotesFileIO.serialize(notes)` 构建 `notes_md` 参数传给 RPC
3. 改造 `ImportSessionViewModel.swift`：
   - 新增 `saveNotesToRecord()` 方法：
     - 使用 `NotesFileIO.serialize(notes)` 生成内容
     - 写入 `RecordsIndexService.rootDirectory/{currentMeetingID}/notes.md`
   - 在 reviewing 阶段退出时（`resetToSelecting` 或导航离开）自动调用
4. 改造 `RecordReviewDataSource.swift`：
   - 将 `saveNotes()` 改为使用 `NotesFileIO.serialize`
   - 将 `loadNotes()` 改为使用 `NotesFileIO.parse`

### 验证

```bash
cd macos/InsightKitApp && swift build 2>&1 | tail -20
```

### 退出标准

- `swift build` 零错误
- 实时会话结束后 `notes.md` 通过 RPC 写入记录文件夹
- 导入转写 reviewing 阶段可保存笔记到本地文件
- `RecordReviewDataSource` 正确加载已保存的笔记
- `NotesFileIO` 的序列化/反序列化与 `RecordReviewDataSource` 现有格式完全兼容

---

## Step 5：记录回看接通 RPC

分支：`phase5/step5-record-review-rpc`
依赖：Step 3
模型层级：default
预计文件：2 改造（Swift）
回滚：`git revert`
可与 Step 4 并行

### 上下文简报

`RecordReviewDataSource`（`macos/.../ViewModels/RecordReviewDataSource.swift`，174 行）是记录回看的数据源适配器。它从文件夹加载 `transcript.json`、`minutes.json`、`notes.md`，并实现三个面板 Protocol。

`onGenerateMinutes()` 当前是空壳（第 129-131 行，注释 `// Would call RPC to generate — placeholder`）。要接通 `insight.build_final` RPC 需要：
1. 注入 `InsightRPCClientProtocol` 依赖
2. 确定 `meetingID`（`metadata.id` 即为 `meetingID`，因为 Step 1 的 `RecordWriter` 使用 `meeting_id` 作为文件夹名和 `metadata.id`）
3. 在后台队列执行 RPC 调用，结果通过 `DispatchQueue.main.async` 回写

`RecordReviewDataSource` 当前没有 `rpcClient` 和 `rpcQueue`，需要通过 init 注入。

### 任务

1. 改造 `RecordReviewDataSource.swift`：
   - init 新增可选参数 `rpcClient: InsightRPCClientProtocol? = nil`
   - 新增 `private let rpcQueue = DispatchQueue(label: "InsightKit.RecordReview.RPC", qos: .userInitiated)`
   - 实现 `onGenerateMinutes()`：
     - 在 `rpcQueue.async` 中调用 `rpcClient?.buildFinal(meetingID: metadata.id)`
     - 成功后在 `DispatchQueue.main.async` 中更新 `smartMinutesData` 和 `chapters`
     - 同时将新生成的 `minutes.json` 写回记录文件夹（覆盖旧文件）
2. 改造 `RecordsView.swift`（或创建 `RecordReviewDataSource` 的调用处）：
   - 在创建 `RecordReviewDataSource` 时传入 `rpcClient`（从 `WorkflowCoordinator` 获取）

### 验证

```bash
cd macos/InsightKitApp && swift build 2>&1 | tail -20
```

手动验证：
- 打开记录回看 → 点击"生成纪要" → 纪要正确生成并显示
- 关闭回看后重新打开 → 纪要从 `minutes.json` 加载（持久化成功）

### 退出标准

- `swift build` 零错误
- `onGenerateMinutes()` 不再是空壳
- 生成的纪要写回 `minutes.json`
- RPC 调用在 `rpcQueue` 上执行，UI 更新在主线程

---

## Step 6：记录搜索 RPC（可选优化）

分支：`phase5/step6-records-search-rpc`
依赖：Step 1-3
模型层级：default
预计文件：2 改造（Python）、1 改造（Swift）
回滚：`git revert`

### 上下文简报

前端 `RecordsIndexService.searchRecords` 在本地搜索 `summaryPreview` 和标签。但转写全文存在后端 SQLite 的 `segments_fts` 虚拟表中。Step 1 写出的 `transcript.json` 包含完整转写文本，但逐文件读取 JSON 做全文搜索性能差。

可选方案：新增 `records.search` RPC，利用后端 SQLite FTS 做全文搜索。

### 任务

1. 后端新增 `records.search` RPC 方法：
   - 在 `insightkit/ipc/server.py` 的 `_dispatch` handlers 中注册 `"records.search"`
   - 实现委托到 `InsightStore.search_segments`
   - 参数：`query`（搜索词）、`limit`（最大结果数，默认 20）
   - 返回：`{results: [{meeting_id, start_ms, end_ms, text, speaker}], total}`
2. 在 `module.capabilities` 的 `actions` 列表中添加 `"records.search"`
3. 前端 `RecordsIndexService` 可选择调用此 RPC 增强搜索（保持本地搜索作为 fallback）
4. 新增测试 `tests/test_records_search_rpc.py`

### 验证

```bash
python -m pytest tests/test_records_search_rpc.py -v
cd macos/InsightKitApp && swift build 2>&1 | tail -20
```

### 退出标准

- RPC 方法正确返回搜索结果
- 前端搜索可同时搜索标签、摘要和转写全文
- 本地搜索作为 fallback 仍然可用

---

## Step 7：集成测试与清理

分支：`phase5/step7-integration`
依赖：Step 1-6
模型层级：default
预计文件：1 新增（测试）、若干小改造
回滚：`git revert`

### 上下文简报

Steps 1-6 完成后，前后端数据流应完整闭环。本步骤验证端到端流程并清理遗留问题。

### 任务

1. 新增集成测试 `tests/test_record_e2e.py`：
   - 模拟完整转写流程（调用 `run_transcription_job`）→ 验证记录文件夹生成
   - 验证 `metadata.json` 的 `createdAt` 以 `Z` 结尾（不是 `+00:00`）
   - 验证 `transcript.json` 格式：数组，每个元素有 `start_ms`、`end_ms`、`speaker`、`text`
   - 验证 `minutes.json` 格式：有 `structured_summary`、`highlights`、`key_decisions`、`action_items`
   - 验证 `records.save` RPC 端到端可用
   - 验证 `records.search` RPC 端到端可用（如果 Step 6 完成）
2. 端到端手动验证：
   - 实时转写完整流程：Green Room → 录制 → 停止 → 智能纪要 → 记录保存 → 记录列表显示 → 记录回看
   - 导入转写完整流程：文件选择 → 转写 → 智能纪要 → 记录保存 → 记录列表显示 → 记录回看
   - 记录管理：搜索 → 筛选 → 标签管理 → 删除
   - 记录回看：生成纪要 → 纪要持久化 → 笔记编辑 → 笔记持久化
3. 清理：
   - 检查 `WorkflowCoordinator` 中残留引用：`grep -r "transcriptionViewModel\|// TODO\|// placeholder\|// Would call" macos/`
   - 确认 `InsightKitApp.swift` 中菜单命令对 `.importMedia` 和 `.records` 路由的处理正确
   - 所有 `// placeholder` 和 `// Would call` 注释确认已全部实现

### 验证

```bash
python -m pytest tests/ -v --tb=short
cd macos/InsightKitApp && swift build 2>&1 | tail -20
grep -r "// placeholder\|// Would call" macos/ && echo "FOUND placeholders" || echo "Clean"
```

### 退出标准

- 所有 Python 测试通过
- `swift build` 零错误
- 实时转写和导入转写的完整流程均能生成可回看的记录
- 记录列表正确显示所有记录
- 无空壳方法或 placeholder 注释残留
- 新文件 < 400 行，改造文件 < 800 行

---

## 计划变更协议

如需修改本蓝图：
- **拆分步骤**：在原步骤后插入子步骤（如 2a、2b），更新依赖图
- **跳过步骤**：标记为 SKIPPED + 原因，确认下游步骤不受影响
- **插入步骤**：分配新编号，更新依赖图
- **放弃步骤**：标记为 ABANDONED + 原因，回滚已完成的部分
