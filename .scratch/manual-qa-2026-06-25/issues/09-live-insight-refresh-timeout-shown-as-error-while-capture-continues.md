# Live Insight Refresh timeout is shown as an error while capture continues

Status: ready-for-human

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

During an active Live Workspace session, the realtime speech summary banner showed:

`调用超时: insight.refresh_live`

At the same time, the live session still appeared usable: audio capture continued, Transcript Segments were visible, Smart Minutes still had useful content, and the user felt the overall experience was normal.

The visible error makes the workflow look broken even though the failure appears limited to one live Insight Refresh attempt.

## What I expected

If one live Insight Refresh times out while capture and transcription are still working, the app should treat it as a recoverable analysis delay instead of presenting the whole realtime speech summary as abnormal.

The Live Workspace should preserve existing Smart Minutes and transcript evidence, continue capture, and show a lower-severity status or retry path unless capture, ASR, or the whole Sidecar is actually unavailable.

## Steps to reproduce

1. Launch the installed InsightKit app.
2. Open the Live Workspace.
3. Start a live recording session with microphone and camera enabled.
4. Speak long enough for Transcript Segments and Smart Minutes content to appear.
5. Continue recording until a live Insight Refresh runs.
6. Observe that the banner can show `调用超时: insight.refresh_live` while the transcript, Smart Minutes, and capture experience still appear to continue normally.

## Additional context

Reported during owner-led manual QA against installed InsightKit build `20260625103254`.

Visible session context:
- meeting ID: `live-7698CF8C-0CDF-40F6-A94E-483B9158F718`
- session phase: running
- recording time: about `01:22`
- last refresh shown around `10:49`
- status area still showed transcription in progress
- Smart Minutes summary was visible
- the error banner action `打开设置` now opens the Settings Workspace, so this is not the same issue as the previous settings-route bug

This is separate from issue 07. Issue 07 is about post-session Final Insight Generation timing out on `insight.build_final`; this issue is about live Insight Refresh timing out on `insight.refresh_live` while the session continues.

## Comments

### 2026-06-25 - Manual QA

The owner reported that the Live Workspace showed `调用超时: insight.refresh_live`, but capture, transcript display, and Smart Minutes still felt usable. This should be triaged as a recoverable live Insight Refresh degradation problem rather than a total Live Workspace failure.

### 2026-06-25 - Additional evidence

The owner provided another QA capture from meeting `live-37056EA5-F6A0-44D6-9701-7E500A5935AE`.

The captured transcript includes comments that `调用超时` appeared around `01:30` to `01:32`, then the experience became normal again around `02:00` to `02:11`. This reinforces that a live Insight Refresh timeout can be intermittent and recoverable while capture and transcript continue.

### 2026-06-25 - Focused triage

Promoted to `ready-for-agent`.

Code triage found this as a recoverable Live Insight Refresh degradation rather than a total Live Workspace failure. `LiveTranscriptPipeline.refreshLiveInsight` can throw a generic `insight.refresh_live` timeout upward; `LiveSessionViewModel.processChunk` then calls `publishError`, and `ContentView` shows that as a top realtime-summary error banner even when capture, Transcript Segments, and existing Smart Minutes continue.

Bounded implementation target:

- classify `insight.refresh_live` timeout as a non-fatal analysis delay when transcript/capture are still healthy;
- preserve existing Smart Minutes and transcript evidence;
- show lower-severity status or retry messaging instead of putting the whole live summary into an error state;
- only escalate if the underlying capture, ASR Runtime, or Sidecar is actually unavailable or repeated failures cross a clear threshold.

Suggested regression loop:

- add a pipeline or view-model test where `refreshLiveInsight` throws `调用超时: insight.refresh_live`;
- assert that transcript outcome is still applied and `captureState` does not become `.error`;
- assert that a user-facing degraded analysis status is available without losing prior Smart Minutes.

Dependency note: implement after issue 11 if possible, because issue 11 separates normal warmup/no-transcript states from actual analysis failures.

### 2026-06-25 - Diagnosing-bugs implementation pass

Code fix installed in build `20260625131608`; owner retest required.

Root cause:

- `LiveTranscriptPipeline.refreshLiveInsight` treated a single `insight.refresh_live` timeout like a fatal pipeline error.
- `LiveSessionViewModel.processChunk` then published that as `errorMessage`, so `ContentView` showed the top `实时语音总结异常` banner.
- `.paused(.timeout)` also suspended future Insight Refresh attempts, even though capture and transcript evidence could still be healthy.

Implemented:

- classify `调用超时: insight.refresh_live` as a recoverable live-analysis delay;
- preserve Transcript Segments, Smart Minutes evidence, and capture state;
- return `analysisRuntimeState = .ready` with no top-level `errorMessage`;
- show a lower-severity recording status: `智能分析刷新超时，转写继续；系统会在后续转写更新后自动重试。`;
- keep `insightRefreshSuspended` false for this recoverable timeout so later transcript updates can retry refresh.

Verification:

- red loop first failed as expected:
  - `swift test --package-path macos/InsightKitApp --filter LiveTranscriptPipelineTests/testLiveRefreshTimeoutDegradesWithoutThrowingWhileKeepingTranscript --filter LiveSessionViewModelTests/testProcessChunkTreatsLiveRefreshTimeoutAsRecoverableStatus`
- target green loop passed: same command, 2 tests, 0 failures
- related green loop passed: `swift test --package-path macos/InsightKitApp --filter LiveTranscriptPipelineTests --filter LiveSessionViewModelTests`, 35 tests, 0 failures
- full Swift gate passed: `swift test --package-path macos/InsightKitApp`, 141 tests, 0 failures
- installed-app sync passed: `PATH=/Users/yann.jy/miniconda3/bin:$PATH bash scripts/sync_insightkit_app.sh`

Installed proof:

- installed app: `/Users/yann.jy/Applications/InsightKit.app`
- installed build: `20260625131608`
- proof: `logs/workflow/latest_sync.json`

Owner retest should confirm:

- a single `insight.refresh_live` timeout no longer appears as the top `实时语音总结异常` banner when capture and transcript continue;
- transcript rows continue to appear;
- existing Smart Minutes content remains visible;
- the lower status may mention a temporary analysis-refresh timeout and retry, but the session should not look fully broken.

### 2026-06-25 - Owner retest passed

The owner confirmed issue 09 is resolved.

Recoverable `insight.refresh_live` timeouts are no longer an active blocker for continuing manual QA.
