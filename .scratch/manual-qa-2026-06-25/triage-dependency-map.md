# Manual QA Dependency Triage

Status: current
Last reviewed: 2026-06-25

## Purpose

This file records the batch triage pass for the owner-led manual QA issues from 2026-06-25.

The Matt workflow rule for this lane is batch triage, single-issue implementation: read the related issues together, identify shared roots and dependencies, then implement one bounded `ready-for-agent` issue at a time.

## Context Used

- `.scratch/manual-qa-2026-06-25/PRD.md`
- `.scratch/manual-qa-2026-06-25/issues/01-live-capture-preview-stays-black.md`
- `.scratch/manual-qa-2026-06-25/issues/02-camera-preview-aspect-ratio-is-overly-wide.md`
- `.scratch/manual-qa-2026-06-25/issues/03-live-insight-refresh-fails-with-gpu-stream-sidecar-error.md`
- `.scratch/manual-qa-2026-06-25/issues/04-live-notes-entry-is-not-discoverable-or-usable.md`
- `.scratch/manual-qa-2026-06-25/issues/05-live-summary-error-open-settings-does-not-open-settings.md`
- `.scratch/manual-qa-2026-06-25/issues/06-live-sidecar-memory-spike-can-freeze-and-restart-system.md`
- `.scratch/manual-qa-2026-06-25/issues/07-final-insight-generation-times-out-after-live-session.md`
- `.scratch/manual-qa-2026-06-25/issues/08-live-review-media-does-not-display-video.md`
- `.scratch/manual-qa-2026-06-25/issues/09-live-insight-refresh-timeout-shown-as-error-while-capture-continues.md`
- `.scratch/manual-qa-2026-06-25/issues/10-provider-non-json-payload-shown-as-realtime-summary-error.md`
- `.scratch/manual-qa-2026-06-25/issues/11-runtime-warmup-delay-can-be-misclassified-as-summary-failure.md`
- `.scratch/manual-qa-2026-06-25/issues/12-generated-summary-does-not-open-summary-review-interface.md`
- `.scratch/manual-qa-2026-06-25/issues/13-live-session-stop-start-can-continue-previous-transcription-backlog.md`
- `.scratch/manual-qa-2026-06-25/issues/14-live-workspace-loading-states-lack-progress-feedback.md`
- `.scratch/manual-qa-2026-06-25/issues/15-speaker-diarization-can-fail-or-label-speakers-incorrectly.md`
- `.scratch/manual-qa-2026-06-25/issues/16-speaker-labels-cannot-be-edited-after-transcription.md`
- `.scratch/manual-qa-2026-06-25/issues/17-smart-minutes-cannot-be-exported-from-review-flow.md`
- `.scratch/manual-qa-2026-06-25/issues/18-record-default-names-are-hard-to-read.md`
- `.scratch/manual-qa-2026-06-25/issues/19-records-cannot-be-renamed.md`
- `.scratch/manual-qa-2026-06-25/issues/20-smart-minutes-review-source-playback-has-no-audio.md`
- `.scratch/manual-qa-2026-06-25/issues/21-smart-minutes-review-source-loses-video-after-audio-fix.md`
- `.scratch/manual-qa-2026-06-25/issues/22-smart-minutes-review-source-seek-does-not-start-playback.md`
- `CONTEXT-MAP.md`
- `docs/contexts/product/CONTEXT.md`
- `docs/contexts/macos-app/CONTEXT.md`
- `docs/contexts/python-runtime/CONTEXT.md`
- `docs/agents/loop-engineering.md`
- `docs/agents/issue-tracker.md`
- `docs/agents/triage-labels.md`
- `macos/InsightKitApp/Sources/InsightKitApp/Views/LiveWorkspaceView.swift`
- `macos/InsightKitApp/Sources/InsightKitApp/Views/Components/LiveCenterView.swift`
- `macos/InsightKitApp/Sources/InsightKitApp/Views/Components/VideoPreviewView.swift`
- `macos/InsightKitApp/Sources/InsightKitApp/Views/Components/MediaPlayerView.swift`
- `macos/InsightKitApp/Sources/InsightKitApp/Views/Components/TimestampNotesEditor.swift`
- `macos/InsightKitApp/Sources/InsightKitApp/Views/Components/SourceToggleBar.swift`
- `macos/InsightKitApp/Sources/InsightKitApp/Services/VideoCaptureService.swift`
- `macos/InsightKitApp/Sources/InsightKitApp/Services/InsightRPCClient.swift`
- `macos/InsightKitApp/Sources/InsightKitApp/ViewModels/LiveSessionViewModel.swift`
- `macos/InsightKitApp/Sources/InsightKitApp/ViewModels/LiveSessionViewModel+Capture.swift`
- `macos/InsightKitApp/Sources/InsightKitApp/ViewModels/LiveSessionViewModel+Insight.swift`
- `macos/InsightKitApp/Sources/InsightKitApp/ViewModels/LiveTranscriptPipeline.swift`
- `macos/InsightKitApp/Sources/InsightKitApp/ViewModels/WarmupPolicy.swift`
- `macos/InsightKitApp/Sources/InsightKitApp/ViewModels/LiveSessionViewModel+Panels.swift`
- `macos/InsightKitApp/Sources/InsightKitApp/ViewModels/LiveSessionViewModel+Records.swift`
- `macos/InsightKitApp/Sources/InsightKitApp/ViewModels/WorkflowCoordinator.swift`
- `macos/InsightKitApp/Sources/InsightKitApp/ViewModels/RecordReviewDataSource.swift`
- `macos/InsightKitApp/Sources/InsightKitApp/ContentView.swift`
- `macos/InsightKitApp/Sources/InsightKitApp/Views/Components/ChapterSidebarView.swift`
- `macos/InsightKitApp/Sources/InsightKitApp/InsightKitApp.swift`

## Dependency Groups

### A. Safety Retest Gate

Issues:

- `06-live-sidecar-memory-spike-can-freeze-and-restart-system.md`
- `03-live-insight-refresh-fails-with-gpu-stream-sidecar-error.md`

Status:

- Both remain `ready-for-human`.
- Issue 06 is the highest-severity safety issue because it involved system-wide freeze/restart.
- Issue 03 is the user-visible realtime speech summary failure that shares the Qwen MLX live-runtime path.

Dependency:

- Issue 03 depends on the worker containment fix from issue 06 being present.
- Further live-recording stress tests should not proceed until issue 06 is retested cautiously.

Next action:

- Owner performs a short guarded installed-app retest with memory visible.
- Stop immediately if Sidecar memory climbs abnormally.

### B. Error Recovery Route

Issue:

- `05-live-summary-error-open-settings-does-not-open-settings.md`

Status:

- owner retest passed after code fix and installed-app sync

Triage:

- The visible banner in `ContentView.activeBanner` can be computed from `liveViewModel.errorMessage`.
- `ContentView.bannerBar` always calls `coordinator.performBannerAction()`.
- `WorkflowCoordinator.performBannerAction()` currently returns early when `coordinator.bannerMessage` is nil.
- For computed live/transcription error banners, `coordinator.bannerMessage` can be nil, so the `打开设置` button can become a no-op.

Dependency:

- Independent.
- This should be fixed before or alongside more runtime diagnosis because it is the main user recovery path when issues 03 or 07 surface.

Suggested next loop:

- No further action unless the Settings Workspace route regresses.
- The later `insight.refresh_live` timeout banner is tracked separately as issue 09.

### C. Final Insight Generation Runtime

Issue:

- `07-final-insight-generation-times-out-after-live-session.md`

Status:

- `ready-for-human` after code fix and installed-app sync

Triage:

- `InsightRPCClient.buildFinal` uses the default RPC timeout path.
- The default timeout is about 8 seconds unless overridden by environment.
- `asr.transcribe_chunk` already has a dedicated longer timeout because model work can exceed the default.
- Final Insight Generation can also exceed the default timeout, especially when a provider is slow.
- `LiveSessionViewModel.buildFinalInsight()` calls `rpcClient.buildFinal`, then only saves the final insight package after the call succeeds.

Dependency:

- Independent from Capture Preview and Time-Bound Notes.
- Related to provider configuration and Sidecar runtime health, but separate from the raw Qwen MLX GPU stream error.
- Should preserve partial Smart Minutes or transcript evidence when final generation times out.

Suggested next loop:

- Owner retests issue 07 in the installed app.
- If the issue still reproduces under normal provider latency, continue `diagnosing-bugs` around provider duration, retry behavior, and finalization UI recovery.

### D. Capture Preview And Review Media Chain

Issues:

- `01-live-capture-preview-stays-black.md`
- `02-camera-preview-aspect-ratio-is-overly-wide.md`
- `08-live-review-media-does-not-display-video.md`

Status:

- All three passed owner retest after one media-chain implementation pass and installed-app sync in build `20260625113541`.

Triage:

- Issue 01: `LiveWorkspaceView` only reacts to the camera toggle. The screen toggle changes local UI state but does not call `VideoCaptureService.startScreenCapture` or another preview path.
- Issue 01: `VideoPreviewView` can only attach `cameraPreviewLayer`; ScreenCaptureKit frames are received for recording but are not exposed as a preview layer.
- Issue 02: `VideoPreviewView.Coordinator.attachPreviewLayer` and `VideoCaptureService.startCamera` both set `.resizeAspectFill`, which fills the container by cropping. This matches the overly wide/cropped camera preview.
- Issue 08: `LiveSessionViewModel.prepareTemporaryRecordingForSave` currently prepares a combined audio WAV from chunks and sets that as `mediaURL`.
- Issue 08: `saveToRecords` persists `temporaryRecordingURL`; if that URL is the WAV fallback, the Record Review media player is correctly loading audio, not saved video.
- Issue 08: `VideoCaptureService.startRecording(to:)` exists, but no current Live Session path calls it.

Dependency:

- Handle issue 01 before issue 02 if the selected visual source is not reliably connected to preview state.
- Handle issue 02 after the preview source is real, so the visual acceptance check is meaningful.
- Handle issue 08 after deciding the Live Session media contract: save actual camera/screen video when visual capture is enabled, or show an explicit audio-only review state.

Suggested order:

1. Owner retests issue 01 camera-only and screen-only preview behavior.
2. Owner retests issue 02 running camera preview aspect/crop behavior.
3. Owner retests issue 08 review media behavior after a visual Live Session.

### E. Time-Bound Notes UX

Issue:

- `04-live-notes-entry-is-not-discoverable-or-usable.md`

Status:

- owner retest passed after code fix and installed-app sync in build `20260625115936`.

Triage:

- The data path for creating notes exists in `LiveSessionViewModel+Panels`.
- `TimestampNotesEditor` uses a single-line `FocusAwareTextField` with a minimum height of 22 points at the bottom of the right panel.
- This matches the owner report that the note entry exists but is not discoverable or suitable for real writing.

Dependency:

- Independent from runtime and media capture.
- May share visual layout space with Session Shell work, but does not require issue 01, 02, 07, or 08 to be fixed first.

Suggested next loop:

- No further action unless the Time-Bound Notes composer regresses.

### F. Live Analysis State And Recoverable Errors

Issues:

- `11-runtime-warmup-delay-can-be-misclassified-as-summary-failure.md`
- `09-live-insight-refresh-timeout-shown-as-error-while-capture-continues.md`
- `10-provider-non-json-payload-shown-as-realtime-summary-error.md`

Status:

- Issue 11 is `ready-for-human` after code fix and installed-app sync in build `20260625123538`.
- Issue 09 is `ready-for-human` after code fix and installed-app sync in build `20260625131608`.
- Issue 10 is `ready-for-human` after code fix and installed-app sync in build `20260625132851`.

Triage:

- Issue 11: `LiveCaptureStateMapper` can represent normal warmup/capturing/transcribing states, but `LiveSessionViewModel.evaluateCaptureHealthHint` can still write a no-transcript hint into `errorMessage`.
- Issue 11: `ContentView` renders any `liveViewModel.errorMessage` as "实时语音总结异常", so normal warmup or waiting-for-first-transcript periods can look like summary failures.
- Issue 09: fixed in build `20260625131608`. `LiveTranscriptPipeline.refreshLiveInsight` now treats `调用超时: insight.refresh_live` as a recoverable live-analysis delay, and `LiveSessionViewModel` keeps it out of the top realtime-summary error banner when capture/transcript remain healthy.
- Issue 10: fixed in build `20260625132851`. Provider response-format failures such as `provider returned non-JSON payload` are now sanitized before reaching the Live Workspace banner, while Transcript Segments and existing Smart Minutes evidence remain available.

Dependency:

- Issue 11 should go first because it separates normal status hints from real errors.
- Issue 09 and issue 10 can share an analysis-error classifier, but they should keep separate issue records because timeout recovery and Provider response-format sanitization have different acceptance checks.

Suggested order:

1. Owner retests issue 09 to confirm a recoverable `insight.refresh_live` timeout no longer appears as a top realtime-summary exception.
2. Owner retests issue 11 to confirm waiting-for-first-transcript no longer appears as a realtime-summary exception.
3. Owner retests issue 10 to confirm Provider non-JSON payload errors no longer expose raw parser details.

### G. Completed Summary Review Presentation

Issue:

- `12-generated-summary-does-not-open-summary-review-interface.md`

Status:

- `ready-for-human` after code fix and installed-app sync in build `20260625140443`.

Triage:

- `LiveSessionViewModel.buildFinalInsight()` can set `sessionPhase = .reviewing` after successful Final Insight Generation.
- `LiveCenterView.reviewingView` still foregrounds the media player and Transcript Segment list.
- Smart Minutes summary is mostly visible in the left chapter sidebar, so the main workspace can still look like the in-progress transcription page even when the summary is ready.
- Fixed in build `20260625140443`. Generated Smart Minutes now switch the center reviewing state into a summary-first presentation while keeping transcript and media available below the summary.

Dependency:

- Independent from the timeout fix in issue 07.
- Best handled after issue 09 and issue 10 so the completed review state is not obscured by unresolved live-analysis error banners.

Suggested next loop:

- Owner retests successful Smart Minutes / Final Insight completion and confirms that the center workspace visibly enters the generated-summary review experience.

### H. Live Session Stop/Start Boundary

Issue:

- `13-live-session-stop-start-can-continue-previous-transcription-backlog.md`

Status:

- owner retest passed after code fix and installed-app sync in build `20260625165436`.

Triage:

- Stopping a Live Session immediately set `isRunning` to false, but the old session could still have an `activeMeetingID` while background finalization and delayed transcript processing completed.
- `WorkflowCoordinator.livePhase` only checked `isRunning` and `lastMeetingID`, so a stopped-but-not-finalized session could look like `livePreparing`.
- `LiveSessionViewModel.canStartSession` also only checked `!isRunning`, so a rapid next "开始直播洞察" click could be accepted while the old session boundary was still open.
- Fixed in build `20260625165436`. New starts are blocked while an unresolved `activeMeetingID` exists, stop finalization captures the meeting ID before asynchronous work begins, and the coordinator keeps the app in `livePostSession` during the stop/finalization boundary.

Dependency:

- This directly affects issue 12 retesting because issue 13 can prevent the app from reaching the post-session Smart Minutes choice.
- It is separate from provider timeout, non-JSON payload, and ASR runtime warmup problems because it is a UI/session-boundary state bug.

Suggested next loop:

- No further action unless the stop/start boundary regresses.
- Issue 12 can be retested again if the owner wants to confirm the completed-summary review flow without stop/start interference.

### I. Post-Retest UX, Speaker, Export, And Record Intake

Issues:

- `14-live-workspace-loading-states-lack-progress-feedback.md`
- `15-speaker-diarization-can-fail-or-label-speakers-incorrectly.md`
- `16-speaker-labels-cannot-be-edited-after-transcription.md`
- `17-smart-minutes-cannot-be-exported-from-review-flow.md`
- `18-record-default-names-are-hard-to-read.md`
- `19-records-cannot-be-renamed.md`
- `20-smart-minutes-review-source-playback-has-no-audio.md`

Status:

- Issue 14 has passed owner retest.
- Issue 15 is `needs-info`.
- Issue 16 is `ready-for-agent`.
- Issue 17 is `ready-for-human`.
- Issue 18 is `ready-for-agent`.
- Issue 19 is `ready-for-agent`.
- Issue 20 is `ready-for-human` after installed fix.

Initial breakdown:

- Issue 14 is a Capture State / Session Phase feedback problem. It is about making normal waiting visible, not about the runtime failing. It now has an installed fix and has passed owner retest.
- Issue 15 is an automatic speaker diarization quality problem. It needs a concrete failing Record/audio/transcript sample before accuracy work can be verified. A separate status-presentation issue can be filed later if the desired first step is only diarization degraded-state messaging.
- Issue 16 is a manual speaker-label correction feature gap. It is related to issue 15, but it should remain separate because users need correction even when automatic diarization improves.
- Issue 17 is a Smart Minutes export discoverability or capability gap from the review flow. Record export already exists elsewhere, so the likely gap is surfacing/exporting from the Smart Minutes review context. It now has an installed fix and has passed owner retest.
- Issue 18 is a default Record naming quality problem. Current Record surfaces can show technical IDs even when metadata has summary/date/source fields.
- Issue 19 is a manual Record rename feature gap. It is related to issue 18, but it should remain separate because better defaults do not replace user correction.
- Issue 20 is an audible playback problem in the Smart Minutes review source area. It is separate from issue 08, which covered whether review media visually appears. It now has an installed fix and needs owner retest.

Dependency:

- Issue 15 is blocked on owner or test-fixture evidence. Issue 16 can proceed without waiting for issue 15.
- Issues 18 and 19 affect the same Records Workspace experience, but neither blocks the other. If issue 19 adds a manual title field, it should override issue 18's generated display name.
- Issue 17 and issue 20 both live in the Smart Minutes review experience, but they should remain separate because export and audible playback have different verification gates.
- Issue 20 may share media playback code with earlier media-chain work, but the acceptance check is different: the user must hear review source audio.
- Issue 14 has passed independent owner retest.

Suggested next loop:

- Issues 14, 17, and 20 are no longer implementation candidates.
- Issues 21 and 22 are now `ready-for-human` after their installed Smart Minutes review-source fixes.
- Handle issues 18 and 19 as a Record naming pair, but keep their issue records separate.
- Keep issue 15 at `needs-info` until a concrete failing diarization sample is available.

## Recommended Processing Order

1. Retest gate still open: issues 06 and 03, owner only, short and guarded.
2. Owner retest still open: issue 07 Final Insight Generation timeout fix.
3. Owner retest: issue 11 Runtime Warmup / waiting-for-first-transcript status-channel fix.
4. Owner retest: issue 09 recoverable Live Insight Refresh timeout fix.
5. Owner retest: issue 10 Provider response-format sanitizer.
6. Optional owner retest: issue 12 completed-summary review presentation fix, now that issue 13 has passed owner retest.
7. Owner retest still open: issue 20/21/22 Smart Minutes review-source bundle: audio playback, video visibility, and click-to-seek-and-play.
8. Ready implementation candidates: issues 16, 18, and 19 for later product work.
9. Issue 15 remains `needs-info` until a concrete failing diarization sample is available.

## Stop Rules

- Do not stress-test Live Workspace for a long session until issue 06 is manually retested.
- Do not claim issue 03 is fixed from automated tests alone; it needs installed-app owner confirmation.
- Do not turn issue 08 into broad media-architecture work without keeping it tied to the Live Session visual-capture expectation.
- Do not implement issue 15 accuracy work without a concrete failing diarization sample and expected speaker labels.
- Do not combine issue 15 and issue 16; automatic diarization quality and manual speaker correction require different verification.
- Do not combine multiple implementation fixes in one commit unless they belong to the same dependency group and share one verification gate.

## Comments

### 2026-06-25 - Issue 13 implemented

Issue 13 was diagnosed as a Live Session boundary bug, not a Provider or ASR model bug.

Verification summary:

- red/green regression: `swift test --package-path macos/InsightKitApp --filter WorkflowCoordinatorTests/testActiveLiveMeetingStillBlocksNewLiveStartWhileStopIsFinalizing`
- related gate: `swift test --package-path macos/InsightKitApp --filter WorkflowCoordinatorTests --filter LiveSessionViewModelTests` -> 34 tests, 0 failures
- full Swift gate: `swift test --package-path macos/InsightKitApp` -> 146 tests, 0 failures
- installed build: `20260625165436`

Owner retest should start with issue 13, because it can mask or interrupt issue 12's completed-summary path.

### 2026-06-25 - Issue 13 owner retest passed and issues 14-20 filed

The owner confirmed that issue 13 is fixed in the installed app.

The same QA pass added seven `needs-triage` issues:

- issue 14: Live Workspace loading-state progress feedback
- issue 15: speaker diarization quality or degradation signaling
- issue 16: manual speaker-label editing
- issue 17: Smart Minutes export from review flow
- issue 18: readable default Record names
- issue 19: manual Record renaming
- issue 20: Smart Minutes review source audio playback

This intake was later resolved by the batch triage note below.

### 2026-06-25 - Issues 14-20 batch triage completed

Triage outcome:

- issue 14: owner retest passed after installed progress-feedback fix.
- issue 15: `needs-info`, requires a concrete failing diarization sample and expected labels.
- issue 16: `ready-for-agent`, manual speaker-label correction.
- issue 17: owner retest passed after installed Smart Minutes export from review flow fix.
- issue 18: `ready-for-agent`, readable default Record names.
- issue 19: `ready-for-agent`, manual Record renaming.
- issue 20: `ready-for-human`, installed Smart Minutes review source playback fix; owner retest found follow-up regressions filed as issues 21 and 22.
- issue 21: `ready-for-human`, installed fix restores captured video in Smart Minutes review source after the audio fix.
- issue 22: `ready-for-human`, installed fix makes Timeline Beat and Transcript Segment clicks seek and start playback.

Recommended next step: owner retest issues 20, 21, and 22 together as the Smart Minutes review-source bundle. Issue 18/19 can follow when the Records naming lane resumes. Issue 16 is ready but larger because it changes speaker-label persistence.

### 2026-06-25 - Batch triage

Batch triage found five ready implementation candidates and one retest gate:

- ready-for-human retest gate: issues 03 and 06
- ready-for-agent independent recovery: issue 05
- ready-for-agent runtime: issue 07
- ready-for-agent media chain: issues 01, 02, 08
- ready-for-agent UX: issue 04

Implementation should still happen one issue at a time.

### 2026-06-25 - Issue 05 implemented

Issue 05 now has a code fix and installed-app sync proof:

- installed build: `20260625102417`
- proof: `logs/workflow/latest_sync.json`

Owner retest later confirmed that the `打开设置` banner action opens the Settings Workspace.

### 2026-06-25 - Issues 01, 02, and 08 implemented

The Capture Preview / Record Review media chain was implemented and installed in build `20260625113541`.

Implemented:

- Issue 01: visual-source toggles now route into a shared Capture Preview plan, screen preview uses ScreenCaptureKit frames, and silent black preview states show actionable messages.
- Issue 02: camera preview uses aspect-fit behavior and the Live Workspace preview frame is bounded to a standard 16:9 media shape.
- Issue 08: visual Live Sessions start an mp4 recording path, finished video is preferred for review/records, and audio-only fallback is explicit when no video frames are saved.

Verification:

- target media-chain tests passed
- full Swift package test passed with 135 tests and 0 failures
- standard sync passed Swift and Python gates
- proof: `logs/workflow/latest_sync.json`

They remain in this dependency map as retest items rather than implementation candidates.

### 2026-06-25 - Issues 01, 02, and 08 owner retest passed

The owner confirmed that the shared Capture Preview / Record Review media-chain fix was successful. The next autonomous implementation target is issue 04.

### 2026-06-25 - Issue 04 implemented

Issue 04 now has a Time-Bound Notes UX fix and installed-app sync proof:

- installed build: `20260625115936`
- proof: `logs/workflow/latest_sync.json`
- regression test: `swift test --package-path macos/InsightKitApp --filter TimestampNotesEditorLayoutTests`
- source regression test: `PATH=/Users/yann.jy/miniconda3/bin:$PATH python -m pytest tests/test_time_bound_notes_editor_ux.py -q`

Owner retest later confirmed that the Time-Bound Notes UX fix was successful.

### 2026-06-25 - Issue 07 implemented

Issue 07 now has a code fix and installed-app sync proof:

- installed build: `20260625103254`
- proof: `logs/workflow/latest_sync.json`
- regression test: `swift test --package-path macos/InsightKitApp --filter InsightRPCClientFinalInsightTimeoutTests/testBuildFinalUsesDedicatedFinalInsightTimeout`

It remains in this dependency map as a retest item rather than an implementation candidate.

### 2026-06-25 - Issue 09 added after batch triage

The owner confirmed that issue 05's `打开设置` banner action now opens the Settings Workspace.

A new issue was filed:

- `.scratch/manual-qa-2026-06-25/issues/09-live-insight-refresh-timeout-shown-as-error-while-capture-continues.md`

Initial classification:

- status: `ready-for-agent` after focused triage
- likely group: Live Insight Refresh degradation
- distinct from issue 07, which covers post-session Final Insight Generation on `insight.build_final`

Implement issue 11 first if possible, then issue 09.

### 2026-06-25 - Issues 10 and 11 added after batch triage

The owner provided a mixed QA report and asked for precise splitting.

New issues:

- `.scratch/manual-qa-2026-06-25/issues/10-provider-non-json-payload-shown-as-realtime-summary-error.md`
- `.scratch/manual-qa-2026-06-25/issues/11-runtime-warmup-delay-can-be-misclassified-as-summary-failure.md`

Initial classification:

- issue 10 status: initially agent-ready after focused triage; later `ready-for-human` after code fix and installed-app sync
- issue 10 likely group: Provider response validation and recoverable analysis error handling
- issue 11 status: initially agent-ready after focused triage; later `ready-for-human` after code fix and installed-app sync
- issue 11 likely group: Runtime Warmup / first Transcript Segment state classification

Related existing issues updated:

- issue 08 received another review media placeholder example
- issue 09 received evidence that `insight.refresh_live` timeout can recover while the live session continues

Issue 11 should be implemented before issue 09 and issue 10 because it fixes the basic status/error channel.

Issue 11 was later implemented and installed in build `20260625123538`; issue 09 was later implemented and installed in build `20260625131608`; issue 10 was later implemented and installed in build `20260625132851`; issue 12 was later implemented and installed in build `20260625140443`.

### 2026-06-25 - Issue 12 added after batch triage

The owner reported a successful-summary presentation issue: after transcription ended and the summary was already generated, the app still looked like the transcript-dominant in-progress page instead of entering a clear summary review interface.

New issue:

- `.scratch/manual-qa-2026-06-25/issues/12-generated-summary-does-not-open-summary-review-interface.md`

Initial classification:

- issue 12 status: initially `ready-for-agent` after focused triage; later `ready-for-human` after code fix and installed-app sync
- likely group: Session Phase transition and completed Smart Minutes review presentation
- distinct from issue 07, which covers Final Insight Generation timeout rather than successful-generation presentation

Issue 12 was implemented after the live analysis state issues.

### 2026-06-25 - Issues 09-12 focused triage completed

Focused triage originally promoted issues 09, 10, 11, and 12 to `ready-for-agent`; later comments record their installed fixes and current `ready-for-human` retest state.

The recommended order is:

1. issue 11 - status/error-channel separation, now installed and awaiting owner retest;
2. issue 09 - recoverable live Insight Refresh timeout;
3. issue 10 - Provider response-format sanitization;
4. issue 12 - completed summary review presentation.

### 2026-06-25 - Issue 11 implemented

Issue 11 now has a code fix and installed-app sync proof:

- installed build: `20260625123538`
- proof: `logs/workflow/latest_sync.json`
- red/green regression test: `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testWaitingForFirstTranscriptUsesRecordingStatusInsteadOfErrorBanner`
- full Swift gate: `swift test --package-path macos/InsightKitApp`, 139 tests, 0 failures
- standard sync gate passed Swift and Python tests; Python reported `Ran 136 tests ... OK`

It remains in this dependency map as a retest item rather than an implementation candidate.

### 2026-06-25 - Issue 09 implemented

Issue 09 now has a code fix and installed-app sync proof:

- installed build: `20260625131608`
- proof: `logs/workflow/latest_sync.json`
- red/green regression tests:
  - `swift test --package-path macos/InsightKitApp --filter LiveTranscriptPipelineTests/testLiveRefreshTimeoutDegradesWithoutThrowingWhileKeepingTranscript --filter LiveSessionViewModelTests/testProcessChunkTreatsLiveRefreshTimeoutAsRecoverableStatus`
- related Live Transcript Pipeline / Live Session ViewModel gate passed: 35 tests, 0 failures
- full Swift gate passed: `swift test --package-path macos/InsightKitApp`, 141 tests, 0 failures

It remains in this dependency map as a retest item rather than an implementation candidate.

### 2026-06-25 - Issue 10 implemented

Issue 10 now has a code fix and installed-app sync proof:

- installed build: `20260625132851`
- proof: `logs/workflow/latest_sync.json`
- red/green regression tests:
  - `swift test --package-path macos/InsightKitApp --filter LiveTranscriptPipelineTests/testProviderNonJSONPayloadDegradesWithSanitizedMessageWhileKeepingTranscript --filter LiveSessionViewModelTests/testPublishErrorSanitizesProviderNonJSONPayloadError`
- related Live Transcript Pipeline / Live Session ViewModel gate passed: 37 tests, 0 failures
- full Swift gate passed: `swift test --package-path macos/InsightKitApp`, 143 tests, 0 failures
- standard sync gate passed Swift and Python tests; Python reported `Ran 136 tests ... OK`

It remains in this dependency map as a retest item rather than an implementation candidate.

### 2026-06-25 - Issue 12 implemented

Issue 12 now has a code fix and installed-app sync proof:

- installed build: `20260625140443`
- proof: `logs/workflow/latest_sync.json`
- red/green regression test:
  - `swift test --package-path macos/InsightKitApp --filter LiveReviewPresentationPlanTests`
- full Swift gate passed: `swift test --package-path macos/InsightKitApp`, 145 tests, 0 failures
- standard sync gate passed Swift and Python tests; Python reported `Ran 136 tests ... OK`

It remains in this dependency map as a retest item rather than an implementation candidate. The current manual-QA lane now has ready implementation candidates in issues 16, 18, and 19; issue 15 remains `needs-info`.

### 2026-06-25 - Issue 14 implemented

Issue 14 now has a code fix and installed-app sync proof:

- installed build: `20260625183127`
- proof: `logs/workflow/latest_sync.json`
- TDD RED/GREEN tests added to `LiveSessionViewModelTests`
- narrow gate: `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests`, 34 tests, 0 failures
- broad Swift gate: `swift test --package-path macos/InsightKitApp`, 151 tests, 0 failures
- installed smoke: launched `/Users/yann.jy/Applications/InsightKit.app` in Live UI-test route and quit successfully

Issue 14 later passed owner retest and is not an implementation candidate.

### 2026-06-25 - Issue 17 implemented

Issue 17 now has a code fix and installed-app sync proof:

- installed build: `20260625185114`
- proof: `logs/workflow/latest_sync.json`
- TDD RED/GREEN tests added to `LiveReviewPresentationPlanTests` and `LiveSessionViewModelTests`
- narrow gates:
  - `swift test --package-path macos/InsightKitApp --filter LiveReviewPresentationPlanTests`, 3 tests, 0 failures
  - `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests`, 35 tests, 0 failures
  - `swift test --package-path macos/InsightKitApp --filter RecordDocumentExporterTests`, 4 tests, 0 failures
- broad Swift gate: `swift test --package-path macos/InsightKitApp`, 153 tests, 0 failures
- installed smoke: launched `/Users/yann.jy/Applications/InsightKit.app` in Live UI-test route and quit successfully

Issue 17 later passed owner retest and is not an implementation candidate.

### 2026-06-25 - Issue 20 implemented

Issue 20 now has a code fix and installed-app sync proof:

- installed build: `20260625192450`
- proof: `logs/workflow/latest_sync.json`
- TDD RED/GREEN tests added to `LiveSessionViewModelTests`
- narrow gate: `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests`, 37 tests, 0 failures
- broad Swift gate: `swift test --package-path macos/InsightKitApp`, 155 tests, 0 failures
- installed smoke: launched `/Users/yann.jy/Applications/InsightKit.app` in Live UI-test route and quit successfully

Issue 20 is now a retest item, not an implementation candidate.

### 2026-06-25 - Issues 21 and 22 added from issue 20 owner retest

The owner reported two Smart Minutes review regressions after testing build `20260625192450`:

- issue 21: `回看资料` no longer displays captured video after the audio fix.
- issue 22: clicking Timeline Beats or Transcript Segments does not seek to the matching source position and start playback.

Issue 21 now has an installed code fix and is `ready-for-human`. Issue 22 now has an installed code fix and is `ready-for-human`. The current manual-QA lane has ready implementation candidates in issues 16, 18, and 19; issue 15 remains `needs-info`.

### 2026-06-25 - Issue 21 implemented

Issue 21 now has a code fix and installed-app sync proof:

- installed build: `20260625203632`
- proof: `logs/workflow/latest_sync.json`
- red/green regression test: `swift test --package-path macos/InsightKitApp --filter LiveReviewSourcePresentationTests/testVideoRemainsPrimaryReviewSourceWhenSeparateAudioFallbackExists`
- related gates:
  - `swift test --package-path macos/InsightKitApp --filter LiveReviewSourcePresentationTests`, 1 test, 0 failures
  - `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testPrepareTemporaryRecordingKeepsAudibleReviewSourceWhenVideoHasNoAudioTrack`, 1 test, 0 failures
- broad Swift gate: `swift test --package-path macos/InsightKitApp`, 156 tests, 0 failures
- installed smoke: launched `/Users/yann.jy/Applications/InsightKit.app` in Live UI-test route and quit successfully

Issue 21 is now a retest item, not an implementation candidate.

### 2026-06-25 - Issue 22 implemented

Issue 22 now has a code fix and installed-app sync proof:

- proof: `logs/workflow/latest_sync.json`
- red/green regression loop:
  - `swift test --package-path macos/InsightKitApp --filter MediaSeekRequestTests/testLiveReviewTranscriptTapRequestsPlayback --filter MediaSeekRequestTests/testLiveReviewChapterTapRequestsPlayback`, 2 tests, 0 failures
- related gate: `swift test --package-path macos/InsightKitApp --filter MediaSeekRequestTests`, 9 tests, 0 failures
- broad Swift gate: `swift test --package-path macos/InsightKitApp`, 158 tests, 0 failures

Issue 22 is now a retest item, not an implementation candidate. Retest it together with issues 20 and 21.
