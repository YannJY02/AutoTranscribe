# Manual QA Session 2026-06-25

Status: ready-for-human

## Purpose

Record owner-led manual QA for the currently installed InsightKit app and turn each reported user-visible problem into a durable local markdown issue.

This lane is for discovery and issue filing, not for immediate implementation. Implementation should happen later through individual `ready-for-agent` issues.

High-severity safety note: issue 06 reports system-wide freeze/restart after Sidecar memory grew to roughly 30 GB. Treat it as the highest priority QA finding in this lane.

Issue 06 now has a code-level resource-containment fix installed in build `20260625094746`; it still needs a short, guarded owner retest before further Live Workspace stress testing.

Issue 03 now has Sidecar RPC regression coverage for the raw Qwen MLX GPU stream error; it still needs owner Live Workspace retest to confirm the user-visible speech-summary banner is gone.

Issue 11 now has a code-level status-channel fix installed in build `20260625123538`; it needs owner retest.

Issue 09 now has a code-level recoverable live-analysis timeout fix installed in build `20260625131608`; it needs owner retest.

Issue 10 now has a code-level Provider response-format sanitizer installed in build `20260625132851`; it needs owner retest.

Issue 12 now has a code-level completed-summary review presentation fix installed in build `20260625140443`; owner retest conditionally passed when issue 13's stop/start backlog problem does not occur.

Issue 13 has a code-level Live Session stop/start boundary fix installed in build `20260625165436`; owner retest passed.

Issue 14 has a code-level Live Workspace progress-feedback fix installed in build `20260625183127`; owner retest passed.

Issue 17 has a code-level Smart Minutes review export fix installed in build `20260625185114`; owner retest passed.

Issue 20 has a code-level Smart Minutes review-source audio fix installed in build `20260625192450`; owner retest found follow-up regressions now filed as issues 21 and 22.

Issue 21 has a code-level Smart Minutes review-source video fix installed in build `20260625203632`; it needs owner retest.

Batch dependency triage is recorded in `.scratch/manual-qa-2026-06-25/triage-dependency-map.md`. Issues 01, 02, 04, 05, 08, 13, 14, 17, and conditionally 12 have passed owner retest after their installed fixes; issues 03, 06, 07, 09, 10, 11, 20, and 21 are `ready-for-human` for owner retest after installed fixes. Issues 16, 18, 19, and 22 are `ready-for-agent`; issue 15 is `needs-info` for a concrete diarization sample.

## Test Baseline

- App: InsightKit
- Installed app path: `/Users/yann.jy/Applications/InsightKit.app`
- Bundle version: `0.1.0`
- Build version: `20260625003524`
- Git revision: `1463cd7`
- Build source: `local-workspace-clean`
- Sync proof: `logs/workflow/latest_sync.json`
- QA date: 2026-06-25

Latest fix sync:
- Build version: `20260625203632`
- Git revision: `61883f7`
- Build source: `local-workspace-dirty`
- Scope: issue 21 Smart Minutes review-source video display

## Recording Rules

For each issue the owner reports:

1. Capture the behavior in the owner's words.
2. Ask at most 2-3 short clarifying questions only when expected behavior, actual behavior, reproduction steps, or consistency is unclear.
3. Explore the relevant app or domain context before filing, but do not put brittle file paths or line numbers in the issue body.
4. Use InsightKit domain language from `docs/contexts/product/CONTEXT.md` and `docs/contexts/macos-app/CONTEXT.md`.
5. Create one issue per independently fixable behavior under `.scratch/manual-qa-2026-06-25/issues/`.
6. Prefer `Status: needs-triage` unless the issue is already fully specified and can be safely marked `ready-for-agent`.

## Issue Template

```markdown
# <durable user-facing title>

Status: needs-triage

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

<actual behavior>

## What I expected

<expected behavior>

## Steps to reproduce

1. <step>

## Additional context

<notes from manual QA and background context>

## Comments

### 2026-06-25 - Manual QA

Reported during owner-led manual QA against InsightKit build `20260625003524`.
```

## Current Issue Log

- `.scratch/manual-qa-2026-06-25/issues/01-live-capture-preview-stays-black.md` - Live capture preview stays black after enabling camera or screen capture. Code fix installed in build `20260625113541`; owner retest passed.
- `.scratch/manual-qa-2026-06-25/issues/02-camera-preview-aspect-ratio-is-overly-wide.md` - Camera preview aspect ratio is overly wide during live recording. Code fix installed in build `20260625113541`; owner retest passed.
- `.scratch/manual-qa-2026-06-25/issues/03-live-insight-refresh-fails-with-gpu-stream-sidecar-error.md` - Live Insight Refresh fails with GPU stream sidecar error during recording. Worker fix installed and RPC regression coverage added; owner retest required.
- `.scratch/manual-qa-2026-06-25/issues/04-live-notes-entry-is-not-discoverable-or-usable.md` - Live notes entry is not discoverable or usable during recording. Code fix installed in build `20260625115936`; owner retest passed.
- `.scratch/manual-qa-2026-06-25/issues/05-live-summary-error-open-settings-does-not-open-settings.md` - Live summary error banner cannot open Settings Workspace. Code fix installed in build `20260625102417`; owner retest passed.
- `.scratch/manual-qa-2026-06-25/issues/06-live-sidecar-memory-spike-can-freeze-and-restart-system.md` - Live Sidecar memory spike can freeze and restart the system. Code fix installed; guarded owner retest required.
- `.scratch/manual-qa-2026-06-25/issues/07-final-insight-generation-times-out-after-live-session.md` - Final Insight Generation times out after a live session.
- `.scratch/manual-qa-2026-06-25/issues/08-live-review-media-does-not-display-video.md` - Live review media does not display video. Code fix installed in build `20260625113541`; owner retest passed.
- `.scratch/manual-qa-2026-06-25/issues/09-live-insight-refresh-timeout-shown-as-error-while-capture-continues.md` - Live Insight Refresh timeout is shown as an error while capture continues. Code fix installed in build `20260625131608`; owner retest required.
- `.scratch/manual-qa-2026-06-25/issues/10-provider-non-json-payload-shown-as-realtime-summary-error.md` - Provider non-JSON payload is shown as a realtime summary error. Code fix installed in build `20260625132851`; owner retest required.
- `.scratch/manual-qa-2026-06-25/issues/11-runtime-warmup-delay-can-be-misclassified-as-summary-failure.md` - Runtime Warmup delay can be misclassified as a summary failure. Code fix installed in build `20260625123538`; owner retest required.
- `.scratch/manual-qa-2026-06-25/issues/12-generated-summary-does-not-open-summary-review-interface.md` - Generated summary does not open the summary review interface. Code fix installed in build `20260625140443`; owner retest conditionally passed when issue 13 does not occur.
- `.scratch/manual-qa-2026-06-25/issues/13-live-session-stop-start-can-continue-previous-transcription-backlog.md` - Live session stop/start can continue previous transcription backlog. Code fix installed in build `20260625165436`; owner retest passed.
- `.scratch/manual-qa-2026-06-25/issues/14-live-workspace-loading-states-lack-progress-feedback.md` - Live Workspace loading states lack progress feedback. Code fix installed in build `20260625183127`; owner retest passed.
- `.scratch/manual-qa-2026-06-25/issues/15-speaker-diarization-can-fail-or-label-speakers-incorrectly.md` - Speaker diarization can fail or label speakers incorrectly. Triaged as `needs-info` pending a concrete failing sample.
- `.scratch/manual-qa-2026-06-25/issues/16-speaker-labels-cannot-be-edited-after-transcription.md` - Speaker labels cannot be edited after transcription. Triaged as `ready-for-agent`.
- `.scratch/manual-qa-2026-06-25/issues/17-smart-minutes-cannot-be-exported-from-review-flow.md` - Smart Minutes cannot be exported from the review flow. Code fix installed in build `20260625185114`; owner retest passed.
- `.scratch/manual-qa-2026-06-25/issues/18-record-default-names-are-hard-to-read.md` - Record default names are hard to read. Triaged as `ready-for-agent`.
- `.scratch/manual-qa-2026-06-25/issues/19-records-cannot-be-renamed.md` - Records cannot be renamed. Triaged as `ready-for-agent`.
- `.scratch/manual-qa-2026-06-25/issues/20-smart-minutes-review-source-playback-has-no-audio.md` - Smart Minutes review source playback has no audio. Code fix installed in build `20260625192450`; owner retest found follow-up regressions tracked as issues 21 and 22.
- `.scratch/manual-qa-2026-06-25/issues/21-smart-minutes-review-source-loses-video-after-audio-fix.md` - Smart Minutes review source loses video after the audio fix. Code fix installed in build `20260625203632`; owner retest required.
- `.scratch/manual-qa-2026-06-25/issues/22-smart-minutes-review-source-seek-does-not-start-playback.md` - Smart Minutes review source seek does not start playback. Triaged as `ready-for-agent`.
- `.scratch/manual-qa-2026-06-25/triage-dependency-map.md` - Batch dependency triage for issues 01-22.

## Comments

### 2026-06-25 - QA lane opened

InsightKit was synced and launched from `/Users/yann.jy/Applications/InsightKit.app` before the session started.

Verification baseline:
- `bash scripts/sync_insightkit_app.sh` -> success
- Swift package tests -> passed
- Python unit tests -> `Ran 136 tests ... OK`
- Running process path verified as `/Users/yann.jy/Applications/InsightKit.app/Contents/MacOS/InsightKitApp`

### 2026-06-25 - QA paused after issue 03 diagnosis

Owner-led QA intake is paused with five issues recorded.

Issue 03 was taken through one `diagnosing-bugs` loop and installed into `/Users/yann.jy/Applications/InsightKit.app` build `20260625090217`. Owner retest still reproduced `There is no Stream(gpu, 2) in current thread`, so issue 03 remains open. Remaining QA issues also stay open for later triage or implementation.

### 2026-06-25 - System restart / Sidecar memory issue added

The owner reported a system freeze/restart after InsightKit memory grew to roughly 30 GB during Live Workspace QA. Diagnostic review showed a watchdog panic and a `python3.11` Sidecar process at about 29.4 GiB resident memory. This was recorded as issue 06 and should be treated as the highest-priority QA finding before further live-recording stress testing.

### 2026-06-25 - Issue 06 code fix installed

Issue 06 was diagnosed with a resource-safe automated loop that reproduced unbounded Qwen MLX session growth without loading the real model. The fix routes Qwen MLX work through one long-lived worker thread per model source instead of caching one session per Sidecar caller thread.

Verification summary:
- targeted red/green Qwen MLX worker test passed
- related ASR/Sidecar tests passed
- full Python pytest suite passed
- sync-script Swift and Python gates passed with Python 3.11 first in `PATH`
- installed app build `20260625094746` was verified with `codesign --verify --deep --strict`

Standard `scripts/sync_insightkit_app.sh` first failed under Xcode Python 3.9, then reached packaging but failed on `dist/macos` extended-attribute signing detritus. The sync script now uses a `/tmp` package output by default, and the final standard sync succeeded with build `20260625094746`.

### 2026-06-25 - Issue 03 RPC regression coverage added

Issue 03 was continued after the issue 06 worker fix. Added a real `InsightRPCServer` regression test that runs `asr.prewarm` and concurrent short-connection `asr.transcribe_chunk` calls with a fake Qwen MLX session that raises `There is no Stream(gpu, 2) in current thread` if any live chunk uses the wrong GPU stream owner.

Verification summary:
- mutation check against the old caller-thread-scoped loader produced `mutation_red_errors=3`
- targeted RPC regression test passed
- Qwen MLX thread-affinity tests passed
- related ASR/Sidecar/RPC tests passed
- full Python pytest suite passed

No additional installed-app sync was required because the runtime worker fix was already installed in build `20260625094746`; the new work adds regression coverage and updates issue state.

### 2026-06-25 - Issues 07 and 08 added from owner QA

The owner continued manual QA on installed build `20260625094746`.

New issues recorded:
- issue 07: Final Insight Generation can time out with `调用超时: insight.build_final` after a live session reaches review/post-session state.
- issue 08: Live review media shows a dark generic playback placeholder instead of displaying the recorded video.

Both issues are separate from the raw Qwen MLX GPU stream Sidecar error. Issue 07 is a final insight/retry-state problem, while issue 08 is a review media display problem.

### 2026-06-25 - Batch dependency triage completed

Batch triage recorded the dependency groups in `.scratch/manual-qa-2026-06-25/triage-dependency-map.md`.

Current issue state after later QA updates:
- owner retest passed: issues 01, 02, and 08 after the Capture Preview / Record Review media-chain fix.
- owner retest passed: issue 04 after the Time-Bound Notes UX fix.
- `ready-for-human`: issues 03 and 06, because they need guarded installed-app owner retest.
- owner retest passed: issue 05.
- `ready-for-human`: issue 07, because the Final Insight Generation timeout fix is installed and needs owner retest.
- `ready-for-human`: issue 09, because the recoverable live Insight Refresh timeout fix is installed and needs owner retest.
- `ready-for-human`: issue 10, because the Provider non-JSON payload sanitizer is installed and needs owner retest.
- `ready-for-human`: issue 11, because the Runtime Warmup / waiting-for-transcript status-channel fix is installed and needs owner retest.
- conditional owner retest passed: issue 12, because the completed-summary review presentation works when issue 13's stop/start backlog problem does not prevent the flow from reaching the post-session Smart Minutes choice.
- owner retest passed: issue 13 after the Live Session stop/start boundary fix.
- owner retest passed: issue 14 after the Live Workspace progress-feedback fix.
- owner retest passed: issue 17 after the Smart Minutes review export fix.
- `ready-for-human`: issue 20, because the Smart Minutes review-source audio fix is installed and needs owner retest.
- `ready-for-agent`: issues 16, 18, and 19 after batch triage and later fixes.
- `needs-info`: issue 15, because automatic speaker diarization accuracy needs a concrete failing sample.

Recommended current next action:
1. Retest issue 20 in the installed app when the owner is ready.
2. Retest issues 09, 10, and 11 if not already covered by the same Live Workspace pass.
3. Retest issues 03, 06, and 07 when the owner is ready.
4. Provide a concrete failing speaker diarization sample before issue 15 can move past `needs-info`.

### 2026-06-25 - Issue 05 code fix installed

Issue 05 was diagnosed and fixed with a red-capable regression loop. The installed app at `/Users/yann.jy/Applications/InsightKit.app` now contains build `20260625102417`, which passes sync verification in `logs/workflow/latest_sync.json`.

### 2026-06-25 - Issue 09 added from owner QA

The owner confirmed that issue 05's `打开设置` banner action now works in the installed app.

During the same QA pass, a new realtime speech-summary banner appeared:

`调用超时: insight.refresh_live`

The owner observed that the Live Workspace still felt usable: capture continued, transcript rows were visible, and Smart Minutes had useful content. This was recorded as issue 09 and should be triaged as a recoverable live Insight Refresh degradation problem, separate from issue 07's post-session `insight.build_final` timeout.

### 2026-06-25 - Issues 10 and 11 added from owner QA

The owner provided a mixed QA report from meeting `live-37056EA5-F6A0-44D6-9701-7E500A5935AE` and asked for precise issue splitting.

New issues recorded:
- issue 10: Provider non-JSON payload appears as a raw realtime speech-summary error while transcript and Smart Minutes evidence remains useful.
- issue 11: early Runtime Warmup or delayed first Transcript Segment can be misclassified as a realtime summary failure.

Existing issues updated:
- issue 08: added another review-state media placeholder example from the same meeting.
- issue 09: added evidence that `insight.refresh_live` timeout can recover while the live session continues.

### 2026-06-25 - Issue 12 added from owner QA

The owner reported that after transcription ended and summary generation should have led into a summary interface, the app still looked like the transcription page with transcript rows and only a basic Smart Minutes summary visible.

Issue 12 records this as a completed-summary presentation and Session Phase transition problem. It is separate from issue 07 because the summary had already been generated.

### 2026-06-25 - Issues 01, 02, and 08 media-chain fix installed

Issues 01, 02, and 08 were handled as one Capture Preview / Record Review media-chain pass because they share the visual source, preview layout, and review media contract.

Verification summary:
- issue 01 red/green test: `LiveSessionViewModelTests/testVisualPreviewPlanRoutesScreenOnlySelectionToScreenPreview`
- issue 02 red/green tests: `LiveSessionViewModelTests/testCameraPreviewLayerUsesAspectFitToAvoidCropping`, `LiveSessionViewModelTests/testRunningPreviewLayoutPreservesStandardMediaAspectRatio`
- issue 08 red/green tests: `LiveSessionViewModelTests/testPrepareTemporaryRecordingPrefersExistingVideoRecordingForReview`, `LiveSessionViewModelTests/testPrepareTemporaryRecordingShowsAudioOnlyStatusWhenExpectedVideoIsMissing`
- media-chain target gate passed for all five tests
- full Swift gate passed: `swift test --package-path macos/InsightKitApp`, 135 tests, 0 failures
- standard sync passed Swift and Python gates; Python unittest suite reported `Ran 136 tests ... OK`

Installed proof:
- installed app: `/Users/yann.jy/Applications/InsightKit.app`
- installed build: `20260625113541`
- git revision: `1463cd7`
- build source: `local-workspace-dirty`
- proof: `logs/workflow/latest_sync.json`

Owner retest should cover:
- camera-only and screen-only preview no longer silently black
- camera preview no longer appears as an overly wide cropped strip
- review media shows video when visual frames are captured, or an explicit audio-only fallback when video frames were not saved

### 2026-06-25 - Issues 01, 02, and 08 owner retest passed

The owner confirmed that the shared Capture Preview / Record Review media-chain fix was successful.

### 2026-06-25 - Issue 04 code fix installed

Issue 04 now has a Time-Bound Notes UX fix installed in build `20260625115936`. The right-side notes panel uses a large multi-line composer near the top of the panel instead of a tiny bottom single-line input. Proof: `logs/workflow/latest_sync.json`.

### 2026-06-25 - Issue 04 owner retest passed

The owner confirmed that the Time-Bound Notes UX fix was successful in the installed app.

### 2026-06-25 - Issues 09-12 focused triage completed

Focused triage originally promoted issues 09, 10, 11, and 12 to `ready-for-agent`; later comments record their installed fixes and current `ready-for-human` retest state.

Recommended order:

1. issue 11 - separate warmup/waiting states from error banners;
2. issue 09 - treat recoverable `insight.refresh_live` timeout as live analysis degradation;
3. issue 10 - sanitize Provider non-JSON payload errors while preserving useful transcript and Smart Minutes state;
4. issue 12 - make successful summary generation open a clear completed review experience.

### 2026-06-25 - Issue 11 code fix installed

Issue 11 now has a Runtime Warmup / waiting-for-first-transcript status-channel fix installed in build `20260625123538`.

Verification summary:

- red/green test: `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testWaitingForFirstTranscriptUsesRecordingStatusInsteadOfErrorBanner`
- related ViewModel gate: `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests`
- full Swift gate: `swift test --package-path macos/InsightKitApp`, 139 tests, 0 failures
- standard sync passed Swift and Python gates; Python reported `Ran 136 tests ... OK`

Installed proof:

- installed app: `/Users/yann.jy/Applications/InsightKit.app`
- installed build: `20260625123538`
- proof: `logs/workflow/latest_sync.json`

Owner retest should confirm that waiting for the first Transcript Segment no longer appears as a top realtime-summary exception.

### 2026-06-25 - Issue 09 code fix installed

Issue 09 now has a recoverable live Insight Refresh timeout fix installed in build `20260625131608`.

Verification summary:

- red/green pipeline and ViewModel timeout tests first failed, then passed:
  - `swift test --package-path macos/InsightKitApp --filter LiveTranscriptPipelineTests/testLiveRefreshTimeoutDegradesWithoutThrowingWhileKeepingTranscript --filter LiveSessionViewModelTests/testProcessChunkTreatsLiveRefreshTimeoutAsRecoverableStatus`
- related Live Transcript Pipeline / Live Session ViewModel gate passed: 35 tests, 0 failures
- full Swift gate passed: `swift test --package-path macos/InsightKitApp`, 141 tests, 0 failures
- standard sync installed build `20260625131608` into `/Users/yann.jy/Applications/InsightKit.app`

Installed proof:

- installed app: `/Users/yann.jy/Applications/InsightKit.app`
- installed build: `20260625131608`
- proof: `logs/workflow/latest_sync.json`

Owner retest should confirm that a single `insight.refresh_live` timeout no longer appears as the top realtime-summary exception while capture, transcript rows, and existing Smart Minutes continue.

### 2026-06-25 - Issue 10 code fix installed

Issue 10 now has a Provider non-JSON payload sanitizer installed in build `20260625132851`.

Verification summary:

- red/green Provider response-format tests first failed, then passed:
  - `swift test --package-path macos/InsightKitApp --filter LiveTranscriptPipelineTests/testProviderNonJSONPayloadDegradesWithSanitizedMessageWhileKeepingTranscript --filter LiveSessionViewModelTests/testPublishErrorSanitizesProviderNonJSONPayloadError`
- related Live Transcript Pipeline / Live Session ViewModel gate passed: 37 tests, 0 failures
- full Swift gate passed: `swift test --package-path macos/InsightKitApp`, 143 tests, 0 failures
- standard sync passed Swift and Python gates; Python reported `Ran 136 tests ... OK`
- standard sync installed build `20260625132851` into `/Users/yann.jy/Applications/InsightKit.app`

Installed proof:

- installed app: `/Users/yann.jy/Applications/InsightKit.app`
- installed build: `20260625132851`
- proof: `logs/workflow/latest_sync.json`

Owner retest should confirm that Provider non-JSON payload failures no longer expose raw parser details such as `line 42` or `char 1169`, while transcript rows and existing Smart Minutes remain visible.

### 2026-06-25 - Issue 12 code fix installed

Issue 12 now has a completed-summary review presentation fix installed in build `20260625140443`.

Verification summary:

- red/green presentation-plan tests first failed, then passed:
  - `swift test --package-path macos/InsightKitApp --filter LiveReviewPresentationPlanTests`
- full Swift gate passed: `swift test --package-path macos/InsightKitApp`, 145 tests, 0 failures
- standard sync passed Swift and Python gates; Python reported `Ran 136 tests ... OK`
- standard sync installed build `20260625140443` into `/Users/yann.jy/Applications/InsightKit.app`

Installed proof:

- installed app: `/Users/yann.jy/Applications/InsightKit.app`
- installed build: `20260625140443`
- proof: `logs/workflow/latest_sync.json`

Owner retest should confirm that after successful Smart Minutes or Final Insight generation, the center workspace foregrounds the generated summary review instead of looking like the in-progress transcript page.

### 2026-06-25 - Issue 12 conditional owner retest passed

The owner reported that issue 12 conditionally passes: if issue 13 does not occur, the generated-summary review experience works normally.

Residual risk:

- issue 13 can still interfere before summary generation by keeping the Live Workspace in a delayed transcription state or skipping the post-session Smart Minutes choice.

### 2026-06-25 - Issue 13 added from owner QA

The owner reported an intermittent Live Workspace stop/start boundary problem: after clicking stop and then clicking "开始直播洞察" again, the app can continue delayed transcription from the previous run instead of presenting the Smart Minutes choice for the stopped session.

Issue 13 records this as a Session Phase / Live Transcript Pipeline backlog boundary problem. It is separate from issue 12 because issue 12 covered successful summary review presentation after generation, while issue 13 covers the session not reliably reaching the post-session Smart Minutes choice when stop/start actions happen around delayed transcription.

Current classification:

- issue 13 status: `ready-for-human`
- group: Live Workspace session boundary and delayed transcript backlog handling
- installed build: `20260625165436`
- next action: owner retest in the installed app

### 2026-06-25 - Issue 13 code fix installed

Issue 13 now has a Live Session stop/start boundary fix installed in build `20260625165436`.

Diagnosis:

- The app set `isRunning` to false immediately when the user clicked stop, but the old Live Session still had an `activeMeetingID` while finalization ran on the background pipeline queue.
- `WorkflowCoordinator.livePhase` ignored that still-active meeting and returned the UI to `livePreparing`.
- `canStartSession` only checked `!isRunning`, so a new start action could be accepted before the old session boundary was fully closed.

Implemented behavior:

- A Live Session can no longer start while an unresolved `activeMeetingID` exists.
- The coordinator now treats a stopped-but-still-active Live Session as `livePostSession`.
- Stop finalization captures the meeting ID at stop time, before asynchronous finalization work begins.

Verification summary:

- red/green regression: `swift test --package-path macos/InsightKitApp --filter WorkflowCoordinatorTests/testActiveLiveMeetingStillBlocksNewLiveStartWhileStopIsFinalizing`
- related Swift gate: `swift test --package-path macos/InsightKitApp --filter WorkflowCoordinatorTests --filter LiveSessionViewModelTests` -> 34 tests, 0 failures
- full Swift gate: `swift test --package-path macos/InsightKitApp` -> 146 tests, 0 failures
- standard sync installed build `20260625165436` into `/Users/yann.jy/Applications/InsightKit.app`

Owner retest should confirm that clicking stop and immediately trying to start Live Insight again does not continue or merge delayed transcript rows from the previous session, and does not skip the stopped session's post-session Smart Minutes path.

### 2026-06-25 - Issue 13 owner retest passed and issues 14-20 added

The owner confirmed that issue 13 is fixed in the installed app.

The same QA pass found seven additional product and UX issues:

- issue 14: Live Workspace loading states lack progress feedback.
- issue 15: speaker diarization can fail or label speakers incorrectly.
- issue 16: speaker labels cannot be edited after transcription.
- issue 17: Smart Minutes cannot be exported from the review flow.
- issue 18: Record default names are hard to read.
- issue 19: Records cannot be renamed.
- issue 20: Smart Minutes review source playback has no audio.

Batch triage later moved issues 14, 16, 17, 18, 19, and 20 to `ready-for-agent`; issue 15 moved to `needs-info` pending a concrete failing diarization sample. Issue 14 now has an installed code fix and has passed owner retest. Issue 17 now has an installed code fix and has passed owner retest. Issue 20 now has an installed code fix; owner retest found follow-up regressions now filed as issues 21 and 22.

### 2026-06-25 - Issues 14-20 batch triage completed

Batch triage classified the latest QA findings as follows:

- issue 14: owner retest passed; progress-feedback fix installed in build `20260625183127`.
- issue 15: `needs-info`; automatic speaker diarization accuracy needs a concrete failing sample and expected speaker labels.
- issue 16: `ready-for-agent`; manual speaker-label correction is actionable independently of issue 15.
- issue 17: owner retest passed; Smart Minutes export from the review flow fix installed in build `20260625185114`.
- issue 18: `ready-for-agent`; default Record display names can improve without renaming folders.
- issue 19: `ready-for-agent`; manual Record renaming can persist a human-readable name in metadata.
- issue 20: `ready-for-human`; Smart Minutes review source playback fix installed in build `20260625192450`.

Recommended next implementation target: issue 22 to finish the Smart Minutes review regression cleanup. Issue 18/19 can follow when the Records naming lane resumes.

### 2026-06-25 - Issue 14 implemented

Issue 14 now has a code fix and installed-app sync proof:

- installed build: `20260625183127`
- proof: `logs/workflow/latest_sync.json`
- TDD RED/GREEN tests added to `LiveSessionViewModelTests`
- narrow gate: `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests`, 34 tests, 0 failures
- broad Swift gate: `swift test --package-path macos/InsightKitApp`, 151 tests, 0 failures
- installed smoke: launched `/Users/yann.jy/Applications/InsightKit.app` in Live UI-test route and quit successfully

It is now `ready-for-human` for owner retest.

### 2026-06-25 - Issue 14 owner retest passed

The owner confirmed issue 14 passes in the installed app.

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

It is now `ready-for-human` for owner retest.

### 2026-06-25 - Issue 17 owner retest passed

The owner confirmed issue 17 passes in the installed app.

### 2026-06-25 - Issue 20 implemented

Issue 20 now has a code fix and installed-app sync proof:

- installed build: `20260625192450`
- proof: `logs/workflow/latest_sync.json`
- TDD RED/GREEN tests added to `LiveSessionViewModelTests`
- narrow gates:
  - `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testPrepareTemporaryRecording` passed, 7 tests, 0 failures
  - `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests` passed, 37 tests, 0 failures
- broad Swift gate: `swift test --package-path macos/InsightKitApp`, 155 tests, 0 failures
- installed smoke: launched `/Users/yann.jy/Applications/InsightKit.app` in Live UI-test route and quit successfully

It is now `ready-for-human` for owner retest.

### 2026-06-25 - Issues 21 and 22 added from issue 20 owner retest

The owner reported two follow-up regressions after testing build `20260625192450`:

- issue 21: Smart Minutes `回看资料` no longer displays captured video after the review-source audio fix.
- issue 22: clicking Timeline Beats or Transcript Segments does not seek to the matching source position and start playback.

Issue 21 now has an installed code fix and is `ready-for-human`. Issue 22 remains `ready-for-agent` and should make review shortcuts seek and start playback for the selected moment.
