# Manual QA Session 2026-06-25

Status: ready-for-human

## Purpose

Record owner-led manual QA for the currently installed InsightKit app and turn each reported user-visible problem into a durable local markdown issue.

This lane is for discovery and issue filing, not for immediate implementation. Implementation should happen later through individual `ready-for-agent` issues.

High-severity safety note: issue 06 reports system-wide freeze/restart after Sidecar memory grew to roughly 30 GB. Treat it as the highest priority QA finding in this lane.

Issue 06 has passed owner retest after the resource-containment fix installed in build `20260625094746`.

Issue 03 has passed owner retest after the Qwen MLX worker fix and Sidecar RPC regression coverage.

Issue 11 has passed owner retest after the status-channel fix installed in build `20260625123538`.

Issue 09 has passed owner retest after the recoverable live-analysis timeout fix installed in build `20260625131608`.

Issue 10 has passed owner retest after the Provider response-format sanitizer installed in build `20260625132851`.

Issue 12 has passed owner retest after the completed-summary review presentation fix installed in build `20260625140443` and the related issue 13 stop/start backlog path was handled.

Issue 13 has a code-level Live Session stop/start boundary fix installed in build `20260625165436`; owner retest passed.

Issue 14 has a code-level Live Workspace progress-feedback fix installed in build `20260625183127`; owner retest passed.

Issue 17 has a code-level Smart Minutes review export fix installed in build `20260625185114`; owner retest passed.

Issue 16 has a code-level Record Review speaker-label rename fix installed in build `20260625222052`; owner retest passed.

Issue 18 has a code-level readable Record display-name fix installed in build `20260625222052`; owner retest passed.

Issue 19 has a code-level manual Record rename fix installed in build `20260625222052`; owner retest passed.

Issue 20 has a code-level Smart Minutes review-source audio fix installed in build `20260625192450`; owner retest later passed after follow-up regressions were tracked and fixed as issues 21, 22, and 23.

Issue 21 has a code-level Smart Minutes review-source video fix installed in build `20260625203632`; owner retest passed.

Issue 22 has a code-level Smart Minutes review-source click-to-seek-and-play fix installed; owner retest passed.

Issue 23 has a code-level Smart Minutes review-source single-player fix implemented; owner retest passed.

Issue 24 previously passed after the second Smart Minutes review-source audio/video synchronization fix, but later regressed after microphone audio recovered. After the red-capable source-timeline loop, build `20260627115314` installed the capture-clock video writer fix; owner retest passed on a new installed-app capture. The old failed records remain diagnostic fixtures because their source media was already written with old timing.

Issue 25 records that Record Review playback auto-pauses after opening a saved Record from the Records Workspace. It now has an installed playback-continuity fix in build `20260626190326` and owner retest passed.

Issue 26 records the stronger media-timeline rule from issue 24 follow-up diagnosis: saved transcript timestamps must be derived from the final media file, not from live chunk processing time. The stop-before-final-transcription follow-up fix is installed in build `20260626163854`; owner retest passed.

Issues 27-30 record new owner QA findings after issue 26 passed: playback electrical noise, audio-only Record Review losing speaker rename controls, missing draggable playback timeline, and long-strip media aspect ratio. Issue 27 passed owner retest after its canonical media-source fix. Issue 29 passed owner retest. Issue 30 passed owner retest after the residual audio-only player-frame fix installed in build `20260627001232`. Issue 28 was clarified as mis-scoped and superseded by issue 32.

Issue 31 records an intermittent Live Workspace crash while starting microphone capture. It had an installed microphone startup fix in build `20260626172647`, but owner retest failed again on installed build `20260627145522` with the same `AVAudioNode.installTap` crash signature. The Obj-C exception-safe follow-up fix is installed in build `20260627153026` and is `ready-for-human`.

Issues 32-34 record follow-up QA from the same owner retest: Smart Minutes finalization lacks speaker rename controls, Record Review and Smart Minutes need a canonical shared meeting-asset source, and Record Review back navigation skips the Records Workspace. Issue 32 passed owner retest. Issue 33 passed owner retest after the canonical Meeting Asset fix installed in build `20260626221051`. Issue 34 has an installed Record Review back-navigation fix in build `20260626222305`; owner retest passed.

Issues 35-39 record the latest owner QA/design intake and final-transcription follow-up: bottom status bar occlusion on session pages, Record Folder naming standards, generated Record title standards, an Apple Speech framework feasibility spike, and live final transcription failure when the sidecar cannot find `ffmpeg` or the captured media is silent. Issue 35 passed owner retest after the bottom-status-bar layout fix installed in build `20260627001915`. Issues 36 and 37 have installed naming-standard fixes in build `20260627004202` and are `ready-for-human`. Issue 38 has an accepted Apple Speech feasibility decision. Issue 40 has an installed Apple Speech offline-media prototype in build `20260627145522` and is `ready-for-human`. Issue 39 passed owner retest after the final-transcription environment and silent-audio detection fix installed in build `20260627095346`.

Issues 41-42 record the latest owner QA after installing build `20260627145522`: the main interface lacked a discoverable Settings Workspace entry, and Apple Speech needs a stronger realtime ASR parity plus Diarization proof before being presented as a peer local ASR Engine. Issue 41 passed owner retest after the Settings Workspace entry fix installed in build `20260627154910`. Issue 42 has an installed Apple Speech peer-engine parity gate in build `20260627161028` and is `ready-for-human`.

Issues 43-44 record the latest owner QA after installing build `20260627161028`: the in-app Settings banner action can crash after a transcription failure, and Live transcription failure can leave the latest session unsaved or still appearing active. Both are `ready-for-agent`.

Batch dependency triage is recorded in `.scratch/manual-qa-2026-06-25/triage-dependency-map.md`. Issues 01, 02, 03, 04, 05, 06, 07, 08, 09, 10, 11, 12, 13, 14, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 29, 30, 32, 33, 34, 35, 39, and 41 have passed owner retest after their installed fixes. Issues 31, 36, 37, 40, and 42 are `ready-for-human` for owner retest. Issue 38 remains `ready-for-human` as a completed decision record. Issues 43 and 44 are `ready-for-agent`. Issue 15 is `needs-info`. Issue 28 is `wontfix` because it was superseded by issue 32.

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
- Build version: `20260627161028`
- Git revision: `db4fc1b`
- Build source: `local-workspace-dirty`
- Scope: issue 42 Apple Speech peer-engine parity gate

Latest owner QA update:
- Issues 20, 21, 22, 23, 24, 25, 26, 27, 29, 30, 33, 34, 35, and 39 passed owner retest after their installed fixes.
- Issue 24 passed owner retest after the capture-clock video writer fix installed in build `20260627115314`.
- Issue 30 passed owner retest after the residual audio-only player-frame fix installed in build `20260627001232`.
- Issue 31 retest failed again on installed build `20260627145522` with an `AVAudioNode.installTap` crash; the Obj-C exception-safe follow-up fix is now installed in build `20260627153026` and needs owner retest.
- Issues 35-39 were filed from the latest owner QA/design intake and final-transcription follow-up.
- Issue 35 passed owner retest after the bottom-status-bar layout fix installed in build `20260627001915`.
- Issues 36 and 37 have installed Record folder/title naming-standard fixes in build `20260627004202` and need owner retest.
- Issue 38 has an Apple Speech feasibility decision recorded in `.scratch/manual-qa-2026-06-25/apple-speech-framework-feasibility.md`.
- Issue 39 passed owner retest after the final-transcription environment and silent-audio detection fix installed in build `20260627095346`.
- Issue 38's feasibility decision is accepted; issue 40 has an installed Apple Speech prototype in build `20260627145522` and needs owner retest.
- Issues 41 and 42 were filed from owner QA against build `20260627145522`: Settings Workspace discoverability, and Apple Speech realtime ASR parity with Diarization proof.
- Issue 41 passed owner retest after the Settings Workspace discoverability fix in build `20260627154910`.
- Issue 42 has an installed Apple Speech peer-engine parity gate in build `20260627161028` and needs owner retest in Settings.
- Issues 43 and 44 were filed from owner QA against build `20260627161028`: the Settings banner action crash after transcription failure, and a Live transcription failure / unsaved session recovery gap.
- Issue 27 passed owner retest after the canonical media-source fix in build `20260626210922`.
- Issue 28 was clarified as mis-scoped and is superseded by issue 32.
- Issue 32 passed owner retest after the Smart Minutes finalization speaker-rename fix in build `20260626214019`.
- Issue 33 passed owner retest after the canonical Meeting Asset fix installed in build `20260626221051`.
- Issues 03, 06, 07, 09, 10, 11, 12, 16, 18, and 19 are confirmed resolved by owner retest.
- Issue 26 has passed owner retest after the installed stop-before-final-transcription follow-up fix in build `20260626163854`.

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
- `.scratch/manual-qa-2026-06-25/issues/03-live-insight-refresh-fails-with-gpu-stream-sidecar-error.md` - Live Insight Refresh fails with GPU stream sidecar error during recording. Owner retest passed.
- `.scratch/manual-qa-2026-06-25/issues/04-live-notes-entry-is-not-discoverable-or-usable.md` - Live notes entry is not discoverable or usable during recording. Code fix installed in build `20260625115936`; owner retest passed.
- `.scratch/manual-qa-2026-06-25/issues/05-live-summary-error-open-settings-does-not-open-settings.md` - Live summary error banner cannot open Settings Workspace. Code fix installed in build `20260625102417`; owner retest passed.
- `.scratch/manual-qa-2026-06-25/issues/06-live-sidecar-memory-spike-can-freeze-and-restart-system.md` - Live Sidecar memory spike can freeze and restart the system. Owner retest passed.
- `.scratch/manual-qa-2026-06-25/issues/07-final-insight-generation-times-out-after-live-session.md` - Final Insight Generation times out after a live session. Owner retest passed.
- `.scratch/manual-qa-2026-06-25/issues/08-live-review-media-does-not-display-video.md` - Live review media does not display video. Code fix installed in build `20260625113541`; owner retest passed.
- `.scratch/manual-qa-2026-06-25/issues/09-live-insight-refresh-timeout-shown-as-error-while-capture-continues.md` - Live Insight Refresh timeout is shown as an error while capture continues. Owner retest passed.
- `.scratch/manual-qa-2026-06-25/issues/10-provider-non-json-payload-shown-as-realtime-summary-error.md` - Provider non-JSON payload is shown as a realtime summary error. Owner retest passed.
- `.scratch/manual-qa-2026-06-25/issues/11-runtime-warmup-delay-can-be-misclassified-as-summary-failure.md` - Runtime Warmup delay can be misclassified as a summary failure. Owner retest passed.
- `.scratch/manual-qa-2026-06-25/issues/12-generated-summary-does-not-open-summary-review-interface.md` - Generated summary does not open the summary review interface. Owner retest passed.
- `.scratch/manual-qa-2026-06-25/issues/13-live-session-stop-start-can-continue-previous-transcription-backlog.md` - Live session stop/start can continue previous transcription backlog. Code fix installed in build `20260625165436`; owner retest passed.
- `.scratch/manual-qa-2026-06-25/issues/14-live-workspace-loading-states-lack-progress-feedback.md` - Live Workspace loading states lack progress feedback. Code fix installed in build `20260625183127`; owner retest passed.
- `.scratch/manual-qa-2026-06-25/issues/15-speaker-diarization-can-fail-or-label-speakers-incorrectly.md` - Speaker diarization can fail or label speakers incorrectly. Triaged as `needs-info` pending a concrete failing sample.
- `.scratch/manual-qa-2026-06-25/issues/16-speaker-labels-cannot-be-edited-after-transcription.md` - Speaker labels cannot be edited after transcription. Code fix installed in build `20260625222052`; owner retest passed.
- `.scratch/manual-qa-2026-06-25/issues/17-smart-minutes-cannot-be-exported-from-review-flow.md` - Smart Minutes cannot be exported from the review flow. Code fix installed in build `20260625185114`; owner retest passed.
- `.scratch/manual-qa-2026-06-25/issues/18-record-default-names-are-hard-to-read.md` - Record default names are hard to read. Code fix installed in build `20260625222052`; owner retest passed.
- `.scratch/manual-qa-2026-06-25/issues/19-records-cannot-be-renamed.md` - Records cannot be renamed. Code fix installed in build `20260625222052`; owner retest passed.
- `.scratch/manual-qa-2026-06-25/issues/20-smart-minutes-review-source-playback-has-no-audio.md` - Smart Minutes review source playback has no audio. Code fix installed in build `20260625192450`; owner retest passed after issues 21-23 follow-ups were handled.
- `.scratch/manual-qa-2026-06-25/issues/21-smart-minutes-review-source-loses-video-after-audio-fix.md` - Smart Minutes review source loses video after the audio fix. Code fix installed in build `20260625203632`; owner retest passed.
- `.scratch/manual-qa-2026-06-25/issues/22-smart-minutes-review-source-seek-does-not-start-playback.md` - Smart Minutes review source seek does not start playback. Code fix installed; owner retest passed.
- `.scratch/manual-qa-2026-06-25/issues/23-smart-minutes-review-source-splits-audio-and-video.md` - Smart Minutes review source splits audio and video. Code fix implemented; owner retest passed.
- `.scratch/manual-qa-2026-06-25/issues/24-smart-minutes-review-source-audio-video-out-of-sync.md` - Smart Minutes review source audio and video are out of sync. Repeated installed fixes failed until the source-timeline diagnostic caught video timeline drift; the capture-clock video writer fix installed in build `20260627115314` has passed owner retest.
- `.scratch/manual-qa-2026-06-25/issues/25-record-review-playback-auto-pauses-after-opening-record.md` - Record Review playback auto-pauses after opening a saved Record from the Records Workspace. Code fix installed in build `20260626190326`; owner retest passed.
- `.scratch/manual-qa-2026-06-25/issues/26-saved-transcript-timestamps-must-use-final-media-timeline.md` - Saved transcript timestamps must use the final media timeline. Stop-before-final-transcription follow-up installed in build `20260626163854`; owner retest passed.
- `.scratch/manual-qa-2026-06-25/issues/27-record-review-playback-has-electrical-noise.md` - Record Review playback has electrical noise. Canonical media-source fix installed in build `20260626210922`; owner retest passed.
- `.scratch/manual-qa-2026-06-25/issues/28-audio-only-record-review-loses-speaker-rename.md` - Audio-only Record Review loses speaker rename controls. Superseded by issue 32 after owner clarified the original problem was mis-scoped.
- `.scratch/manual-qa-2026-06-25/issues/29-record-review-player-lacks-draggable-timeline.md` - Record Review player lacks a draggable media timeline. Code fix installed in build `20260626192237`; owner retest passed.
- `.scratch/manual-qa-2026-06-25/issues/30-record-review-player-aspect-ratio-is-long-strip.md` - Record Review player aspect ratio is a long strip. Residual audio-only player-frame fix installed in build `20260627001232`; owner retest passed.
- `.scratch/manual-qa-2026-06-25/issues/31-live-workspace-can-crash-when-starting-microphone-capture.md` - Live Workspace can crash when starting microphone capture. Obj-C exception-safe follow-up fix installed in build `20260627153026`; needs owner retest.
- `.scratch/manual-qa-2026-06-25/issues/32-smart-minutes-finalization-lacks-speaker-rename.md` - Smart Minutes finalization lacks speaker rename controls. Code fix installed in build `20260626214019`; owner retest passed.
- `.scratch/manual-qa-2026-06-25/issues/33-record-review-and-smart-minutes-should-share-canonical-meeting-asset-source.md` - Record Review and Smart Minutes should share one canonical Meeting Asset source. Code fix installed in build `20260626221051`; owner retest passed.
- `.scratch/manual-qa-2026-06-25/issues/34-record-review-back-navigation-skips-records-workspace.md` - Record Review back navigation skips the Records Workspace. Code fix installed in build `20260626222305`; owner retest passed.
- `.scratch/manual-qa-2026-06-25/issues/35-session-pages-are-obscured-by-bottom-status-bar.md` - Session pages are obscured by the bottom status bar. Code fix installed in build `20260627001915`; owner retest passed.
- `.scratch/manual-qa-2026-06-25/issues/36-record-folder-names-need-a-readable-standard.md` - Record Folder names need a readable standard.
- `.scratch/manual-qa-2026-06-25/issues/37-generated-record-titles-are-too-long-and-unstandardized.md` - Generated Record titles are too long and unstandardized.
- `.scratch/manual-qa-2026-06-25/issues/38-evaluate-apple-speech-framework-as-official-transcription-backend.md` - Evaluate Apple Speech framework as an official transcription backend. Feasibility decision accepted; follow-up issue 40 filed.
- `.scratch/manual-qa-2026-06-25/issues/39-live-final-transcription-fails-when-sidecar-cannot-find-ffmpeg.md` - Live final transcription can fail when the sidecar cannot find `ffmpeg` or the captured media is silent. Environment and silent-audio detection fix installed in build `20260627095346`; owner retest passed.
- `.scratch/manual-qa-2026-06-25/issues/40-prototype-apple-speech-offline-media-transcription.md` - Prototype Apple Speech offline media transcription on macOS 26+ behind an experimental audio final-media toggle. Installed in build `20260627145522`; needs owner retest.
- `.scratch/manual-qa-2026-06-25/issues/41-main-interface-lacks-discoverable-settings-entry.md` - Main interface lacks a discoverable Settings Workspace entry. Installed in build `20260627154910`; owner retest passed.
- `.scratch/manual-qa-2026-06-25/issues/42-apple-speech-needs-live-asr-parity-and-diarization-proof.md` - Apple Speech needs live ASR parity and Diarization proof before becoming a peer local engine. Installed peer-engine parity gate in build `20260627161028`; needs owner retest.
- `.scratch/manual-qa-2026-06-25/issues/43-settings-banner-action-can-crash-after-transcription-failure.md` - Settings banner action can crash after transcription failure. New `ready-for-agent` issue.
- `.scratch/manual-qa-2026-06-25/issues/44-live-transcription-failure-can-leave-session-unsaved-and-still-recording.md` - Live transcription failure can leave the session unsaved and still recording. New `ready-for-agent` issue.
- `.scratch/manual-qa-2026-06-25/triage-dependency-map.md` - Batch dependency triage for issues 01-44.

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
- owner retest passed: issues 01, 02, 03, 04, 05, 06, 07, 08, 09, 10, 11, 12, 13, 14, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 29, 30, 32, 33, 34, 35, and 39.
- owner retest passed after latest updates: issue 41.
- `ready-for-agent`: none.
- `ready-for-human`: issues 31, 36, 37, 40, and 42; issue 38 remains a completed decision record.
- `needs-triage`: none.
- `needs-info`: issue 15, because automatic speaker diarization accuracy needs a concrete failing sample.
- `wontfix`: issue 28, because it was superseded by issue 32.

Recommended current next action at that point:
1. Owner-retest issue 31 on installed build `20260627153026` with repeated microphone or mixed-audio starts.
2. Owner-retest issue 42's Apple Speech peer-engine parity gate in installed build `20260627161028`.
3. Owner-retest issue 40's Apple Speech experimental audio final-media prototype when convenient.

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
- issue 21: `ready-for-human`; Smart Minutes review source video fix installed in build `20260625203632`.
- issue 22: `ready-for-human`; Smart Minutes review source click-to-seek-and-play fix installed.
- issue 23: `ready-for-human`; Smart Minutes review source single-player audio/video fix implemented.

Recommended next step: owner retest issues 20, 21, 22, 23, and 24 together as the Smart Minutes review-source bundle. After that, issue 18/19 can resume the Records naming lane, or issue 16 can start speaker-label editing.

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

### 2026-06-25 - Issues 21, 22, and 23 added from issue 20 owner retest

The owner reported follow-up regressions after testing build `20260625192450` and the later issue 22 installed fix:

- issue 21: Smart Minutes `回看资料` no longer displays captured video after the review-source audio fix.
- issue 22: clicking Timeline Beats or Transcript Segments does not seek to the matching source position and start playback.
- issue 23: Smart Minutes `回看资料` should not split audio and video into separate playback surfaces.

Issue 21 now has an installed code fix and is `ready-for-human`. Issue 22 now has an installed code fix and is `ready-for-human`. Issue 23 now has a code fix and is `ready-for-human`. Issue 24 later received a second installed fix with system-audio E2E proof and is `ready-for-human` for owner retest.

### 2026-06-25 - Issue 23 implemented

Issue 23 now has a code fix and test proof:

- red/green regression loop:
  - `swift test --package-path macos/InsightKitApp --filter LiveReviewSourcePresentationTests/testVideoReviewSourceUsesSingleStandardPlayerEvenWhenLegacySeparateAudioExists`
- narrow gates:
  - `swift test --package-path macos/InsightKitApp --filter LiveReviewSourcePresentationTests/testVideoReviewSourceUsesSingleStandardPlayerEvenWhenLegacySeparateAudioExists --filter LiveSessionViewModelTests/testPrepareTemporaryRecordingComposesSinglePlayableVideoWhenVideoAndAudioAreCaptured`, 2 tests, 0 failures
  - `swift test --package-path macos/InsightKitApp --filter LiveReviewSourcePresentationTests --filter LiveSessionViewModelTests/testPrepareTemporaryRecording --filter MediaSeekRequestTests`, 17 tests, 0 failures
- broad Swift gate: `swift test --package-path macos/InsightKitApp`, 158 tests, 0 failures

### 2026-06-25 - Issue 24 added from Smart Minutes review-source owner QA

The owner reported that after a Live Workspace session ends and the Smart Minutes preview/review interface opens, the review source audio and video seem out of sync.

Issue 24 records this as a new Smart Minutes review-source timing problem. It is separate from issues 20, 21, 22, and 23 because those issues cover whether the media is audible, visible, seekable, and presented through one standard player. Issue 24 assumes playback exists but its timing may not be correct.

Current classification:

- status: `ready-for-agent`
- latest observed installed build: `20260625212142`
- installed fix build: `20260625214038`
- next action: diagnose why Smart Minutes `回看资料` audio/video synchronization still fails after the installed fix

### 2026-06-25 - Issue 24 code fix installed

Issue 24 now has a code fix and installed-app sync proof:

- installed build: `20260625214038`
- proof: `logs/workflow/latest_sync.json`
- RED/GREEN regression: `python -m pytest tests/test_live_review_media_sync.py -q`
- related gate: `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testPrepareTemporaryRecording --filter LiveReviewSourcePresentationTests --filter MediaSeekRequestTests`, 17 tests, 0 failures
- broad Swift gate: `swift test --package-path macos/InsightKitApp`, 158 tests, 0 failures

Owner retest later failed; at that point the issue returned to `ready-for-agent`.

### 2026-06-25 - Issue 24 owner retest failed and issue 25 added

The owner reported that issue 24 still reproduces after testing the installed build `20260625214038`: Smart Minutes review-source audio and video are still not synchronized.

At that point the issue returned to `ready-for-agent`. The previous timing-boundary fix should be treated as attempted mitigation, not proof that the media timing problem is solved.

The owner also reported a separate playback issue from the Records Workspace: after opening a saved Record, Record Review playback can auto-pause and cannot play normally. This is recorded as issue 25.

Current classification:

- issue 24: `ready-for-human`
- issue 25: `ready-for-human` after installed build `20260626190326`

Recommended order:

1. Owner retest issue 24 on installed build `20260626144645`, preferably using system audio or mixed audio if microphone input is unreliable.
2. Owner retest issue 25 on installed build `20260626190326` because it starts from Records Workspace / Record Review rather than Live Workspace / Smart Minutes.

### 2026-06-26 - Issue 24 second fix installed and system-audio E2E passed

Issue 24 now has a second fix and installed-app proof:

- installed build: `20260626144645`
- proof: `logs/workflow/latest_sync.json`
- RED/GREEN media timing regression: `python -m pytest tests/test_live_review_media_sync.py -q`, 3 tests, 0 failures.
- playback state regression: `swift test --package-path macos/InsightKitApp --filter MediaSeekRequestTests`, 10 tests, 0 failures.
- standard sync: `bash scripts/sync_insightkit_app.sh`; Swift and Python gates passed.
- installed-app system-audio record `live-B5BD191C-0E4E-4A36-A24D-350155C1E65F` passed `scripts/diagnose_issue24_media_timeline.py` with audio duration `70.492s`, video duration `71.277s`, and no failures.
- Live Smart Minutes `回看资料` click-to-play proof: clicking `00:22` and `00:34` review source links moved `回看态`, kept the player toggle `on`, and the timeline advanced.

Current classification:

- issue 24: `ready-for-human`
- issue 25: `ready-for-human` after installed build `20260626190326`

Recommended order:

1. Owner retest issue 24 by watching/listening to the installed Smart Minutes `回看资料` path.
2. Then owner retest issue 25 unless issue 24 fails again.

### 2026-06-25 - Issues 03, 06, 07, 09, 10, 11, and 12 owner retest passed

The owner confirmed these previously installed fixes are resolved:

- issue 03: Qwen MLX GPU stream Sidecar error.
- issue 06: Sidecar memory spike and system-freeze risk.
- issue 07: Final Insight Generation timeout on `insight.build_final`.
- issue 09: recoverable Live Insight Refresh timeout.
- issue 10: Provider non-JSON payload banner sanitization.
- issue 11: Runtime Warmup / waiting-for-first-transcript misclassified as summary failure.
- issue 12: generated summary opening into the summary review interface.

These issues are no longer active blockers for the next QA implementation pass.

### 2026-06-25 - Issues 16, 18, and 19 implemented

Issues 16, 18, and 19 now have one Records Workspace / Record Review fix bundle installed in build `20260625222052`.

Implemented:

- issue 16: Record Review speaker labels can be renamed from a speaker menu or transcript row context menu; the correction persists to `transcript.json` and is reflected in Transcript Segments, Smart Minutes speaker summaries, and exports.
- issue 18: Record display names now use manual title, then Smart Minutes summary preview, then a readable source/date fallback instead of exposing only technical IDs.
- issue 19: Records can be renamed from the Record list context menu or Record Review toolbar; the manual title persists in `metadata.json` and is searchable.

Verification:

- RED/GREEN: `swift test --package-path macos/InsightKitApp --filter RecordsIndexServiceTests/testRecordDisplayTitlePrefersManualTitleThenSummaryThenReadableFallback --filter RecordsIndexServiceTests/testRenameRecordPersistsManualTitleAndSearchUsesIt --filter RecordsIndexServiceTests/testRecordReviewRenamesSpeakerAndExportUsesCorrectedLabel`
- Related gate: `swift test --package-path macos/InsightKitApp --filter RecordsIndexServiceTests --filter RecordDocumentExporterTests`, 16 tests, 0 failures.
- Broad Swift gate: `swift test --package-path macos/InsightKitApp`, 161 tests, 0 failures.
- Standard sync: `bash scripts/sync_insightkit_app.sh`, Swift and Python gates passed; installed build `20260625222052` to `/Users/yann.jy/Applications/InsightKit.app`.

Current state:

- issue 16: `ready-for-human`
- issue 18: `ready-for-human`
- issue 19: `ready-for-human`

Recommended owner retest:

1. Open Records Workspace.
2. Confirm readable Record names appear in the list and Record Review header.
3. Rename a Record from the list context menu or Record Review toolbar and confirm it persists.
4. Open a Record with generic speaker labels, rename one speaker, and confirm transcript, Smart Minutes speaker summaries, and export output use the corrected label.

### 2026-06-26 - Issue 26 stop-before-final-transcription follow-up installed

The owner retested issue 26 on build `20260626160503` and found a follow-up failure: stopping before Final Media Transcription completed could immediately show `最终回看资料转写失败；已保留媒体和笔记，本次转写需要重新生成。`

Follow-up fix installed in build `20260626163854`:

- Stop drains already captured queued audio chunks instead of clearing them after `isRunning` becomes false.
- Live Workspace shows that it is processing remaining audio and final transcription after Stop.
- Final Media Transcription retries transient `asr.transcribe_media` failures before saving an empty transcript.
- Finalization progress stays active until Record saving finishes.

Verification:

- `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testStopLiveSessionDrainsQueuedChunksBeforeSavingRecord --filter LiveSessionViewModelTests/testSaveToRecordsRetriesFinalMediaTranscriptionBeforeSavingEmptyTranscript --filter LiveSessionViewModelTests/testSaveToRecordsDoesNotFallbackToLiveChunkTranscriptWhenFinalMediaTranscriptionFails --filter LiveSessionViewModelTests/testSaveToRecordsReplacesLiveChunkTranscriptWithFinalMediaTranscript --filter LiveSessionViewModelTests/testBuildFinalInsightReplacesRuntimeTranscriptWithFinalMediaTranscriptBeforeGeneratingMinutes`, 5 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp`, 167 tests, 0 failures.
- `bash scripts/sync_insightkit_app.sh`, Swift and Python gates passed; installed build `20260626163854` to `/Users/yann.jy/Applications/InsightKit.app`.

Current state:

- issue 26: `ready-for-human`
- owner retest passed.

### 2026-06-26 - Issues 27-30 added after issue 26 owner retest

The owner confirmed issue 26 is resolved, then reported four new Record Review / playback UX problems:

- issue 27: Record Review playback has electrical noise.
- issue 28: audio-only Record Review loses the previously fixed speaker rename controls.
- issue 29: Record Review player lacks a draggable media timeline.
- issue 30: Record Review player aspect ratio can appear as a long strip.

Current classification:

- issue 25: `ready-for-human` after installed build `20260626190326`
- issue 27: `ready-for-human` after installed build `20260626203055`
- issue 28: `ready-for-human` after installed build `20260626200713`
- issue 29: `ready-for-human` after installed build `20260626192237`
- issue 30: `ready-for-human` after installed build `20260626192237`

Recommended order:

1. Owner retest issue 25 first because auto-pausing can interfere with validating audio quality, timeline dragging, and media frame behavior.
2. Owner retest issues 29 and 30 on installed build `20260626192237`.
3. Continue with issues 27 and 28.

### 2026-06-26 - Issue 31 added from intermittent crash report

The owner reported an intermittent app crash and attached a macOS crash report.

Issue 31 was filed as `ready-for-agent` and later moved to `ready-for-human` after an installed microphone capture startup fix.

Key crash evidence:

- installed build: `20260626163854`
- exception type: `EXC_CRASH (SIGABRT)`
- termination: `Abort trap: 6`
- trigger: background cooperative queue while starting microphone capture
- crash signature: `AVAudioNode.installTap` raises an Objective-C exception during microphone capture startup

Diagnosis and code fix:

- `MicCaptureService.start()` now serializes AVAudioEngine graph mutations on a dedicated control queue.
- Duplicate microphone start requests are idempotent and do not install a second input tap.
- Startup failure clears the tap and resets the service so the next start can retry.
- Regression coverage added in `MicCaptureServiceTests`.

Verification:

- `swift test --package-path macos/InsightKitApp --filter MicCaptureServiceTests`
- `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests`
- `swift test --package-path macos/InsightKitApp` passed: 170 tests, 0 failures.
- `bash scripts/sync_insightkit_app.sh` installed build `20260626172647`.
- `codesign --verify --deep --strict --verbose=2 /Users/yann.jy/Applications/InsightKit.app` passed.

Recommended next action:

1. Owner-retest issue 31 on installed build `20260626172647` with repeated microphone start/stop.
2. Owner-retest issue 25 on installed build `20260626190326`, then continue issues 27-30.

### 2026-06-26 - Issue 25 playback-continuity fix installed

Issue 25 now has an installed Record Review playback-continuity fix and is `ready-for-human`.

Root cause:

- Record Review passed `isPlaying: false` into `MediaPlayerView`.
- Playback time updates refreshed SwiftUI state, and the next view update called `pause()` on the player.

Fix summary:

- `MediaPlayerView` now uses optional playback intent: `nil` means user-controlled playback, `true` means host-controlled play, and `false` means host-controlled pause.
- Record Review no longer forces pause while the user is controlling playback.

Verification:

- `swift test --package-path macos/InsightKitApp --filter MediaSeekRequestTests`, 12 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp`, 172 tests, 0 failures.
- `bash scripts/sync_insightkit_app.sh` installed build `20260626190326`.
- `codesign --verify --deep --strict --verbose=2 /Users/yann.jy/Applications/InsightKit.app` passed.

Current next action:

- owner retest issue 25 on installed build `20260626190326`;
- owner retest issue 28 on installed build `20260626200713`;
- owner retest issues 29 and 30 on installed build `20260626192237`;
- owner retest issue 27 on installed build `20260626203055` with a fresh recording.

### 2026-06-26 - Issues 29 and 30 shared review-player UX fix installed

Issues 29 and 30 now have an installed shared review-player UX fix and are `ready-for-human`.

Diagnosis:

- Audio review used `.minimal` AVKit controls, which did not provide a mature draggable media timeline.
- Review playback surfaces stretched to the full center-column width with only a height cap, which could create a long-strip video frame.
- Record Review, Smart Minutes review, and Import review had separate frame wrappers around the same player behavior.

Fix:

- `MediaPlayerView` now uses AVKit `.default` controls for audio and video review media.
- `MediaPlayerView` now sets video gravity to `.resizeAspect`.
- `ReviewMediaPlayerView` centralizes review-player layout across Record Review, Smart Minutes review, and Import review.
- `ReviewMediaPlayerLayout` constrains video to a stable 16:9 review frame and audio to a compact audio bar.

Verification:

- RED loop: `swift test --package-path macos/InsightKitApp --filter MediaSeekRequestTests/testMediaPlayerUsesDefaultControlsForAudioAndVideoScrubbing --filter MediaSeekRequestTests/testMediaPlayerPreservesNaturalVideoAspectInsteadOfStretching --filter MediaSeekRequestTests/testReviewMediaPlayerLayoutAvoidsVideoLongStrip --filter MediaSeekRequestTests/testReviewMediaPlayerLayoutUsesCompactAudioBar` failed before implementation.
- `swift test --package-path macos/InsightKitApp --filter MediaSeekRequestTests` passed: 15 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp` passed: 175 tests, 0 failures.
- `bash scripts/sync_insightkit_app.sh` installed build `20260626192237`.
- `codesign --verify --deep --strict --verbose=2 /Users/yann.jy/Applications/InsightKit.app` passed.

Current next action:

- owner retest issues 29 and 30 on installed build `20260626192237`;
- owner retest issue 28 on installed build `20260626200713`;
- owner retest issue 27 on installed build `20260626203055` with a fresh recording.

### 2026-06-26 - Issue 28 audio-only speaker rename fix installed

Issue 28 now has an installed Record Review speaker-rename fix and is `ready-for-human`.

Diagnosis:

- Saved Record speaker renaming still worked in the data layer, but the visible Review UI relied on a crowded top toolbar menu and row context menus.
- Audio-only review could therefore appear to lose the speaker rename workflow even though transcript speaker data was present.
- Speaker correction should depend on transcript rows with speaker labels, not on whether the Record has video.

Fix:

- Added `RecordSpeakerRenamePresentation` to make rename-control visibility independent of media type.
- Added a visible `说话人` strip in Record Review whenever editable speakers exist.
- Added visible transcript-row pencil actions for speaker rename, while keeping the existing context-menu path.

Verification:

- RED loop: focused tests failed before implementation because `RecordSpeakerRenamePresentation` did not exist.
- `swift test --package-path macos/InsightKitApp --filter RecordsIndexServiceTests/testAudioOnlyRecordReviewShowsVisibleSpeakerRenameStrip --filter RecordsIndexServiceTests/testTranscriptRowWithSpeakerShowsVisibleRenameAction --filter RecordsIndexServiceTests/testRecordReviewRenamesSpeakerAndExportUsesCorrectedLabel` passed: 3 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp --filter RecordsIndexServiceTests` passed: 14 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp` passed before sync; `bash scripts/sync_insightkit_app.sh` reran the full sync gate successfully.
- `bash scripts/sync_insightkit_app.sh` installed build `20260626200713`.
- `codesign --verify --deep --strict --verbose=2 /Users/yann.jy/Applications/InsightKit.app` passed.

Current next action:

- owner retest issue 28 on installed build `20260626200713`;
- owner retest issue 27 on installed build `20260626203055` with a fresh recording.

### 2026-06-26 - Issue 27 audio headroom fix installed

Issue 27 now has an installed Record Review audio-quality fix and is `ready-for-human`.

Diagnosis:

- The RED loop reproduced a clipping risk in the capture-to-review media path: loud mixed input could hit full-scale output, and WAV writing could store over-range samples as `Int16.max`.
- That kind of full-scale flat-top clipping can sound like harsh buzzing or electrical noise during Record Review playback.
- A quick scan found one existing local older Record with full-scale WAV samples: `/Users/yann.jy/Documents/InsightKit/Records/live-12649D1E-0E2D-4D51-99DD-4AFC913011FF/recording.wav`. This supports the diagnosis but also means old already-clipped media may remain noisy.

Fix:

- Added `AudioSampleLimiter`.
- Added mixed-input headroom in `AudioMixBus`, so loud microphone plus loud system audio does not clip.
- Applied limiting in `ChunkAssembler` before writing 16-bit WAV samples.

Verification:

- RED loop failed before implementation: `swift test --package-path macos/InsightKitApp --filter AudioMixBusTests/testMixedModeUsesHeadroomInsteadOfClipping --filter ChunkAssemblerTests/testWAVWriterAvoidsFullScaleClippingForOverRangeSamples`.
- The same focused loop passed after implementation: 2 tests, 0 failures.
- Related gate passed: `swift test --package-path macos/InsightKitApp --filter AudioMixBusTests --filter ChunkAssemblerTests --filter LiveSessionViewModelTests/testPrepareTemporaryRecording`, 11 tests, 0 failures.
- Full Swift gate passed: `swift test --package-path macos/InsightKitApp`, 178 tests, 0 failures.
- `bash scripts/sync_insightkit_app.sh` passed Swift and Python gates and installed build `20260626203055`.
- `codesign --verify --deep --strict --verbose=2 /Users/yann.jy/Applications/InsightKit.app` passed.

Current next action:

- owner retest issue 27 on installed build `20260626203055` with a fresh Live Workspace recording;
- older Records that already contain clipped samples should not be used as the sole pass/fail proof.

### 2026-06-26 - Follow-up QA after issue 27 retest

The owner reported four follow-up findings:

- issue 27 still reproduces electrical noise after the installed audio headroom fix, so it is back to `ready-for-agent`;
- issue 28 was mis-scoped; the true missing speaker-name correction workflow belongs in the Smart Minutes finalization/result surface and is now issue 32;
- issue 33 records the product decision that Record Review and Smart Minutes should share one canonical Meeting Asset source;
- issue 34 records that Record Review back navigation should return to the Records Workspace rather than the Home Workspace.

Queue state at that point:

- issue 27: `ready-for-agent`
- issue 28: `wontfix`, superseded by issue 32
- issue 32: `ready-for-agent`
- issue 33: `ready-for-agent`
- issue 34: `ready-for-agent`

### 2026-06-26 - Issue 33 decision mapped

Issue 33 now has a decision map:

- `.scratch/manual-qa-2026-06-25/canonical-meeting-asset-decision-map.md`

Decision:

- Record Review and Smart Minutes are two views over one canonical Meeting Asset source.
- The canonical source should keep review media, Media-Timed Transcript, speaker-name mapping, notes, and the Insight Package consistent across views.
- When the original saved recording is already clean and playable, playback surfaces should use it directly.
- If derived media must be created, it should become one shared canonical review media source and must not degrade audio quality or sync.

Current classification:

- issue 33: `ready-for-agent`
- issue 27 should use this decision as the next diagnostic/fix direction.

### 2026-06-26 - Issue 27 canonical media-source fix installed

Issue 27 now has an installed fix using the canonical Meeting Asset source rule from issue 33.

Fix summary:

- added an AVFoundation-backed media asset inspector;
- Live Workspace save finalization now checks whether the original captured video already has an audio track;
- when the video already has audio, InsightKit keeps that original video as the canonical review media and does not generate a separate `recording-with-audio.mp4`;
- when the video is video-only and separate audio exists, composition remains the fallback path.

Verification:

- RED loop failed before implementation:
  - `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testPrepareTemporaryRecordingKeepsOriginalVideoWhenItAlreadyHasAudio`
- Focused media-save gate passed: 4 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests` passed: 43 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp` passed: 179 tests, 0 failures.
- `bash scripts/sync_insightkit_app.sh` passed Swift and Python gates and installed build `20260626210922`.
- Codesign verification passed.

Current queue state:

- issue 27: `ready-for-human`
- issue 32: `ready-for-agent`
- issue 33: `ready-for-agent`
- issue 34: `ready-for-agent`

### 2026-06-26 - Issue 27 owner retest passed and issue 32 installed

Issue 27 basically passed owner retest after the canonical media-source fix. A small amount of residual noise remained, but the owner judged it likely came from the microphone/source rather than added playback distortion.

Issue 32 now has an installed Smart Minutes speaker-rename fix.

Fix summary:

- Live Smart Minutes finalization and generated Smart Minutes review show a `说话人校正` control when speaker labels are available.
- Renaming a speaker updates Live Session Transcript Segments, Smart Minutes speaker summaries, the last generated Insight Package, and Workbench speaker metadata.
- If the matching Record has already been saved, the rename is written to the Record `transcript.json`, so later Record Review and document export use the corrected speaker label.
- Record Review no longer shows the extra horizontal speaker-rename strip that duplicated the existing speaker workflow.

Verification:

- RED loop failed before implementation:
  - `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testLiveSmartMinutesSpeakerRenameUpdatesRuntimeMinutesPackageAndPersistedRecord`
- Focused test passed after implementation.
- Related gates passed:
  - `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests`, 44 tests, 0 failures.
  - `swift test --package-path macos/InsightKitApp --filter RecordsIndexServiceTests --filter RecordDocumentExporterTests`, 18 tests, 0 failures.
  - `swift test --package-path macos/InsightKitApp`, 180 tests, 0 failures.
- `bash scripts/sync_insightkit_app.sh` passed Swift and Python gates, including 139 Python tests, and installed build `20260626214019`.
- Codesign verification passed.

Current queue state:

- issue 27: owner retest basically passed
- issue 32: owner retest passed
- issue 33: `ready-for-human`
- issue 34: `ready-for-agent`

### 2026-06-26 - Issue 32 owner retest passed and issue 33 installed

Issue 32 passed owner retest after the Smart Minutes speaker-rename placement fix.

Issue 33 now has an installed canonical Meeting Asset source fix.

Fix summary:

- Added `MeetingAssetSnapshot` as the shared Record Folder reader for canonical media, transcript, notes, Smart Minutes, and Insight Package state.
- Record Review now prefers full `insight_package.json` Smart Minutes content when present, then falls back to `minutes.json`.
- Record Review-generated Smart Minutes now persist both `minutes.json` and `insight_package.json`.
- Markdown/PDF export now uses the same Meeting Asset snapshot for Smart Minutes, notes, and media selection.
- Import recovery and Record thumbnail generation now use the same canonical `recording.*` media selection rule.

Verification:

- RED/GREEN: `swift test --package-path macos/InsightKitApp --filter RecordsIndexServiceTests/testRecordReviewPrefersInsightPackageAsCanonicalSmartMinutesSource`.
- RED/GREEN: `swift test --package-path macos/InsightKitApp --filter RecordDocumentExporterTests/testMarkdownExportPrefersInsightPackageAsCanonicalSmartMinutesSource`.
- Related gate: `swift test --package-path macos/InsightKitApp --filter RecordsIndexServiceTests --filter RecordDocumentExporterTests --filter MediaSeekRequestTests`, 35 tests, 0 failures.
- Full Swift gate: `swift test --package-path macos/InsightKitApp`, 182 tests, 0 failures.
- Standard sync: `bash scripts/sync_insightkit_app.sh` passed Swift and Python gates, including 139 Python tests, and installed build `20260626221051`.
- Codesign verification passed.

Current queue state:

- issue 27: owner retest basically passed
- issue 32: owner retest passed
- issue 33: `ready-for-human`
- issue 34: `ready-for-agent`

### 2026-06-26 - Owner retest update and issues 35-38 filed

The owner reported the following retest status:

- fixed: issues 20, 21, 22, 23, 24, 25, 29, and 34;
- partially fixed: issue 30, where video framing is now normal but audio-only playback still has a strange aspect/frame;
- uncertain: issue 31 has not been repeatedly tested yet.

New QA/design issues filed:

- issue 35: Session pages are obscured by the bottom status bar;
- issue 36: Record Folder names need a readable standard;
- issue 37: generated Record titles are too long and unstandardized;
- issue 38: evaluate Apple Speech framework as an official transcription backend.

Current queue state:

- issue 30: `ready-for-human` after residual audio-only player-frame fix in build `20260627001232`;
- issue 31: `ready-for-human`;
- issue 33: `ready-for-human`;
- issue 35: `ready-for-human` after installed bottom-status-bar layout fix in build `20260627001915`;
- issue 36: `ready-for-human` after installed readable Record Folder naming fix in build `20260627004202`;
- issue 37: `ready-for-human` after installed generated-title standard fix in build `20260627004202`;
- issue 38: `ready-for-human` after feasibility decision;
- issue 15: `needs-info`;
- issue 28: `wontfix`.

### 2026-06-27 - Issue 30 residual audio-only frame fix installed

Issue 30 moved from `ready-for-agent` back to `ready-for-human` after a focused residual fix for the audio-only playback frame.

Verification:

- focused RED/GREEN covered the compact audio panel, metadata-driven audio override, and Record media type mapping;
- `swift test --package-path macos/InsightKitApp --filter MediaSeekRequestTests`, 17 tests, 0 failures;
- `swift test --package-path macos/InsightKitApp`, 185 tests, 0 failures;
- standard sync's Python unittest gate was blocked by the local Homebrew Python environment missing `pytest`, `faster-whisper`, and `silero-vad`;
- installed sync succeeded with the already-passed Swift gate via `scripts/sync_insightkit_app.sh --install-dir /Users/yann.jy/Applications --skip-tests`;
- installed build: `20260627001232`; proof: `logs/workflow/latest_sync.json`.

Current queue state:

- issue 30: `ready-for-human`;
- issue 31: `ready-for-human`;
- issue 33: `ready-for-human`;
- issue 35: `ready-for-human`;
- issue 36: `ready-for-human`;
- issue 37: `ready-for-human`;
- issue 38: `ready-for-human` after feasibility decision;
- issue 15: `needs-info`;
- issue 28: `wontfix`.

### 2026-06-27 - Issues 36 and 37 naming-standard fixes installed

Issues 36 and 37 moved from `needs-triage` to `ready-for-human` after a combined naming-standard implementation.

Decision:

- Issue 36 stays about on-disk Record Folder names.
- Issue 37 stays about user-visible generated Record titles.
- Stable Record identity remains `metadata.json.id`; folder readability is a storage presentation standard, not an ID migration.

Implemented:

- New Record folders use `YYYYMMDD-HHMM-{live|import}-{topic-slug}-{shortid}`.
- Existing legacy folders named by raw ID remain supported.
- Repeated saves for the same `meeting_id` reuse the existing folder by reading `metadata.json`.
- Generated Record titles are cleaned and capped at 44 characters; manual rename still overrides generated titles.

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

### 2026-06-27 - Owner QA filed issues 41 and 42; issue 31 retest failed

Issue 31 moved back to `ready-for-agent` after owner retest on installed build `20260627145522` produced a new crash report with the same microphone capture startup boundary.

New issues filed:

- `.scratch/manual-qa-2026-06-25/issues/41-main-interface-lacks-discoverable-settings-entry.md`
- `.scratch/manual-qa-2026-06-25/issues/42-apple-speech-needs-live-asr-parity-and-diarization-proof.md`

Current status at that point:

- owner retest passed: issues 01, 02, 03, 04, 05, 06, 07, 08, 09, 10, 11, 12, 13, 14, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 29, 30, 32, 33, 34, 35, and 39
- `ready-for-agent`: issues 31, 41, and 42
- `ready-for-human`: issues 36, 37, and 40; issue 38 remains a completed decision record
- `needs-info`: issue 15
- `wontfix`: issue 28

Recommended current next action:

1. Fix issue 31's microphone startup crash because it can terminate the app during QA.
2. Fix issue 41's Settings Workspace discoverability gap.
3. Run issue 42's Apple Speech realtime ASR parity and Diarization spike.

### 2026-06-27 - Issue 31 Obj-C exception-safe microphone startup fix installed

Issue 31 moved back to `ready-for-human` after the follow-up microphone startup crash fix was installed in build `20260627153026`.

Implementation summary:

- Added an `InsightKitObjCShims` SwiftPM target to catch Objective-C `NSException` from AVFAudio.
- Added `ObjCExceptionBridge.perform` for Swift microphone startup code.
- Wrapped `AVAudioNode.installTap` so tap-installation exceptions become recoverable `MicCaptureEngineError.inputTapInstallationFailed` errors instead of process aborts.
- Preserved the existing serial microphone control queue, duplicate-start idempotence, cleanup-on-failure, and retry behavior.

Verification:

- Red-capable proof: a standalone Swift subprocess raising `NSInvalidArgumentException` exits with `Abort trap: 6`, matching the crash class.
- `swift test --package-path macos/InsightKitApp --filter MicCaptureServiceTests`, 5 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests` initially hit one signal-11 runner exit; the named test and a full rerun both passed, 49 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp`, 211 tests, 0 failures.
- `git diff --check`, passed.
- `bash -n scripts/package_insightkit_app.sh`, passed.
- `bash -n scripts/release_preflight.sh`, passed.
- Installed sync: `./scripts/sync_insightkit_app.sh --skip-tests`, build `20260627153026`.
- `codesign --verify --deep --strict --verbose=2 /Users/yann.jy/Applications/InsightKit.app`, passed.
- Sync proof: `logs/workflow/latest_sync.json`.

Current status at that point:

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

- Owner-retest issue 31 in installed build `20260627153026`: open Live Workspace, start microphone or mixed-audio capture repeatedly, stop/restart capture, and confirm the app stays open. If AVFAudio refuses tap installation, the expected behavior is an in-app recoverable microphone startup error.
- Owner-retest issue 41's Settings Workspace entry point in installed build `20260627154910`.
- Then run issue 42's Apple Speech realtime-ASR parity and Diarization spike.

### 2026-06-27 - Issue 41 Settings Workspace entry fix installed

Issue 41 moved from `ready-for-agent` to `ready-for-human` after the Settings Workspace entry fix was installed in build `20260627154910`.

Implementation summary:

- Added a visible Home Workspace `设置` button with a gear icon.
- Added a bottom status bar `设置` action for non-home workspace routes.
- Routed both entries through `WorkflowCoordinator.openSettings()` so they use the same Settings Workspace window as the existing macOS menu command.
- Added `BottomStatusAction.settings` to keep the status-bar action explicit and testable.

Verification:

- Red check: `swift test --package-path macos/InsightKitApp --filter WorkflowCoordinatorTests` initially failed on the missing direct settings action and bottom-status action model.
- `swift test --package-path macos/InsightKitApp --filter WorkflowCoordinatorTests`, 8 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp`, 213 tests, 0 failures.
- `git diff --check`, passed.
- `bash -n scripts/package_insightkit_app.sh`, passed.
- `bash -n scripts/release_preflight.sh`, passed.
- Installed sync: `./scripts/sync_insightkit_app.sh --skip-tests`, build `20260627154910`.
- `codesign --verify --deep --strict --verbose=2 /Users/yann.jy/Applications/InsightKit.app`, passed.
- Visual GUI Proof: `logs/diagnostics/2026-06-27/issue41-home-settings-entry.png`.
- Visual GUI Proof: `logs/diagnostics/2026-06-27/issue41-live-bottom-status-settings-entry.png`.
- Sync proof: `logs/workflow/latest_sync.json`.

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

- Owner-retest issue 41 in installed build `20260627154910`: open Settings from the Home Workspace `设置` button, then from a non-home workspace bottom status bar `设置` action.
- Superseded by the next update: issue 41 owner retest passed, then issue 42 was implemented.

### 2026-06-27 - Issue 41 owner retest passed and issue 42 parity gate installed

Issue 41 passed owner retest.

Issue 42 moved from `ready-for-agent` to `ready-for-human`.

Decision/proof doc:

- `.scratch/manual-qa-2026-06-25/apple-speech-live-parity-and-diarization.md`

Implementation summary:

- Added `AppleSpeechPeerEngineParityStatus` as a testable gate for whether Apple Speech may be exposed as a peer local ASR Engine.
- Added `AppleSpeechRuntimeStatus.shouldExposePeerLocalASREngineOption`.
- Kept `LocalASREngine` limited to Whisper, FunASR, and Qwen3-ASR MLX.
- Updated Settings so the Apple Speech card explicitly says the feature is currently an experimental audio final-media prototype, not a peer ASR Engine.
- Listed blockers for strict-local readiness, Live Workspace realtime transcription, Diarization, and Record/Smart Minutes parity.
- Preserved the existing experimental audio final-media toggle separately from the peer-engine gate.

Verification:

- Red check: `swift test --package-path macos/InsightKitApp --filter AppleSpeechTranscriptionServiceTests` initially failed because `AppleSpeechPeerEngineParityStatus` and `shouldExposePeerLocalASREngineOption` did not exist.
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

- Owner-retest issue 42 in installed build `20260627161028`: open Settings and confirm the Apple Speech card says it is not a peer ASR Engine yet, lists Live Workspace / Diarization / Record and Smart Minutes parity blockers, and leaves the normal ASR Engine picker limited to Whisper, FunASR, and Qwen3-ASR MLX.
- Owner-retest issue 31, issue 40, and the naming-standard issues when convenient.

### 2026-06-27 - Owner QA filed issues 43 and 44 after issue 42 build

Owner QA against installed build `20260627161028` reported another app crash and a transcription failure.

Classification:

- Issue 43 captures the crash boundary. The supplied crash report shows a main-thread Settings action from an in-app banner after a transcription failure. This is a separate crash class from the earlier issue 31 microphone tap startup crash.
- Issue 44 captures the transcription failure and recovery boundary. The owner reported transcription failure, and local state did not show a new saved Record for the latest QA attempt.

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

- Start issue 43 first so the Settings recovery action cannot terminate the app while diagnosing failed transcription.
- Then start issue 44 to preserve or recover the Live transcription result when ASR/finalization fails.
