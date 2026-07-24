# 实时语音总结卡顿诊断报告

## Summary

- 诊断对象：`实时语音总结`，输入模式固定为 `仅麦克风`。
- 结论：当前主因不是 provider，也不是“用户误以为已经开始”的单纯 UX 问题，而是 **ASR sidecar 的启动/预热路径会长时间阻塞，并且在超时后留下一个对后续状态查询不友好的 runtime 状态**。
- 结论强度：高。由两类证据同时支持：
  - 真实运行时间线与进程采样
  - 代码实现与 sidecar 日志

## Test Matrix

| Run | 模式 | 结果 |
| --- | --- | --- |
| `run1_packaged_cold_retry` | 冷启动 + 已打包 `.app` + 当前 provider | 进入 `准备运行时 -> 加载模型`，约 `26.7s` 后回到 `会后定稿/待机`，始终无首条文本 |
| `run2_packaged_hot` | 热启动 + 已打包 `.app` + 当前 provider | 进入 `准备运行时`，约 `17.2s` 后直接回到 `会后定稿/待机`，始终无首条文本 |
| `run3_packaged_provider_authfail` | 冷启动 + 已打包 `.app` + 无效 provider key | 进入 `准备运行时 -> 加载模型`，约 `31.4s` 后回到 `会后定稿/待机`，始终无首条文本 |
| `run4_source_cold` / `run4_source_cold_retry` | 源码运行 | `swift run` 与直接启动 debug 二进制都未得到可稳定自动化的 GUI 进程；该项未形成有效“用户视角”对照证据 |

## Timeline

### Run 1: Cold + Packaged + Current Provider

- `0.585s`: `进行中 / 准备运行时`
- `6.533s`: `进行中 / 加载模型`
- `26.693s`: `会后定稿 / 待机`
- 首条文本：未出现
- transcript 区占位文案 `等待实时转写输入…` 全程未消失

关键证据：

- [events.json](/Users/yann.jy/Developer/Projects/transcription/logs/diagnostics/live-lag/20260306-003204/run1_packaged_cold_retry/events.json)
- [t3_sidecar.sample.txt](/Users/yann.jy/Developer/Projects/transcription/logs/diagnostics/live-lag/20260306-003204/run1_packaged_cold_retry/t3_sidecar.sample.txt)
- [t60_sidecar.sample.txt](/Users/yann.jy/Developer/Projects/transcription/logs/diagnostics/live-lag/20260306-003204/run1_packaged_cold_retry/t60_sidecar.sample.txt)
- [sidecar.log](/Users/yann.jy/Library/Logs/InsightKit/sidecar.log)

### Run 2: Hot + Packaged + Current Provider

- `0.585s`: `进行中 / 准备运行时`
- `17.230s`: `会后定稿 / 待机`
- 首条文本：未出现
- `asr.runtime.status` 在启动前后都超时
- `analysis.providers.status` 正常返回，`selected_vendor=deepseek`，`active_ready=true`

关键证据：

- [events.json](/Users/yann.jy/Developer/Projects/transcription/logs/diagnostics/live-lag/20260306-003204/run2_packaged_hot/events.json)
- [00_prestart_rpc.json](/Users/yann.jy/Developer/Projects/transcription/logs/diagnostics/live-lag/20260306-003204/run2_packaged_hot/00_prestart_rpc.json)
- [99_post_rpc.json](/Users/yann.jy/Developer/Projects/transcription/logs/diagnostics/live-lag/20260306-003204/run2_packaged_hot/99_post_rpc.json)
- [t60_sidecar.sample.txt](/Users/yann.jy/Developer/Projects/transcription/logs/diagnostics/live-lag/20260306-003204/run2_packaged_hot/t60_sidecar.sample.txt)

### Run 3: Cold + Packaged + Invalid Provider Key

- `0.579s`: `进行中 / 准备运行时`
- `11.465s`: `进行中 / 加载模型`
- `31.402s`: `会后定稿 / 待机`
- 首条文本：未出现
- 状态序列与 run 1 本质一致

关键证据：

- [events.json](/Users/yann.jy/Developer/Projects/transcription/logs/diagnostics/live-lag/20260306-003204/run3_packaged_provider_authfail/events.json)
- [99_post_rpc.json](/Users/yann.jy/Developer/Projects/transcription/logs/diagnostics/live-lag/20260306-003204/run3_packaged_provider_authfail/99_post_rpc.json)

说明：

- 这轮的 invalid key 是通过 Keychain 临时改写 `vendor.deepseek.api_key` 完成，并已恢复。
- 该轮并未把 live 流推进到 provider probe/refresh 阶段；它仍然先在 ASR 路径失败。

### Run 4: Source GUI

- 尝试 1：按计划使用 `swift run --package-path ...`
  - 结果：只稳定完成构建，未得到可持续自动化的 GUI 进程。
- 尝试 2：直接启动 `macos/InsightKitApp/.build/arm64-apple-macosx/debug/InsightKitApp`
  - 结果：未得到可稳定自动化的窗口/toolbar 结构。

这部分不足以支持“用户视角下源码版是否同样卡顿”的最终判断，因此不纳入主结论证据链。

相关产物：

- [run4_source_cold/app_stdout.log](/Users/yann.jy/Developer/Projects/transcription/logs/diagnostics/live-lag/20260306-003204/run4_source_cold/app_stdout.log)
- [run4_source_cold_retry/app_stdout.log](/Users/yann.jy/Developer/Projects/transcription/logs/diagnostics/live-lag/20260306-003204/run4_source_cold_retry/app_stdout.log)

## Process Evidence

### App

- `ui_poll` 延迟峰值均低于 `1s`
  - run1: `944ms`
  - run2: `714ms`
- 没有证据表明 UI 主线程在首要问题阶段已经形成“重度卡死”
- 注意：app sample 会受到 Accessibility 轮询污染，因此本报告不把 app sample 作为主证据

### Sidecar

- run1 `t3` 采样显示 sidecar 线程在 `libtorch_cpu` / `uniform_` / `normal_` 路径里，说明此时正在做重型 PyTorch/FunASR 初始化或 warmup
  - [t3_sidecar.sample.txt](/Users/yann.jy/Developer/Projects/transcription/logs/diagnostics/live-lag/20260306-003204/run1_packaged_cold_retry/t3_sidecar.sample.txt)
- run2 `t3/t60/final` 采样显示：
  - main thread 仍能 `accept()` socket
  - 大量线程阻塞在 Python lock / `_pthread_cond_wait`
  - `analysis.providers.status` 可正常返回
  - 只有 `asr.runtime.status` 持续超时
- 这更像是 **ASR runtime 局部卡住/锁竞争**，不是 sidecar 整体宕死

## Sidecar Log Evidence

`[sidecar.log](/Users/yann.jy/Library/Logs/InsightKit/sidecar.log)` 显示：

- `2026-03-06 00:44:42` 与 `00:54:25` 两次 fresh sidecar launch
- 随后发生 FunASR ASR/VAD/PUNC/SPK 模型加载
- 日志里能看到模型文件加载成功，但 UI 端“加载模型”阶段明显长于这些日志显示的文件读取时间

推断：

- 真实慢点不只是“磁盘加载模型文件”，更可能是 **模型加载后的 warmup/首次推理返回**。

## Code Evidence

### 1. `prewarm_asr` 忽略 `timeout_sec`

- [scripts/transcriber.py:560](/Users/yann.jy/Developer/Projects/transcription/scripts/transcriber.py:560)
- [scripts/transcriber.py:566](/Users/yann.jy/Developer/Projects/transcription/scripts/transcriber.py:566)

关键事实：

- `timeout_sec` 被写成 `_ = timeout_sec  # Reserved for future watchdog enforcement.`
- 这意味着 app 端虽然按 `20s` 给 `asr.prewarm` 设置了 RPC 超时，但 sidecar 端没有真正的 watchdog
- 一旦 app 端先超时，sidecar 端的 prewarm 仍可能继续在后台跑

### 2. prewarm 对 FunASR 执行真实 warmup 推理

- [scripts/transcriber.py:531](/Users/yann.jy/Developer/Projects/transcription/scripts/transcriber.py:531)
- [scripts/transcriber.py:537](/Users/yann.jy/Developer/Projects/transcription/scripts/transcriber.py:537)
- [scripts/transcriber.py:573](/Users/yann.jy/Developer/Projects/transcription/scripts/transcriber.py:573)

关键事实：

- `_warmup_once("funasr")` 会写入一段静音 wav，并调用 `model.generate(...)`
- 这不是元数据查询，而是实际推理 warmup
- 这一步在 CPU/float32 路径上可能比 UI 期待更重

### 3. `_load_funasr_model()` 在全局 `_models_lock` 内构造 `AutoModel`

- [scripts/transcriber.py:317](/Users/yann.jy/Developer/Projects/transcription/scripts/transcriber.py:317)
- [scripts/transcriber.py:329](/Users/yann.jy/Developer/Projects/transcription/scripts/transcriber.py:329)

关键事实：

- `AutoModel(...)` 整段都在 `_models_lock` 保护范围内
- 同时 `runtime_backend_status()` / `runtime_warm_status()` 也读取同一把锁
  - [scripts/transcriber.py:106](/Users/yann.jy/Developer/Projects/transcription/scripts/transcriber.py:106)
  - [scripts/transcriber.py:125](/Users/yann.jy/Developer/Projects/transcription/scripts/transcriber.py:125)

推断：

- 当 prewarm 或模型初始化线程占住这把锁时，`asr.runtime.status` 这类状态查询也可能被一起堵住
- 这与 run2 的表现一致：`sidecar.status` 和 provider 状态可返回，但 `asr.runtime.status` 单独超时

### 4. App 启动链路确实把 `ensureRuntimeReady + asrPrewarm(20s)` 放在采集开始之前

- [LiveSessionViewModel.swift:306](/Users/yann.jy/Developer/Projects/transcription/macos/InsightKitApp/Sources/InsightKitApp/ViewModels/LiveSessionViewModel.swift:306)
- [LiveSessionViewModel.swift:310](/Users/yann.jy/Developer/Projects/transcription/macos/InsightKitApp/Sources/InsightKitApp/ViewModels/LiveSessionViewModel.swift:310)
- [LiveSessionViewModel.swift:323](/Users/yann.jy/Developer/Projects/transcription/macos/InsightKitApp/Sources/InsightKitApp/ViewModels/LiveSessionViewModel.swift:323)

这解释了为什么用户会先看到一个长时间的“已经开始但还没有文本”的阶段。

## Root Cause Ranking

### 1. 主因：ASR prewarm / runtime 路径本身阻塞，并且超时后没有 sidecar 端 watchdog 收口

支持证据：

- run1 冷启动在 `加载模型` 阶段停留约 `20s`
- `prewarm_asr` 明确忽略 `timeout_sec`
- sidecar 采样显示 PyTorch/FunASR 初始化/计算热点
- run1 和 run3 都在首条文本出现前失败

### 2. 次因：ASR runtime 状态查询与模型初始化共享锁，失败后留下“热态不可查询”的坏状态

支持证据：

- run2 热启动时 `asr.runtime.status` 在启动前后都超时
- 同时 `sidecar.status` 与 `analysis.providers.status` 可以正常返回
- `_load_funasr_model()` 与 `runtime_backend_status()/runtime_warm_status()` 共用 `_models_lock`

### 3. 次因：用户可见状态虽然分阶段了，但仍不足以表达“ASR prewarm 已超时/sidecar 仍在后台忙”

支持证据：

- UI 长时间停在 `准备运行时` / `加载模型`
- 没有首条文本，也没有更明确的“本地 ASR 启动失败但 sidecar 仍在收尾”的反馈

## Rejected / Downgraded Hypotheses

### “模型没有显式加载，所以用户误以为已经正式开始”

- 结论：`次因`
- 这解释的是感知问题，不解释技术性失败
- 真正的技术问题是：即使用户知道“还在加载”，加载路径本身也会超时或把 runtime 带入坏状态

### “模型没有跑在 GPU，所以才卡”

- 结论：`不成立（作为主因）`
- 现有证据只支持它可能是性能放大器，不支持它是主因
- 当前最核心的失败发生在：
  - `asr.prewarm` 客户端超时
  - `asr.runtime.status` 长时间超时
  - 首条文本始终未出现
- 这些现象已经足以由 prewarm 设计、锁竞争、无 watchdog 收口解释，不需要先假设 GPU 才能成立

补充：

- 代码默认 FunASR backend 状态为 `device=auto`、`compute_type=float32`
- 但由于 `asr.runtime.status` 本身会超时，当前没有足够运行期证据把“实际后端解析到 CPU”升级为主结论

## Decision Mapping

### 启动阻塞

- `成立`
- run1/run2/run3 都在首条文本出现前失败

### ASR 吞吐瓶颈

- `部分成立，但不是首要矛盾`
- 冷启动时 sidecar 确有重型 PyTorch/FunASR 工作
- 但系统甚至没稳定进入持续转写阶段，所以“chunk 长期排队”不是第一现场

### UI 主线程过载

- `当前证据不支持为主因`
- 当前没有任何 run 进入“持续出文本然后越跑越卡”的阶段
- app 主线程样本受 Accessibility 轮询污染，不作为主证据

### analysis / refresh 引发卡顿

- `不成立`
- 当前失败发生在 provider refresh 之前
- run2/provider status 正常时仍失败
- run3/provider key 失效时仍先在 ASR 路径失败

## What Is Still Missing

- 一个可稳定自动化的“源码 GUI”运行方式
- 一个专门为 live 流设计的显式 provider 401/timeout 取证快照
- 未使用 Instruments GUI；本轮只使用 CLI 取证

这些不足不会改变当前主因判断，但会影响“源码路径是否完全同构”和“provider 失效在 live 后半段会不会再引入额外卡顿”的结论强度。

## Recommended Fix Direction

1. 给 `asr.prewarm` 加真实 watchdog/cancellation，而不是只在 app 端设置 RPC timeout。
2. 不要在 `_models_lock` 内构造 FunASR `AutoModel`；把长耗时初始化移出锁，只在缓存写回时持锁。
3. 把 `runtime.status` 做成无阻塞快照读取，不能与 prewarm/模型初始化共享致命锁路径。
4. 如果 prewarm 超时，UI 必须明确显示“本地语音识别预热超时”，而不是只停留在“加载模型”。
5. 在修完上述问题前，不要把“没上 GPU”当成首要修复方向；那是优化项，不是当前最先失效的控制点。
