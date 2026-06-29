# Manual QA Dependency Triage

Status: current
Last reviewed: 2026-06-27

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
- `.scratch/manual-qa-2026-06-25/issues/23-smart-minutes-review-source-splits-audio-and-video.md`
- `.scratch/manual-qa-2026-06-25/issues/24-smart-minutes-review-source-audio-video-out-of-sync.md`
- `.scratch/manual-qa-2026-06-25/issues/25-record-review-playback-auto-pauses-after-opening-record.md`
- `.scratch/manual-qa-2026-06-25/issues/26-saved-transcript-timestamps-must-use-final-media-timeline.md`
- `.scratch/manual-qa-2026-06-25/issues/27-record-review-playback-has-electrical-noise.md`
- `.scratch/manual-qa-2026-06-25/issues/28-audio-only-record-review-loses-speaker-rename.md`
- `.scratch/manual-qa-2026-06-25/issues/29-record-review-player-lacks-draggable-timeline.md`
- `.scratch/manual-qa-2026-06-25/issues/30-record-review-player-aspect-ratio-is-long-strip.md`
- `.scratch/manual-qa-2026-06-25/issues/31-live-workspace-can-crash-when-starting-microphone-capture.md`
- `.scratch/manual-qa-2026-06-25/issues/32-smart-minutes-finalization-lacks-speaker-rename.md`
- `.scratch/manual-qa-2026-06-25/issues/33-record-review-and-smart-minutes-should-share-canonical-meeting-asset-source.md`
- `.scratch/manual-qa-2026-06-25/issues/34-record-review-back-navigation-skips-records-workspace.md`
- `.scratch/manual-qa-2026-06-25/issues/35-session-pages-are-obscured-by-bottom-status-bar.md`
- `.scratch/manual-qa-2026-06-25/issues/36-record-folder-names-need-a-readable-standard.md`
- `.scratch/manual-qa-2026-06-25/issues/37-generated-record-titles-are-too-long-and-unstandardized.md`
- `.scratch/manual-qa-2026-06-25/issues/38-evaluate-apple-speech-framework-as-official-transcription-backend.md`
- `.scratch/manual-qa-2026-06-25/issues/39-live-final-transcription-fails-when-sidecar-cannot-find-ffmpeg.md`
- `.scratch/manual-qa-2026-06-25/issues/40-prototype-apple-speech-offline-media-transcription.md`
- `.scratch/manual-qa-2026-06-25/issues/41-main-interface-lacks-discoverable-settings-entry.md`
- `.scratch/manual-qa-2026-06-25/issues/42-apple-speech-needs-live-asr-parity-and-diarization-proof.md`
- `.scratch/manual-qa-2026-06-25/issues/43-settings-banner-action-can-crash-after-transcription-failure.md`
- `.scratch/manual-qa-2026-06-25/issues/44-live-transcription-failure-can-leave-session-unsaved-and-still-recording.md`
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

- Both passed owner retest after the Qwen MLX worker fix and regression coverage.
- Issue 06 is the highest-severity safety issue because it involved system-wide freeze/restart.
- Issue 03 is the user-visible realtime speech summary failure that shares the Qwen MLX live-runtime path.

Dependency:

- Issue 03 depends on the worker containment fix from issue 06 being present.
- Further live-recording stress tests should not proceed until issue 06 is retested cautiously.

Next action:

- No further action unless the GPU stream error or abnormal Sidecar memory growth reappears in owner QA.

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

- Issue 11 passed owner retest after code fix and installed-app sync in build `20260625123538`.
- Issue 09 passed owner retest after code fix and installed-app sync in build `20260625131608`.
- Issue 10 passed owner retest after code fix and installed-app sync in build `20260625132851`.

Triage:

- Issue 11: `LiveCaptureStateMapper` can represent normal warmup/capturing/transcribing states, but `LiveSessionViewModel.evaluateCaptureHealthHint` can still write a no-transcript hint into `errorMessage`.
- Issue 11: `ContentView` renders any `liveViewModel.errorMessage` as "实时语音总结异常", so normal warmup or waiting-for-first-transcript periods can look like summary failures.
- Issue 09: fixed in build `20260625131608`. `LiveTranscriptPipeline.refreshLiveInsight` now treats `调用超时: insight.refresh_live` as a recoverable live-analysis delay, and `LiveSessionViewModel` keeps it out of the top realtime-summary error banner when capture/transcript remain healthy.
- Issue 10: fixed in build `20260625132851`. Provider response-format failures such as `provider returned non-JSON payload` are now sanitized before reaching the Live Workspace banner, while Transcript Segments and existing Smart Minutes evidence remain available.

Dependency:

- Issue 11 should go first because it separates normal status hints from real errors.
- Issue 09 and issue 10 can share an analysis-error classifier, but they should keep separate issue records because timeout recovery and Provider response-format sanitization have different acceptance checks.

Suggested order:

No further action unless one of these live-analysis state regressions reappears.

### G. Completed Summary Review Presentation

Issue:

- `12-generated-summary-does-not-open-summary-review-interface.md`

Status:

- Owner retest passed after code fix and installed-app sync in build `20260625140443`, once the related issue 13 stop/start backlog path was handled.

Triage:

- `LiveSessionViewModel.buildFinalInsight()` can set `sessionPhase = .reviewing` after successful Final Insight Generation.
- `LiveCenterView.reviewingView` still foregrounds the media player and Transcript Segment list.
- Smart Minutes summary is mostly visible in the left chapter sidebar, so the main workspace can still look like the in-progress transcription page even when the summary is ready.
- Fixed in build `20260625140443`. Generated Smart Minutes now switch the center reviewing state into a summary-first presentation while keeping transcript and media available below the summary.

Dependency:

- Independent from the timeout fix in issue 07.
- Best handled after issue 09 and issue 10 so the completed review state is not obscured by unresolved live-analysis error banners.

Suggested next loop:

- No further action unless completed Smart Minutes review presentation regresses.

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
- Issue 16 has passed owner retest after installed fix in build `20260625222052`.
- Issue 17 has passed owner retest.
- Issue 18 has passed owner retest after installed fix in build `20260625222052`.
- Issue 19 has passed owner retest after installed fix in build `20260625222052`.
- Issue 20 has passed owner retest after follow-up issues 21-23 were handled.

Initial breakdown:

- Issue 14 is a Capture State / Session Phase feedback problem. It is about making normal waiting visible, not about the runtime failing. It now has an installed fix and has passed owner retest.
- Issue 15 is an automatic speaker diarization quality problem. It needs a concrete failing Record/audio/transcript sample before accuracy work can be verified. A separate status-presentation issue can be filed later if the desired first step is only diarization degraded-state messaging.
- Issue 16 is a manual speaker-label correction feature gap. It is related to issue 15, but it should remain separate because users need correction even when automatic diarization improves. It now has an installed first-pass rename fix.
- Issue 17 is a Smart Minutes export discoverability or capability gap from the review flow. Record export already exists elsewhere, so the likely gap is surfacing/exporting from the Smart Minutes review context. It now has an installed fix and has passed owner retest.
- Issue 18 is a default Record naming quality problem. Current Record surfaces can show technical IDs even when metadata has summary/date/source fields. It now has an installed readable display-title fix.
- Issue 19 is a manual Record rename feature gap. It is related to issue 18, but it should remain separate because better defaults do not replace user correction. It now has an installed manual rename fix.
- Issue 20 is an audible playback problem in the Smart Minutes review source area. It is separate from issue 08, which covered whether review media visually appears. It now has an installed fix and has passed owner retest after the follow-up review-source regressions were also fixed.

Dependency:

- Issue 15 is blocked on owner or test-fixture evidence. Issue 16 can proceed without waiting for issue 15.
- Issues 18 and 19 affect the same Records Workspace experience, but neither blocks the other. If issue 19 adds a manual title field, it should override issue 18's generated display name.
- Issue 17 and issue 20 both live in the Smart Minutes review experience, but they should remain separate because export and audible playback have different verification gates.
- Issue 20 may share media playback code with earlier media-chain work, but the acceptance check is different: the user must hear review source audio.
- Issue 14 has passed independent owner retest.

Suggested next loop:

- Issues 14, 16, 17, 18, 19, and 20 are no longer implementation candidates.
- Issues 21 and 22 are now `ready-for-human` after their installed Smart Minutes review-source fixes.
- Issues 16, 18, and 19 have passed owner retest as the Records naming and speaker-label correction bundle.
- Keep issue 15 at `needs-info` until a concrete failing diarization sample is available.

## Recommended Processing Order

1. Owner-retest issue 30 on installed build `20260627001232` for the residual audio-only player frame while spot-checking that video framing remains normal.
2. Owner-retest issue 31 on installed build `20260626172647` because app termination was the highest-severity remaining retest blocker.
3. Owner-retest issue 33 on installed build `20260626221051` for the canonical Meeting Asset source.
4. Review the issue 38 Apple Speech feasibility decision and decide whether to file the macOS 26+ experimental backend prototype.
5. Owner-retest issues 36 and 37 on installed build `20260627004202` after the Record Folder naming and generated Record title standards were implemented.
6. Issue 15 remains `needs-info` until a concrete failing diarization sample is available.

## Stop Rules

- Do not stress-test Live Workspace for a long session until issue 06 is manually retested.
- Do not claim issue 03 is fixed from automated tests alone; it needs installed-app owner confirmation.
- Do not turn issue 08 into broad media-architecture work without keeping it tied to the Live Session visual-capture expectation.
- Do not implement issue 15 accuracy work without a concrete failing diarization sample and expected speaker labels.
- Do not combine issue 15 and issue 16; automatic diarization quality and manual speaker correction require different verification.
- Do not combine multiple implementation fixes in one commit unless they belong to the same dependency group and share one verification gate.
- Do not treat live chunk timestamps as saved Record timestamps once final media exists; saved transcripts must use the final media timeline.

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
- issue 20: `ready-for-human`, installed Smart Minutes review source playback fix; owner retest found follow-up regressions filed as issues 21, 22, and 23.
- issue 21: `ready-for-human`, installed fix restores captured video in Smart Minutes review source after the audio fix.
- issue 22: `ready-for-human`, installed fix makes Timeline Beat and Transcript Segment clicks seek and start playback.
- issue 23: `ready-for-human`, code fix composes audio/video into one Smart Minutes review-source media file and removes separate playback surfaces.

Recommended next step: owner retest issues 20, 21, 22, 23, and 24 together as the Smart Minutes review-source bundle. Issue 18/19 can follow when the Records naming lane resumes. Issue 16 is ready but larger because it changes speaker-label persistence.

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

### 2026-06-25 - Issues 21, 22, and 23 added from issue 20 owner retest

The owner reported Smart Minutes review regressions after testing build `20260625192450` and the later issue 22 installed fix:

- issue 21: `回看资料` no longer displays captured video after the audio fix.
- issue 22: clicking Timeline Beats or Transcript Segments does not seek to the matching source position and start playback.
- issue 23: audio and video should not be split into separate playback surfaces.
- issue 24: after the single-player fix, audio and video appear out of sync in the completed Smart Minutes review experience.

Issue 21 now has an installed code fix and is `ready-for-human`. Issue 22 now has an installed code fix and is `ready-for-human`. Issue 23 now has a code fix and is `ready-for-human`. Issue 24 later received a second installed fix with system-audio E2E proof and is `ready-for-human`. Issue 25 now has an installed Record Review playback-continuity fix and is `ready-for-human`. Issues 27, 28, 29, and 30 now have installed Record Review fixes and are `ready-for-human`. The current manual-QA lane has no ready implementation candidate; issue 15 remains `needs-info`.

### 2026-06-25 - Issue 21 implemented

Issue 21 now has a code fix and installed-app sync proof:

- installed build: `20260625203632`
- proof: `logs/workflow/latest_sync.json`
- red/green regression test: `swift test --package-path macos/InsightKitApp --filter LiveReviewSourcePresentationTests/testVideoReviewSourceUsesSingleStandardPlayerEvenWhenLegacySeparateAudioExists`
- related gates:
  - `swift test --package-path macos/InsightKitApp --filter LiveReviewSourcePresentationTests`, 1 test, 0 failures
  - `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testPrepareTemporaryRecordingComposesSinglePlayableVideoWhenVideoAndAudioAreCaptured`, 1 test, 0 failures
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

Issue 22 is now a retest item, not an implementation candidate.

### 2026-06-25 - Issue 23 implemented

Issue 23 now has a code fix and test proof:

- red/green regression loop:
  - `swift test --package-path macos/InsightKitApp --filter LiveReviewSourcePresentationTests/testVideoReviewSourceUsesSingleStandardPlayerEvenWhenLegacySeparateAudioExists`
- narrow gates:
  - `swift test --package-path macos/InsightKitApp --filter LiveReviewSourcePresentationTests/testVideoReviewSourceUsesSingleStandardPlayerEvenWhenLegacySeparateAudioExists --filter LiveSessionViewModelTests/testPrepareTemporaryRecordingComposesSinglePlayableVideoWhenVideoAndAudioAreCaptured`, 2 tests, 0 failures
  - `swift test --package-path macos/InsightKitApp --filter LiveReviewSourcePresentationTests --filter LiveSessionViewModelTests/testPrepareTemporaryRecording --filter MediaSeekRequestTests`, 17 tests, 0 failures
- broad Swift gate: `swift test --package-path macos/InsightKitApp`, 158 tests, 0 failures

Issue 23 is now a retest item, not an implementation candidate. Retest it together with issues 20, 21, and 22. Issue 24 is tracked separately because owner retest failed after its installed fix.

### 2026-06-25 - Issue 24 added from Smart Minutes review-source retest

The owner reported a new Smart Minutes review-source timing symptom after the single-player audio/video composition fix: in the completed review interface, audio and video appear out of sync.

Initial classification:

- initial status: `ready-for-agent`
- likely group: Smart Minutes review-source playback timing
- distinct from issue 20 audio absence, issue 21 video absence, issue 22 click-to-seek, and issue 23 split playback surfaces

Diagnosis found that saved visual recording could start before microphone or system audio capture, while composition later treated both media files as starting at zero.

Installed fix:

- visual review recording now starts after the selected audio capture source has successfully started
- installed build: `20260625214038`
- proof: `logs/workflow/latest_sync.json`
- regression: `python -m pytest tests/test_live_review_media_sync.py -q`
- broad Swift gate: `swift test --package-path macos/InsightKitApp`, 158 tests, 0 failures

Owner retest later failed after build `20260625214038`, so the next action is another diagnosis pass rather than more owner retesting.

### 2026-06-25 - Issue 24 owner retest failed and issue 25 added

The owner reported two QA outcomes after testing the current installed app:

- issue 24 still reproduces after installed build `20260625214038`; Smart Minutes review-source audio and video remain out of sync.
- issue 25 was added because Record Review playback auto-pauses after opening a saved Record from the Records Workspace.

Current classification:

- issue 24: `ready-for-human`

- issue 25: `ready-for-human` after installed playback-continuity fix in build `20260626190326`

Dependency note:

- Issue 25 is not blocked by issue 24 because it starts from a saved Record rather than the post-session Smart Minutes review path.
- Both may share media-player behavior, but issue 24 now has installed proof and needs owner retest instead of more autonomous diagnosis.
- Issue 25 later received an installed playback-continuity fix and now needs owner retest.

### 2026-06-25 - Runtime retests passed and Records bundle implemented

The owner confirmed these previously installed runtime/review fixes are resolved:

- issue 03
- issue 06
- issue 07
- issue 09
- issue 10
- issue 11
- issue 12

Issues 16, 18, and 19 were then implemented as one Records Workspace / Record Review bundle because they share Record metadata and review surfaces while keeping separate acceptance checks.

Installed bundle:

- issue 16: speaker-label rename in Record Review.
- issue 18: readable Record display title.
- issue 19: manual Record rename persisted in metadata.

Verification:

- `swift test --package-path macos/InsightKitApp --filter RecordsIndexServiceTests/testRecordDisplayTitlePrefersManualTitleThenSummaryThenReadableFallback --filter RecordsIndexServiceTests/testRenameRecordPersistsManualTitleAndSearchUsesIt --filter RecordsIndexServiceTests/testRecordReviewRenamesSpeakerAndExportUsesCorrectedLabel`
- `swift test --package-path macos/InsightKitApp --filter RecordsIndexServiceTests --filter RecordDocumentExporterTests`
- `swift test --package-path macos/InsightKitApp`
- `bash scripts/sync_insightkit_app.sh`

Installed app:

- path: `/Users/yann.jy/Applications/InsightKit.app`
- build: `20260625222052`
- proof: `logs/workflow/latest_sync.json`

Current next action:

- owner retest for issues 16, 18, and 19 passed;
- owner retest issue 24 on installed build `20260626144645`;
- then continue with issues 27-30 unless the owner reports a new higher-priority regression or issue 24 fails again.

### 2026-06-26 - Issue 24 second fix installed and system-audio E2E passed

Issue 24 now has second-fix installed proof and is `ready-for-human`.

Fix summary:

- stop/finish visual recording before background finalization can extend video beyond audio;
- pad short composed audio to the video timeline;
- wire Live review playback time updates into the visible `回看态` state.

Verification:

- `python -m pytest tests/test_live_review_media_sync.py -q`, 3 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp --filter MediaSeekRequestTests`, 10 tests, 0 failures.
- `bash scripts/sync_insightkit_app.sh`, Swift and Python gates passed.
- installed build: `20260626144645`.
- installed-app E2E system-audio record `live-B5BD191C-0E4E-4A36-A24D-350155C1E65F` passed `scripts/diagnose_issue24_media_timeline.py` with no failures.
- Live Smart Minutes `回看资料` links at `00:22` and `00:34` sought media and left the standard player in playback state.

Current next action:

- owner retest issue 26 on installed build `20260626163854`;
- then continue with issues 27-30 unless the owner reports a new higher-priority regression.

### 2026-06-26 - Issue 26 media-timed transcript fix installed

Issue 26 now has installed proof and is `ready-for-human`.

Fix summary:

- added `asr.transcribe_media` so completed media can be transcribed on its own timeline;
- added `transcript.replace` so the runtime transcript store can be replaced before Smart Minutes generation;
- saved Records now use final media transcription segments instead of live chunk timestamps when media exists;
- final media transcription failure saves media and notes with an empty transcript instead of silently using live chunk timestamps.

Verification:

- `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testSaveToRecordsUsesPreparedLiveRecordingAsMediaSource --filter LiveSessionViewModelTests/testSaveToRecordsReplacesLiveChunkTranscriptWithFinalMediaTranscript --filter LiveSessionViewModelTests/testSaveToRecordsDoesNotFallbackToLiveChunkTranscriptWhenFinalMediaTranscriptionFails --filter LiveSessionViewModelTests/testBuildFinalInsightReplacesRuntimeTranscriptWithFinalMediaTranscriptBeforeGeneratingMinutes --filter LiveSessionViewModelTests/testSaveToRecordsPersistsGeneratedLiveInsightPackageForRecovery --filter InsightRPCClientFinalInsightTimeoutTests --filter WorkflowCoordinatorTests`, 11 tests, 0 failures.
- `python -m pytest tests/test_asr_dispatcher.py tests/test_session_handler.py tests/test_sidecar_single_instance.py tests/test_rpc_delta_refresh.py -q`, 19 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp`, 165 tests, 0 failures.
- `python -m pytest -q`, 222 tests, 0 failures, 1 warning.
- `bash scripts/sync_insightkit_app.sh`, Swift and Python gates passed.
- installed build: `20260626160503`.

Current next action:

- owner retest issue 26 by recording a new Live Workspace session, stopping before final transcription appears fully complete, reopening the saved Record, and checking that transcript row / Timeline Beat timestamps match the saved media audio;
- then continue with issues 27-30 unless issue 26 fails owner retest.

### 2026-06-26 - Issue 26 stop-before-final-transcription follow-up installed

The owner retested issue 26 on build `20260626160503` and found a follow-up failure: stopping before Final Media Transcription completed could show `最终回看资料转写失败；已保留媒体和笔记，本次转写需要重新生成。`

Follow-up fix:

- Stop now drains already captured queued audio chunks instead of clearing them after `isRunning` becomes false.
- The Live Workspace shows that it is processing remaining audio and final transcription after Stop.
- Final Media Transcription now retries transient `asr.transcribe_media` failures before saving an empty transcript.
- Finalization progress stays active until Record saving finishes.

Verification:

- `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testStopLiveSessionDrainsQueuedChunksBeforeSavingRecord --filter LiveSessionViewModelTests/testSaveToRecordsRetriesFinalMediaTranscriptionBeforeSavingEmptyTranscript --filter LiveSessionViewModelTests/testSaveToRecordsDoesNotFallbackToLiveChunkTranscriptWhenFinalMediaTranscriptionFails --filter LiveSessionViewModelTests/testSaveToRecordsReplacesLiveChunkTranscriptWithFinalMediaTranscript --filter LiveSessionViewModelTests/testBuildFinalInsightReplacesRuntimeTranscriptWithFinalMediaTranscriptBeforeGeneratingMinutes`, 5 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp`, 167 tests, 0 failures.
- `bash scripts/sync_insightkit_app.sh`, Swift and Python gates passed.
- installed build: `20260626163854`.

Current next action:

- owner retest issue 26 on installed build `20260626163854`;
- then continue with issues 27-30 unless issue 26 fails owner retest.

### 2026-06-26 - Issue 26 owner retest passed and issues 27-30 added

The owner confirmed the issue 26 stop-before-final-transcription follow-up is resolved.

New owner QA findings:

- issue 27: Record Review playback has electrical noise.
- issue 28: audio-only Record Review loses speaker rename controls.
- issue 29: Record Review player lacks a draggable media timeline.
- issue 30: Record Review player aspect ratio is a long strip.

Triage:

- issue 25 is `ready-for-human` after installed build `20260626190326`; owner retest should confirm playback continuity before relying on issue 27-30 checks.
- issue 27 is `ready-for-human` after installed build `20260626203055`; it covers audio headroom and clipping prevention for fresh Record Review media.
- issue 28 is `ready-for-human` after installed build `20260626200713`; it is a regression of issue 16 in the audio-only Record Review state and should remain separate from media playback controls.
- issue 29 is `ready-for-human` after installed build `20260626192237`; it covers the standard draggable Media Timeline control surface.
- issue 30 is `ready-for-human` after installed build `20260626192237`; it covers media frame/aspect presentation and is separate from whether playback can seek.

Recommended order:

1. Owner-retest issue 25 on installed build `20260626190326`.
2. Owner-retest issues 29 and 30 on installed build `20260626192237`.
3. Owner-retest issue 27 on installed build `20260626203055` with a fresh recording.
4. Owner-retest issue 28 on installed build `20260626200713`.

### 2026-06-26 - Issue 31 added from intermittent crash report

The owner reported an intermittent app crash and attached a macOS crash report.

Crash report summary:

- installed build: `20260626163854`;
- exception type: `EXC_CRASH (SIGABRT)`;
- termination: `Abort trap: 6`;
- triggered thread: background cooperative queue;
- crash signature: microphone capture startup calls `AVAudioNode.installTap`, and AVFAudio raises an Objective-C exception.

Triage:

- issue 31 moved from `ready-for-agent` to `ready-for-human` after an installed microphone capture startup fix;
- the fix serializes microphone AVAudioEngine graph mutations and makes duplicate start requests idempotent;
- issue 31 remains higher severity than playback UX, but it now needs owner retest rather than more agent work.

Verification:

- `swift test --package-path macos/InsightKitApp --filter MicCaptureServiceTests`
- `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests`
- `swift test --package-path macos/InsightKitApp` passed: 170 tests, 0 failures.
- `bash scripts/sync_insightkit_app.sh` installed build `20260626172647`.
- `codesign --verify --deep --strict --verbose=2 /Users/yann.jy/Applications/InsightKit.app` passed.

Recommended order:

1. Owner-retest issue 31 in installed build `20260626172647` with repeated microphone start/stop.
2. Owner-retest issues 29 and 30 in installed build `20260626192237`.
3. Return to issues 27 and 28 unless the owner chooses another blocker.

### 2026-06-26 - Issue 25 implemented

Issue 25 now has an installed Record Review playback-continuity fix and is `ready-for-human`.

Diagnosis:

- Record Review passed `isPlaying: false` to the shared `MediaPlayerView`.
- User playback produced time updates, time updates refreshed SwiftUI state, and the next view update applied `pause()` again.
- This made Record Review playback appear to start and then automatically pause.

Fix:

- `MediaPlayerView` now treats `isPlaying == nil` as user-controlled playback.
- Explicit `true` still means host-controlled play, and explicit `false` still means host-controlled pause.
- Record Review and related passive media-player surfaces no longer pass forced pause when the user should control playback.

Verification:

- `swift test --package-path macos/InsightKitApp --filter MediaSeekRequestTests`, 12 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp`, 172 tests, 0 failures.
- `bash scripts/sync_insightkit_app.sh` installed build `20260626190326`.
- `codesign --verify --deep --strict --verbose=2 /Users/yann.jy/Applications/InsightKit.app` passed.

Recommended order:

1. Owner-retest issue 25 on installed build `20260626190326`.
2. Owner-retest issues 29 and 30 on installed build `20260626192237`.
3. Owner-retest issue 27 on installed build `20260626203055` with a fresh recording.

### 2026-06-26 - Issues 29 and 30 implemented

Issues 29 and 30 now have an installed shared review-player UX fix and are `ready-for-human`.

Diagnosis:

- Audio review used `.minimal` AVKit controls, which did not provide the expected mature draggable Media Timeline.
- Review media surfaces stretched to full center-column width with only a height cap, creating a long-strip video frame in wide layouts.
- Record Review, Smart Minutes review, and Import review wrapped the same player separately, increasing the chance of inconsistent playback UX.

Fix:

- `MediaPlayerView` now uses AVKit `.default` controls for audio and video review media.
- `MediaPlayerView` sets video gravity to `.resizeAspect`.
- `ReviewMediaPlayerView` now centralizes review-player layout across Record Review, Smart Minutes review, and Import review.
- `ReviewMediaPlayerLayout` constrains video to a stable 16:9 review frame and audio to a compact audio bar.

Verification:

- RED loop failed before implementation against missing layout policy and old audio control expectations.
- `swift test --package-path macos/InsightKitApp --filter MediaSeekRequestTests`, 15 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp`, 175 tests, 0 failures.
- `bash scripts/sync_insightkit_app.sh` installed build `20260626192237`.
- `codesign --verify --deep --strict --verbose=2 /Users/yann.jy/Applications/InsightKit.app` passed.

Recommended order:

1. Owner-retest issues 28, 29, and 30 on their installed builds.
2. Owner-retest issue 27 on installed build `20260626203055` with a fresh recording.

### 2026-06-26 - Issue 28 fixed and installed

Issue 28 moved from `ready-for-agent` to `ready-for-human` after an installed audio-only speaker-rename fix.

Dependency note:

- This issue stayed separate from issues 29 and 30 because it is not a player-control or aspect-ratio bug.
- It is a speaker-correction regression from issue 16. The shared dependency is Record Review transcript presentation, not media playback.

Verification:

- RED loop failed before implementation because `RecordSpeakerRenamePresentation` did not exist.
- Focused issue28 tests passed.
- `swift test --package-path macos/InsightKitApp --filter RecordsIndexServiceTests` passed: 14 tests, 0 failures.
- Full Swift test suite passed before sync, and `bash scripts/sync_insightkit_app.sh` reran the full sync gate successfully.
- Installed build: `20260626200713`.
- Codesign verification passed.

Next queue state:

- issue 27: `ready-for-human`
- issue 28: `ready-for-human`
- issue 29: `ready-for-human`
- issue 30: `ready-for-human`

### 2026-06-26 - Issue 27 fixed and installed

Issue 27 moved from `ready-for-agent` to `ready-for-human` after an installed audio headroom / clipping-prevention fix.

Dependency note:

- This issue shared the media capture/save path with issues 24 and 25, but its acceptance check is audio quality, not sync or playback continuity.
- Existing Records that already contain clipped WAV samples may remain noisy. Owner retest should use a fresh recording on build `20260626203055`.

Verification:

- RED loop failed before implementation because mixed audio could reach full-scale `1.0` and WAV output could contain `Int16.max` samples.
- Focused RED/GREEN loop passed after implementation.
- Related audio/save gate passed: 11 tests, 0 failures.
- Full Swift gate passed: 178 tests, 0 failures.
- Standard sync passed Swift and Python gates and installed build `20260626203055`.
- Codesign verification passed.

Next queue state:

- issue 27: `ready-for-human`
- issue 28: `ready-for-human`
- issue 29: `ready-for-human`
- issue 30: `ready-for-human`
- issue 15: `needs-info`

### 2026-06-26 - Follow-up QA intake for issues 27, 32, 33, and 34

The owner retested issue 27 and reported that the electrical noise still reproduced. The previous audio headroom fix was therefore not sufficient, and issue 27 returned to `ready-for-agent` at that point. A later canonical media-source fix moved issue 27 back to `ready-for-human`.

Updated issue 27 direction:

- prefer the originally recorded media as the canonical review source;
- avoid extra media transformation when Record Review or Smart Minutes review can play the already captured source;
- if composition is unavoidable, prove that the composed review media does not add electrical noise compared with the original captured media.

Issue 28 was clarified as mis-scoped and is superseded by issue 32. The owner did not primarily need an extra speaker control in Record Review; the missing workflow is speaker-name correction inside the Smart Minutes finalization/result surface.

New issues:

- issue 32: `ready-for-agent`, Smart Minutes finalization lacks speaker rename controls;
- issue 33: `ready-for-agent`, Record Review and Smart Minutes should share one canonical Meeting Asset source;
- issue 34: `ready-for-agent`, Record Review back navigation skips the Records Workspace.

Recommended order:

1. Owner-retest issue 27 on installed build `20260626210922`.
2. Implement issue 33 if code still lets Record Review and Smart Minutes silently diverge for the same Record.
3. Implement issue 32, because it corrects the speaker-rename workflow placement.
4. Implement issue 34 independently as a navigation-flow fix.

### 2026-06-26 - Issue 33 canonical Meeting Asset decision

Decision map:

- `.scratch/manual-qa-2026-06-25/canonical-meeting-asset-decision-map.md`

Resolved rule:

- Record Review and Smart Minutes are two views over one canonical Meeting Asset source.
- The canonical source includes the review media, Media-Timed Transcript, speaker-name mapping, notes, and Insight Package.
- Playback surfaces should use the original saved recording directly when it is clean and playable.
- Derived media should be a fallback or a single verified canonical review media source, not an invisible per-surface replacement.

Queue impact:

- issue 33 moves from `needs-info` to `ready-for-agent`;
- issue 27 should use this rule rather than another isolated audio limiter pass;
- issue 32 should use the same shared speaker-name mapping rule.

### 2026-06-26 - Issue 27 canonical media-source fix installed

Issue 27 moved back to `ready-for-human` after an installed canonical media-source fix.

Diagnosis:

- The prior audio limiter pass did not solve the owner-reported electrical noise.
- The next RED loop proved that the save path did not inspect whether the original captured video already had audio; it would still compose a second review video from separate audio chunks.
- Local media inspection showed both cases exist in saved Records: some `recording.mp4` files have `audio:aac`, while others are video-only.

Fix:

- Added media asset inspection.
- Kept original video as canonical review media when it already has an audio track.
- Kept composition only as a fallback for video-only recordings with separate audio.

Verification:

- focused RED/GREEN media-save loop passed;
- `LiveSessionViewModelTests` passed: 43 tests, 0 failures;
- full Swift suite passed: 179 tests, 0 failures;
- standard sync passed Swift/Python gates and installed build `20260626210922`;
- codesign verification passed.

Queue impact:

- issue 27: `ready-for-human`
- issue 32: `ready-for-agent`
- issue 33: `ready-for-agent`
- issue 34: `ready-for-agent`

### 2026-06-26 - Issue 27 owner retest passed and issue 32 installed

Issue 27 basically passed owner retest after the canonical media-source fix. Minor residual noise remains, but the owner judged it likely comes from the microphone/source rather than InsightKit adding electrical playback noise.

Issue 32 moved from `ready-for-agent` to `ready-for-human` after an installed Smart Minutes speaker-rename fix.

Decision carried forward:

- speaker-name edits are Meeting Asset corrections, not cosmetic edits in one view;
- Smart Minutes finalization/review and Record Review should use one shared speaker-name mapping outcome;
- Record Review should not show an extra duplicate speaker-rename strip when an existing workflow already exists.

Verification:

- focused RED/GREEN: `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testLiveSmartMinutesSpeakerRenameUpdatesRuntimeMinutesPackageAndPersistedRecord`;
- related Swift gates: `LiveSessionViewModelTests` and `RecordsIndexServiceTests` / `RecordDocumentExporterTests`;
- full Swift gate: 180 tests, 0 failures;
- standard sync passed Swift/Python gates, including 139 Python tests, and installed build `20260626214019`;
- codesign verification passed.

Current queue state:

- issue 27: owner retest basically passed
- issue 32: `ready-for-human`
- issue 33: `ready-for-agent`
- issue 34: `ready-for-agent`

### 2026-06-26 - Issue 32 owner retest passed and issue 33 installed

Issue 32 passed owner retest after the Smart Minutes speaker-rename placement fix.

Issue 33 moved from `ready-for-agent` to `ready-for-human` after an installed canonical Meeting Asset source fix.

Diagnosis:

- Record Review loaded flattened `minutes.json` and reconstructed speaker summaries from transcript rows.
- Smart Minutes and live finalization persisted the fuller `insight_package.json`.
- Export also read the flattened minutes path, so the same Record could look different across Record Review, Smart Minutes, and exported Markdown/PDF.

Fix:

- Added a shared `MeetingAssetSnapshot` reader for Record Folder assets.
- Record Review now prefers `insight_package.json` when available and falls back to `minutes.json`.
- Export now uses the same Meeting Asset snapshot for Smart Minutes, notes, and media selection.
- Import recovery and thumbnail generation now use the same canonical `recording.*` selection rule.
- Record Review-generated Smart Minutes now persist the full `insight_package.json`.

Verification:

- focused RED/GREEN Record Review canonical package test passed;
- focused RED/GREEN export canonical package test passed;
- related gate passed: `RecordsIndexServiceTests`, `RecordDocumentExporterTests`, and `MediaSeekRequestTests`, 35 tests, 0 failures;
- full Swift suite passed: 182 tests, 0 failures;
- standard sync passed Swift/Python gates, including 139 Python tests, and installed build `20260626221051`;
- codesign verification passed.

Current queue state:

- issue 27: owner retest basically passed
- issue 32: owner retest passed
- issue 33: `ready-for-human`
- issue 34: `ready-for-agent`

### 2026-06-26 - Issue 34 installed

Issue 34 moved from `ready-for-agent` to `ready-for-human` after an installed Record Review back-navigation fix.

Diagnosis:

- The top app navigation treated every non-home route the same and showed a generic Home Workspace action.
- Record Review is a nested state inside the Records Workspace, so that generic action skipped the expected previous level.

Fix:

- Added shared Records Workspace navigation state.
- The primary toolbar action now returns from Record Review to the Records Workspace list.
- The Records Workspace list and other non-home workflows still use the Home Workspace action.

Verification:

- focused RED/GREEN workflow navigation test passed;
- `WorkflowCoordinatorTests` passed: 6 tests, 0 failures;
- full Swift suite passed: 183 tests, 0 failures;
- standard sync passed Swift/Python gates, including 139 Python tests, and installed build `20260626222305`;
- codesign verification passed.

Current queue state:

- issue 27: owner retest basically passed
- issue 32: owner retest passed
- issue 33: `ready-for-human`
- issue 34: `ready-for-human`
- issue 15: `needs-info`
- no manual-QA issue is currently `ready-for-agent`

### 2026-06-26 - Owner retest update and issues 35-38 filed

The owner reported:

- fixed: issues 20, 21, 22, 23, 24, 25, 29, and 34;
- partially fixed: issue 30, where video playback framing is normal but audio-only playback still has a strange aspect/frame;
- uncertain: issue 31 has not been repeatedly tested yet.

Issue 30 moves back to `ready-for-agent` for the residual audio-only player layout problem. Keep the now-passing video framing behavior intact.

New issue split:

- issue 35: `ready-for-human` after installed bottom-status-bar layout fix in build `20260627001915`;
- issue 36: `ready-for-human` after installed readable Record Folder naming fix in build `20260627004202`;
- issue 37: `ready-for-human` after installed generated-title standard fix in build `20260627004202`;
- issue 38: `ready-for-human` after feasibility decision, evaluate Apple Speech framework as an official transcription backend.

Dependency notes:

- Issue 35 is independent from transcription/runtime correctness; it is a Session Shell layout/content-inset problem.
- Issues 36 and 37 should stay separate: issue 36 is on-disk Record Folder naming, while issue 37 is the user-visible generated title standard.
- Issue 38 is a research spike before implementation; it should not replace the existing Whisper/FunASR/Qwen ASR choices without a feasibility decision.

Current queue state:

- issue 30: `ready-for-human` after residual audio-only player-frame fix in build `20260627001232`
- issue 31: `ready-for-human`
- issue 33: `ready-for-human`
- issue 35: `ready-for-human` after installed bottom-status-bar layout fix in build `20260627001915`
- issue 36: `ready-for-human`
- issue 37: `ready-for-human`
- issue 38: `ready-for-human` after feasibility decision
- issue 15: `needs-info`
- issue 28: `wontfix`

### 2026-06-27 - Issue 30 residual audio-only frame fix installed

Issue 30 moved from `ready-for-agent` back to `ready-for-human` after a focused residual fix for the audio-only playback frame.

Diagnosis:

- The previous issue 30 fix normalized video framing, but audio-only review still used a shallow player bar that could read as another long strip.
- Record Review now passes the Record's canonical media type into the shared review-player layout instead of relying only on file extension inference.

Verification:

- focused RED/GREEN covered the compact audio panel, metadata-driven audio override, and Record media type mapping;
- `swift test --package-path macos/InsightKitApp --filter MediaSeekRequestTests`, 17 tests, 0 failures;
- `swift test --package-path macos/InsightKitApp`, 185 tests, 0 failures;
- standard sync's Python unittest gate was blocked by the local Homebrew Python environment missing `pytest`, `faster-whisper`, and `silero-vad`;
- installed sync succeeded with the already-passed Swift gate via `scripts/sync_insightkit_app.sh --install-dir /Users/yann.jy/Applications --skip-tests`;
- installed build: `20260627001232`; proof: `logs/workflow/latest_sync.json`.

Current queue state:

- issue 30: `ready-for-human`
- issue 31: `ready-for-human`
- issue 33: `ready-for-human`
- issue 35: `ready-for-human`
- issue 36: `ready-for-human`
- issue 37: `ready-for-human`
- issue 38: `ready-for-human` after feasibility decision
- issue 15: `needs-info`
- issue 28: `wontfix`

### 2026-06-27 - Issue 35 bottom status bar layout fix installed

Issue 35 moved from `ready-for-agent` to `ready-for-human` after an installed layout fix.

Diagnosis:

- The bottom status bar was rendered through `safeAreaInset(edge: .bottom)`.
- Session pages use mixed SwiftUI/AppKit layout surfaces, including `HSplitView`, so relying on safe-area propagation could let scrollable content render below the bottom chrome.

Fix:

- Added `BottomStatusBarLayout` for explicit bottom chrome height and content-height reservation.
- Non-home routes now render content and `BottomStatusBarView` as separate rows in a `VStack`, so the status bar occupies real layout space instead of overlaying workspace content.
- Home still does not reserve bottom status bar space.

Verification:

- RED loop failed before implementation because `BottomStatusBarLayout` did not exist.
- `swift test --package-path macos/InsightKitApp --filter BottomStatusBarLayoutTests`, 3 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp`, 188 tests, 0 failures.
- Standard sync's Python unittest gate remains blocked by the local Homebrew Python environment missing `pytest`, `faster-whisper`, and `silero-vad`.
- Installed sync succeeded with the already-passed Swift gate via `scripts/sync_insightkit_app.sh --install-dir /Users/yann.jy/Applications --skip-tests`.
- Installed build: `20260627001915`; proof: `logs/workflow/latest_sync.json`.

Current queue state:

- issue 30: `ready-for-human`
- issue 31: `ready-for-human`
- issue 33: `ready-for-human`
- issue 35: `ready-for-human`
- issue 36: `ready-for-human`
- issue 37: `ready-for-human`
- issue 38: `ready-for-human` after feasibility decision
- issue 15: `needs-info`
- issue 28: `wontfix`

### 2026-06-27 - Issue 38 Apple Speech feasibility decision recorded

Issue 38 moved from `ready-for-agent` to `ready-for-human` after a focused research spike recorded the product and technical decision in `.scratch/manual-qa-2026-06-25/apple-speech-framework-feasibility.md`.

Decision:

- Do not replace the current Whisper / FunASR / Qwen3-ASR local runtime with Apple Speech as the default ASR Engine.
- Consider a follow-up prototype for an experimental, availability-gated Apple Speech backend on macOS 26+ using `SpeechAnalyzer` + `SpeechTranscriber`.
- Keep the older `SFSpeechRecognizer` out of the official default meeting-transcription path because it does not fit the app's long-form, local-first transcription requirements.

Current queue state:

- issue 30: `ready-for-human`
- issue 31: `ready-for-human`
- issue 33: `ready-for-human`
- issue 35: `ready-for-human`
- issue 36: `ready-for-human`
- issue 37: `ready-for-human`
- issue 38: `ready-for-human`

### 2026-06-27 - Issue 24 audio/video timeline regression fixed after microphone audio recovery

Issue 24 remains `ready-for-human` after a new owner report showed the audio/video sync problem could still recur once microphone audio was successfully captured.

Observed sample:

- Record Folder: `20260627-1008-live-record-bbe1a3f0`.
- Meeting ID: `live-CFD54B99-3528-470E-90B1-910EBBE1A3F0`.
- Saved media had audio duration `39.950s` and video duration `47.002s`.
- `scripts/diagnose_issue24_media_timeline.py` failed with stream delta `7.052s`.
- Transcript markers stayed inside the shorter audio timeline, so this was a media timeline problem rather than an ASR timestamp overflow.

Implementation:

- `ReviewMediaComposer` now composes independent audio/video sources onto the shortest playable media timeline instead of padding a short audio track to a longer video track.
- `AVFoundationMediaAssetInspector` now reads playable media duration.
- Live `records.save` now prefers actual media duration for Record metadata when a media file exists.

Verification:

- `python -m pytest tests/test_live_review_media_sync.py -q`, 3 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp --filter ReviewMediaComposerTests/testComposeVideoWithAudioTrimsVideoToShorterAudioTimeline`, 1 test, 0 failures.
- `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testSaveToRecordsUsesPlayableMediaDurationWhenAvailable`, 1 test, 0 failures.
- `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testPrepareTemporaryRecordingComposesSinglePlayableVideoWhenVideoAndAudioAreCaptured`, 1 test, 0 failures.
- `swift test --package-path macos/InsightKitApp`, 195 tests, 0 failures.
- Installed sync succeeded with the already-passed gates via `./scripts/sync_insightkit_app.sh --skip-tests`.
- Installed build: `20260627101746`; proof: `logs/workflow/latest_sync.json`.

Current queue state:

- issue 24: `ready-for-human`
- issue 30: `ready-for-human`
- issue 31: `ready-for-human`
- issue 33: `ready-for-human`
- issue 35: `ready-for-human`
- issue 36: `ready-for-human`
- issue 37: `ready-for-human`
- issue 38: `ready-for-human`
- issue 39: `ready-for-human`
- issue 15: `needs-info`
- issue 28: `wontfix`

### 2026-06-27 - Issue 24 offset-aware media timeline fix installed

Issue 24 remains `ready-for-human` after a third installed synchronization fix.

The owner confirmed the previous duration-level trim still left perceptible audio/video sync problems. New evidence showed the latest final `recording.mp4` could have equal audio/video durations while the temporary source video was much longer than the temporary audio, meaning the composer could still choose the wrong source window.

Fix:

- `ReviewMediaComposer` now composes the audio/video source-window intersection on a shared media timeline.
- Live capture records video start and first audio start in `LiveMediaCaptureTimeline`.
- Video start is tightened to the first actually written video frame.
- New live records persist `capture_timeline.json` so diagnostics can show the selected composition offset.
- `scripts/diagnose_issue24_media_timeline.py` now warns when a video record has equal stream durations but no capture timeline sidecar.

Proof:

- `swift test --package-path macos/InsightKitApp --filter ReviewMediaComposerTests`, 2 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testPrepareTemporaryRecordingComposesSinglePlayableVideoWhenVideoAndAudioAreCaptured --filter LiveSessionViewModelTests/testPrepareTemporaryRecordingPassesCaptureTimelineToReviewMediaComposer`, 2 tests, 0 failures.
- `python -m pytest tests/test_live_review_media_sync.py -q`, 3 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp`, 197 tests, 0 failures.
- `python -m pytest -q`, 225 tests, 0 failures, 1 warning.
- Installed sync succeeded via `./scripts/sync_insightkit_app.sh --skip-tests`.
- Installed build: `20260627104951`; proof: `logs/workflow/latest_sync.json`.

Current status at that point:

- issue 24: `ready-for-human`
- issue 30: `ready-for-human`
- issue 31: `ready-for-human`
- issue 33: `ready-for-human`
- issue 35: `ready-for-human`
- issue 36: `ready-for-human`
- issue 37: `ready-for-human`
- issue 38: `ready-for-human`
- issue 39: `ready-for-human`
- issue 15: `needs-info`
- issue 28: `wontfix`

### 2026-06-27 - Issue 39 live final transcription failure diagnosed and fixed

Issue 39 moved from owner report to `ready-for-human` after diagnostics found two separate failure contributors in the reported session `live-A82D25D9-77EC-4813-9984-4DD063A528DD`.

Findings:

- The sidecar ASR runtime was otherwise healthy, but direct final media transcription initially failed because GUI-launched sidecar environment could not find `ffmpeg`.
- The same session's temporary media was also effectively silent (`mean_volume/max_volume = -91.0 dB`), so after fixing `ffmpeg` lookup, ASR correctly returned no segments for that particular recording.
- App logs showed microphone capture started and stopped, so the remaining owner retest focus is selected input device / mute / mic level rather than sidecar model readiness.

Implementation:

- `PythonRuntimeEnvironment.prepared` preserves existing `PATH` and appends common executable paths, including `/opt/homebrew/bin`, so sidecar media decoding can find Homebrew `ffmpeg`.
- `SidecarManager.startIfNeeded` now checks app/sidecar build mismatch even when an existing sidecar socket passes `ensureReady`.
- `ChunkAssembler` tracks emitted chunk RMS.
- live review-source preparation treats near-digital-silent chunks as no captured audio instead of generating a silent final transcription source.

Verification:

- Direct RPC before the fix: `asr.transcribe_media` failed with `[Errno 2] No such file or directory: 'ffmpeg'`.
- Direct RPC after the PATH fix: `asr.transcribe_media` no longer failed with missing `ffmpeg`; it returned empty segments because the reported media was silent.
- `swift test --package-path macos/InsightKitApp --filter SidecarBuildMismatchRecoveryTests`, 5 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp --filter ChunkAssemblerTests`, 3 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testPrepareTemporaryRecordingTreatsNearSilentChunksAsNoCapturedAudio`, 1 test, 0 failures.
- `swift test --package-path macos/InsightKitApp`, 193 tests, 0 failures.
- Installed sync succeeded with the already-passed Swift gate via `scripts/sync_insightkit_app.sh --skip-tests`.
- Installed build: `20260627095346`; proof: `logs/workflow/latest_sync.json`.

Current queue state:

- issue 30: `ready-for-human`
- issue 31: `ready-for-human`
- issue 33: `ready-for-human`
- issue 35: `ready-for-human`
- issue 36: `ready-for-human`
- issue 37: `ready-for-human`
- issue 38: `ready-for-human`
- issue 39: `ready-for-human`
- issue 15: `needs-info`
- issue 28: `wontfix`

### 2026-06-27 - Issues 36 and 37 naming-standard fixes installed

Issues 36 and 37 moved from `needs-triage` to `ready-for-human` after the naming standards were specified and installed together.

Decision:

- Keep issue 36 scoped to on-disk Record Folder names.
- Keep issue 37 scoped to user-visible generated Record titles.
- Preserve `metadata.json.id` as the canonical Record identity; readable folder names do not migrate or replace stable IDs.

Implementation:

- Python `RecordWriter` writes new folders as `YYYYMMDD-HHMM-{live|import}-{topic-slug}-{shortid}`.
- Python `RecordWriter` reuses an existing folder for the same `meeting_id` by reading `metadata.json`.
- Swift `RecordsIndexService` resolves Record folders by metadata ID, so legacy ID folders and new readable folders both work.
- Record Review, Reveal in Finder, rename persistence, delete, native export, and completed-import artifact loading use the shared resolver.
- `RecordMetadata.displayTitle` caps generated titles at 44 characters after whitespace/bullet cleanup; manual titles still override generated titles.

Verification:

- `python -m pytest tests/test_record_writer.py -q`, 22 tests, 0 failures.
- `python -m pytest tests/test_record_writer.py tests/test_record_e2e.py tests/test_transcription_runner_local_fallback.py -q`, 32 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp --filter RecordsIndexServiceTests`, 17 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp`, 190 tests, 0 failures.
- Standard sync's Homebrew Python 3.14 `unittest` gate remains blocked by missing `pytest`, `faster-whisper`, and `silero-vad`.
- Installed sync succeeded with the already-passed Swift and focused Python gates via `scripts/sync_insightkit_app.sh --install-dir /Users/yann.jy/Applications --skip-tests`.
- Installed build: `20260627004202`; proof: `logs/workflow/latest_sync.json`.

Current queue state:

- issue 30: `ready-for-human`
- issue 31: `ready-for-human`
- issue 33: `ready-for-human`
- issue 35: `ready-for-human`
- issue 36: `ready-for-human`
- issue 37: `ready-for-human`
- issue 38: `ready-for-human`
- issue 15: `needs-info`
- issue 28: `wontfix`

### 2026-06-27 - Issue 24 retimed-frame attempt worsened sync; return to triage

Issue 24 is no longer `ready-for-human` and must not be picked up as an implementation task.

Owner retest reported build `20260627110552` made the audio/video sync worse. The latest inspected record, `20260627-1114-live-record-1a9935ba`, demonstrates why the current diagnostic gate is insufficient:

- final saved media passed duration-level diagnostics: audio `8.705s`, video `8.705s`, format `8.705s`;
- temp source media still diverged: audio `10.000s`, video-only `23.356667s`;
- `scripts/diagnose_issue24_media_timeline.py` produced no failures despite the owner-visible regression.

Next state:

- issue 24: `needs-triage`

Next action:

- Stop implementing in the current context.
- Build `20260627112556` only rolls back the worsened retimed-frame experiment; it is not a fix claim.
- Use the handoff document from this work session to start a fresh diagnosis session.
- Build a red-capable feedback loop that catches visible video lag before any further production code changes.

### 2026-06-27 - Issue 24 red-capable source-timeline loop added

Issue 24 moves from `needs-triage` to `ready-for-agent`.

The fresh diagnosis session extended `scripts/diagnose_issue24_media_timeline.py` so it no longer passes from final-media duration equality alone. It now reads `capture_timeline.json`, probes the temp source `videoPath` and `audioPath`, and fails when the source video timeline is much longer than the source audio/final media timeline.

Real bad-sample proof:

- `20260627-1056-live-record-e69519e2`: final media audio/video are both `41.900s`, but temp source video is `63.381667s` and source audio is `42.000000s`; diagnostic exits `1`.
- `20260627-1114-live-record-1a9935ba`: final media audio/video are both `8.705s`, but temp source video is `23.356667s` and source audio is `10.000000s`; diagnostic exits `1`.
- Proof files:
  - `logs/diagnostics/2026-06-27/issue24-1056-source-timeline-red.json`
  - `logs/diagnostics/2026-06-27/issue24-1114-source-timeline-red.json`

Current status at that point:

- issue 24: `ready-for-agent`
- issue 30: `ready-for-human`
- issue 31: `ready-for-human`
- issue 33: `ready-for-human`
- issue 35: `ready-for-human`
- issue 36: `ready-for-human`
- issue 37: `ready-for-human`
- issue 38: `ready-for-human`
- issue 39: `ready-for-human`
- issue 15: `needs-info`
- issue 28: `wontfix`

Next action at that point:

- Target capture/writer time-base proof, likely by adding first/last host-time and PTS instrumentation or a throwaway AV capture/writer prototype before changing production behavior again.
- Do not mark issue 24 `ready-for-human` until a new installed capture passes the source-timeline diagnostic and owner-visible playback check.

### 2026-06-27 - Issue 24 capture-clock video writer fix installed

Issue 24 moves from `ready-for-agent` to `ready-for-human`.

Diagnosis:

- The red source-timeline loop caught a pre-composition video-source duration expansion that final-media duration checks could not catch.
- The production video writer still used raw sample-buffer PTS as the writer session clock.
- The installed fix candidate now uses capture callback host time as the video writer clock and starts the writer session at zero.

Implementation:

- `VideoCaptureService` samples `ProcessInfo.processInfo.systemUptime` before `writerQueue.async`.
- `VideoRecordingTimeline` maps frames onto a monotonic zero-based recording clock.
- Video samples are copied with new presentation timestamps before being appended to `AVAssetWriter`.

Verification:

- `swift test --package-path macos/InsightKitApp --filter VideoRecordingTimelineTests`, 2 tests, 0 failures.
- `python -m pytest tests/test_live_review_media_sync.py -q`, 5 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp`, 199 tests, 0 failures.
- `git diff --check`, 0 failures.
- `codesign --verify --deep --strict /Users/yann.jy/Applications/InsightKit.app`, passed.
- Installed sync: `./scripts/sync_insightkit_app.sh --skip-tests`, build `20260627115314`.
- Sync proof: `logs/workflow/latest_sync.json`.

Current status at that point:

- issue 24: `ready-for-human`
- issue 30: `ready-for-human`
- issue 31: `ready-for-human`
- issue 33: `ready-for-human`
- issue 35: `ready-for-human`
- issue 36: `ready-for-human`
- issue 37: `ready-for-human`
- issue 38: `ready-for-human`
- issue 39: `ready-for-human`
- issue 15: `needs-info`
- issue 28: `wontfix`

Owner retest:

- Test issue 24 with a new installed-app Live Workspace capture, not an old Record Folder.
- Run `python3 scripts/diagnose_issue24_media_timeline.py <new Record Folder>` after saving the new record.
- Expected: no source-timeline failure, and owner-visible `回看资料` video/audio timing is acceptable.

### 2026-06-27 - Issue 24 owner retest passed

Issue 24 remains a completed `ready-for-human` issue after owner retest confirmed the capture-clock video writer fix in installed build `20260627115314`.

Result:

- New installed-app capture: owner-visible Smart Minutes `回看资料` audio/video timing is acceptable.
- Old failed records remain diagnostic fixtures because their source media was already written with old timing.
- Issue 24 stays separate from issue 25, which covers saved Record Review playback continuity rather than Smart Minutes capture-source synchronization.

Current status:

- owner retest passed: issues 01, 02, 03, 04, 05, 06, 07, 08, 09, 10, 11, 12, 13, 14, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 29, 32, and 34
- issue 30: `ready-for-human`
- issue 31: `ready-for-human`
- issue 33: `ready-for-human`
- issue 35: `ready-for-human`
- issue 36: `ready-for-human`
- issue 37: `ready-for-human`
- issue 38: `ready-for-human`
- issue 39: `ready-for-human`
- issue 15: `needs-info`
- issue 28: `wontfix`

Next action at that point:

- No further issue 24 action unless a new installed-app capture reproduces audio/video desynchronization.
- Continue owner retest on issues 30, 33, 35, 36, 37, and 39; repeat-test issue 31; review the issue 38 Apple Speech decision when ready.

### 2026-06-27 - Owner retests passed and issue 38 promoted to prototype issue

The owner confirmed issues 39, 35, 26, 27, 30, and 33 are resolved.

Ask Matt route for issue 38:

- Do not send issue 38 back through triage; it already has a feasibility decision.
- Treat the accepted Apple Speech direction as a single narrow prototype issue.
- Keep the prototype independent and implementation-ready so it can start from a fresh context.

Issue 38 decision:

- Do not replace Whisper / FunASR / Qwen3-ASR as InsightKit's default local ASR engines.
- Do not use older `SFSpeechRecognizer` as the official meeting transcription path.
- Create an experimental macOS 26+ Apple Speech backend prototype using `SpeechAnalyzer` / `SpeechTranscriber`, scoped to offline saved media first.

Follow-up filed:

- `.scratch/manual-qa-2026-06-25/issues/40-prototype-apple-speech-offline-media-transcription.md`

Current status:

- owner retest passed: issues 01, 02, 03, 04, 05, 06, 07, 08, 09, 10, 11, 12, 13, 14, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 29, 30, 32, 33, 34, 35, and 39
- issue 40: `ready-for-human`
- issue 31: `ready-for-human`
- issue 36: `ready-for-human`
- issue 37: `ready-for-human`
- issue 38: `ready-for-human` as a completed decision record
- issue 15: `needs-info`
- issue 28: `wontfix`

Next action:

- Owner-retest issue 40's Apple Speech experimental audio final-media toggle in installed build `20260627145522`.
- Owner-retest issues 36 and 37 when convenient.
- Repeat-test issue 31 before calling the microphone startup crash fully resolved.

### 2026-06-27 - Issue 40 Apple Speech prototype installed

Issue 40 moved from `ready-for-agent` to `ready-for-human`.

Implementation summary:

- Added a macOS 26+ availability-guarded Swift `AppleSpeechTranscriptionService`.
- Added Settings runtime diagnostics plus the explicit experimental toggle `保存音频最终媒体时使用 Apple Speech 原型`.
- Routed saved final-media transcription through an injectable final-media transcriber; Apple Speech is used only for audio final-media files when the experimental toggle is enabled. Video final media stays on the existing local ASR path.
- Preserved Whisper / FunASR / Qwen3-ASR as the current default local ASR engines.
- Added packaged `NSSpeechRecognitionUsageDescription`.
- Added locale matching for Apple Speech identifiers such as `zh-Hans` -> `zh_CN`.
- Added `SO_NOSIGPIPE` protection for Sidecar lifecycle socket writes after the test fixture exposed a SIGPIPE setup failure.

Verification:

- `swift test --package-path macos/InsightKitApp --filter AppleSpeechTranscriptionServiceTests`, 7 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp --filter AppConfigStoreTests`, 6 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests`, 49 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp`, 209 tests, 0 failures.
- Real local Apple Speech smoke on macOS 26.6 with `zh_CN`: one segment returned from `start=0.0`.
- `git diff --check`, passed.
- `bash -n scripts/package_insightkit_app.sh scripts/release_preflight.sh`, passed.
- Installed sync: `./scripts/sync_insightkit_app.sh --skip-tests`, build `20260627145522`.
- Installed Info.plist check: `NSSpeechRecognitionUsageDescription` present in `/Users/yann.jy/Applications/InsightKit.app`.
- `codesign --verify --deep --strict /Users/yann.jy/Applications/InsightKit.app`, passed.
- Sync proof: `logs/workflow/latest_sync.json`.

Current status:

- owner retest passed: issues 01, 02, 03, 04, 05, 06, 07, 08, 09, 10, 11, 12, 13, 14, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 29, 30, 32, 33, 34, 35, and 39
- issue 31: `ready-for-human`
- issue 36: `ready-for-human`
- issue 37: `ready-for-human`
- issue 38: `ready-for-human` as a completed decision record
- issue 40: `ready-for-human`
- issue 15: `needs-info`
- issue 28: `wontfix`

Next action:

- Owner-retest issue 40 in installed build `20260627145522`: open Settings, confirm Apple Speech experimental status, enable `保存音频最终媒体时使用 Apple Speech 原型`, save a new audio final-media recording, and confirm transcript rows are generated from Apple Speech on the saved media timeline. Also confirm video final media still uses the current local ASR path.
- Keep issue 40 scoped as an experimental prototype, not a default ASR replacement.

### 2026-06-27 - Owner QA filed issues 41 and 42; issue 31 retest failed

Owner QA against installed build `20260627145522` produced three separate findings:

- Issue 31 retest failed again with a crash report showing `EXC_CRASH (SIGABRT)` on `InsightKit.MicCapture.Control` while installing the microphone capture tap.
- Issue 41 filed a discoverability gap: the main app interface lacks an obvious Settings Workspace entry, and the bottom status bar does not expose Settings options.
- Issue 42 filed the stronger Apple Speech product expectation: Apple Speech should not be treated as a peer local ASR Engine until realtime Live Workspace transcription, strict-local runtime state, Media-Timed Transcript behavior, and Diarization parity are proven.

Apple Speech capability note:

- The Xcode 26 Speech SDK exposes `SpeechAnalyzer` async input and `SpeechTranscriber` presets for progressive live transcription, offline transcription, time-indexed live captioning, and time-indexed offline transcription with alternatives.
- The observed public SDK surface exposes transcript text, alternatives, confidence, and audio time ranges, but no meeting-speaker Diarization contract.
- Therefore issue 42 should be a parity spike: prove whether Apple Speech can be combined with InsightKit's existing local Diarization path before exposing it as a same-level local ASR Engine.

Current status:

- owner retest passed: issues 01, 02, 03, 04, 05, 06, 07, 08, 09, 10, 11, 12, 13, 14, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 29, 30, 32, 33, 34, 35, and 39
- issue 31: `ready-for-human`
- issue 36: `ready-for-human`
- issue 37: `ready-for-human`
- issue 38: `ready-for-human` as a completed decision record
- issue 40: `ready-for-human`
- issue 41: `ready-for-human`
- issue 42: `ready-for-agent`
- issue 15: `needs-info`
- issue 28: `wontfix`

Next action:

- Owner-retest issue 31 in installed build `20260627153026` because app termination blocks reliable owner QA.
- Owner-retest issue 41's Settings Workspace entry point in installed build `20260627154910`.
- Then run issue 42's Apple Speech realtime-ASR parity and Diarization spike.

### 2026-06-27 - Issue 31 Obj-C exception-safe microphone startup fix installed

Issue 31 moved back to `ready-for-human`.

Implementation summary:

- Added `InsightKitObjCShims`, a SwiftPM Objective-C shim target for catching `NSException`.
- Added `ObjCExceptionBridge.perform` and wrapped `AVAudioNode.installTap` during microphone startup.
- Converted tap-installation Objective-C exceptions into recoverable microphone startup errors.
- Preserved the serial microphone control queue and retry cleanup from the earlier issue 31 fix.

Verification:

- Red-capable proof: standalone Swift `NSInvalidArgumentException` reproduction exits with `Abort trap: 6`.
- `swift test --package-path macos/InsightKitApp --filter MicCaptureServiceTests`, 5 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests`, final rerun 49 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp`, 211 tests, 0 failures.
- `git diff --check`, passed.
- `bash -n scripts/package_insightkit_app.sh`, passed.
- `bash -n scripts/release_preflight.sh`, passed.
- Installed sync: `./scripts/sync_insightkit_app.sh --skip-tests`, build `20260627153026`.
- Installed app proof: `logs/workflow/latest_sync.json`, `/Users/yann.jy/Applications/InsightKit.app/Contents/Info.plist`, and `codesign --verify --deep --strict --verbose=2 /Users/yann.jy/Applications/InsightKit.app`.

Current status:

- owner retest passed: issues 01, 02, 03, 04, 05, 06, 07, 08, 09, 10, 11, 12, 13, 14, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 29, 30, 32, 33, 34, 35, and 39
- issue 31: `ready-for-human`
- issue 36: `ready-for-human`
- issue 37: `ready-for-human`
- issue 38: `ready-for-human` as a completed decision record
- issue 40: `ready-for-human`
- issue 41: `ready-for-human`
- issue 42: `ready-for-agent`
- issue 15: `needs-info`
- issue 28: `wontfix`

Next action:

- Owner-retest issue 31 on installed build `20260627153026` with repeated Live Workspace microphone or mixed-audio start/stop cycles.
- Owner-retest issue 41 on installed build `20260627154910`.
- Then continue issue 42.

### 2026-06-27 - Issue 41 Settings Workspace entry fix installed

Issue 41 moved from `ready-for-agent` to `ready-for-human`.

Implementation summary:

- Home Workspace now has a visible `设置` button with a gear icon.
- Bottom status bar now exposes a visible `设置` action on non-home workspace routes.
- Both visible actions route through `WorkflowCoordinator.openSettings()` and preserve the existing macOS menu command.

Verification:

- Red check: `swift test --package-path macos/InsightKitApp --filter WorkflowCoordinatorTests` initially failed until `openSettings()` and `BottomStatusAction.settings` existed.
- `swift test --package-path macos/InsightKitApp --filter WorkflowCoordinatorTests`, 8 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp`, 213 tests, 0 failures.
- `git diff --check`, passed.
- `bash -n scripts/package_insightkit_app.sh`, passed.
- `bash -n scripts/release_preflight.sh`, passed.
- Installed sync: `./scripts/sync_insightkit_app.sh --skip-tests`, build `20260627154910`.
- Installed app proof: `logs/workflow/latest_sync.json`, `/Users/yann.jy/Applications/InsightKit.app/Contents/Info.plist`, and `codesign --verify --deep --strict --verbose=2 /Users/yann.jy/Applications/InsightKit.app`.
- Visual GUI Proof: `logs/diagnostics/2026-06-27/issue41-home-settings-entry.png`.
- Visual GUI Proof: `logs/diagnostics/2026-06-27/issue41-live-bottom-status-settings-entry.png`.

Current status:

- owner retest passed: issues 01, 02, 03, 04, 05, 06, 07, 08, 09, 10, 11, 12, 13, 14, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 29, 30, 32, 33, 34, 35, and 39
- issue 31: `ready-for-human`
- issue 36: `ready-for-human`
- issue 37: `ready-for-human`
- issue 38: `ready-for-human` as a completed decision record
- issue 40: `ready-for-human`
- issue 41: `ready-for-human`
- issue 42: `ready-for-agent`
- issue 15: `needs-info`
- issue 28: `wontfix`

Next action at that point:

- Owner-retest issue 41 in installed build `20260627154910`.
- Superseded by the next update: issue 41 owner retest passed, then issue 42 was implemented.

### 2026-06-27 - Issue 41 owner retest passed and issue 42 parity gate installed

Issue 41 passed owner retest.

Issue 42 moved from `ready-for-agent` to `ready-for-human`.

Decision/proof doc:

- `.scratch/manual-qa-2026-06-25/apple-speech-live-parity-and-diarization.md`

Classification:

- Apple Speech live transcription remains plausible on macOS 26+ because `SpeechAnalyzer` can support live analyzer input.
- Apple Speech is not ready to become a peer local ASR Engine because Live Workspace integration, Diarization, and Record/Smart Minutes parity are not proven.
- The observed public Apple Speech transcription API still does not provide a meeting-speaker Diarization contract, so peer parity requires either a separate Apple speaker API proof or a bridge into InsightKit's existing local Diarization component.

Implementation:

- Added a testable `AppleSpeechPeerEngineParityStatus` gate.
- Added `AppleSpeechRuntimeStatus.shouldExposePeerLocalASREngineOption`.
- Kept `LocalASREngine` limited to Whisper, FunASR, and Qwen3-ASR MLX.
- Updated Settings so the Apple Speech card explicitly says it is an experimental audio final-media prototype and not a peer ASR Engine yet.
- Listed blockers for strict-local readiness, Live Workspace realtime transcription, Diarization, and Record/Smart Minutes parity.

Verification:

- Red check: `swift test --package-path macos/InsightKitApp --filter AppleSpeechTranscriptionServiceTests` initially failed because the parity gate did not exist.
- `swift test --package-path macos/InsightKitApp --filter AppleSpeechTranscriptionServiceTests`, 9 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp --filter AppConfigStoreTests`, 7 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp`, 216 tests, 0 failures.
- `git diff --check`, passed.
- `bash -n scripts/package_insightkit_app.sh`, passed.
- `bash -n scripts/release_preflight.sh`, passed.
- Installed sync: `./scripts/sync_insightkit_app.sh --skip-tests`, build `20260627161028`.
- Installed app proof: `logs/workflow/latest_sync.json`, `/Users/yann.jy/Applications/InsightKit.app/Contents/Info.plist`, and `codesign --verify --deep --strict --verbose=2 /Users/yann.jy/Applications/InsightKit.app`.

Current status:

- owner retest passed: issues 01, 02, 03, 04, 05, 06, 07, 08, 09, 10, 11, 12, 13, 14, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 29, 30, 32, 33, 34, 35, 39, and 41
- issue 31: `ready-for-human`
- issue 36: `ready-for-human`
- issue 37: `ready-for-human`
- issue 38: `ready-for-human` as a completed decision record
- issue 40: `ready-for-human`
- issue 42: `ready-for-human`
- issue 15: `needs-info`
- issue 28: `wontfix`
- `ready-for-agent`: none

Next action:

- Owner-retest issue 42 in installed build `20260627161028` from Settings.
- Confirm Apple Speech is visibly not a peer ASR Engine yet and that the ordinary ASR Engine picker still only lists Whisper, FunASR, and Qwen3-ASR MLX.
- Continue owner retests for issue 31, issue 40, issue 36, and issue 37 when convenient.

### 2026-06-27 - Owner QA crash and transcription failure filed as issues 43 and 44

Owner QA against installed build `20260627161028` reported a new crash and transcription failure.

Classification:

- Issue 43 is a recovery-route crash. The crash happens when using the visible Settings action from an in-app banner after a transcription failure. It is independent from issue 31 because the crash report points at the Settings banner action path, not microphone tap startup.
- Issue 44 is a Live transcription failure / recovery issue. The owner reported failed transcription, no new saved Record was found for the latest QA attempt, and the latest Live state may remain active instead of becoming a recoverable post-session Record.

Dependency:

- Issue 43 should go first because it can terminate the app while the user is trying to recover from transcription failure.
- Issue 44 can start independently, but its acceptance check should include behavior when issue 43 no longer masks the failed-transcription path.

Current status:

- owner retest passed: issues 01, 02, 03, 04, 05, 06, 07, 08, 09, 10, 11, 12, 13, 14, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 29, 30, 32, 33, 34, 35, 39, and 41
- issue 31: `ready-for-human`
- issue 36: `ready-for-human`
- issue 37: `ready-for-human`
- issue 38: `ready-for-human` as a completed decision record
- issue 40: `ready-for-human`
- issue 42: `ready-for-human`
- issue 43: `ready-for-agent`
- issue 44: `ready-for-agent`
- issue 15: `needs-info`
- issue 28: `wontfix`

Next action:

- Implement issue 43 first, with a focused crash repro or UI-path regression proving the Settings action is safe.
- Then implement issue 44, with evidence that a failed transcription preserves a recoverable session or saved Record.
