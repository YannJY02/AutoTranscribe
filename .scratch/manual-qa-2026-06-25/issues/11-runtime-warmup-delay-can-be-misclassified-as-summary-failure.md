# Runtime warmup delay can be misclassified as a summary failure

Status: ready-for-human

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

At the start of a Live Workspace session, the user observed that the ASR Runtime may still be warming up or not yet producing Transcript Segments. During that early period, the app or its visible summary/error state can make the situation look like a realtime speech-summary problem.

In the captured transcript, the user describes the flow as:

- the prewarm time felt long
- after entering the live transcription page, the model may not have been warmed yet
- for a period, no transcript text was available
- later monitoring or summary state may treat the missing transcript as a summary problem even though the real issue is delayed Runtime Warmup or delayed first Transcript Segment

## What I expected

When a Live Workspace session is waiting for Runtime Warmup or the first Transcript Segment, the app should present that as a normal preparing or transcribing state, not as a realtime speech-summary exception.

If Smart Minutes cannot be refreshed because there is no transcript evidence yet, the app should say that it is waiting for transcript input rather than implying that Insight Refresh or Final Insight Generation has failed.

## Steps to reproduce

1. Launch the installed InsightKit app.
2. Open the Live Workspace.
3. Start recording soon after entering the workspace, before the ASR Runtime is clearly warm.
4. Speak during the first minute of the session.
5. Observe whether there is a gap before the first Transcript Segments appear.
6. Observe whether the realtime speech-summary state treats that gap as an abnormal summary condition instead of a normal Runtime Warmup or waiting-for-transcript condition.

## Additional context

Reported during owner-led manual QA against installed InsightKit build `20260625103254`.

Visible session context:
- meeting ID: `live-37056EA5-F6A0-44D6-9701-7E500A5935AE`
- captured transcript comments mention prewarm delay around `00:18` to `00:44`
- the user suspected the issue may be a misclassification caused by delayed transcription rather than a true Smart Minutes failure
- later transcript rows appeared normally, which supports treating this as a startup/runtime-state classification issue

This is separate from issue 09 and issue 10. Issue 09 is a live Insight Refresh timeout after transcript evidence exists; issue 10 is a Provider non-JSON payload. This issue is about early Runtime Warmup and waiting-for-transcript state being presented too much like a summary failure.

## Comments

### 2026-06-25 - Manual QA

The owner reported that slow prewarm or delayed first transcription may cause the app to misclassify the situation as a realtime speech-summary abnormality. This should be triaged around Runtime Warmup, first Transcript Segment timing, and user-visible Capture State wording.

### 2026-06-25 - Focused triage

Promoted to `ready-for-agent`.

Code triage found this as an error-channel separation problem. `LiveCaptureStateMapper` already has normal states for model warmup and transcription, but `LiveSessionViewModel.evaluateCaptureHealthHint` can write "识别中：当前暂未产出文本..." into `errorMessage`. `ContentView` then renders any `liveViewModel.errorMessage` as "实时语音总结异常", so a normal warmup or waiting-for-first-transcript period can look like a summary failure.

Bounded implementation target:

- move normal warmup/no-transcript hints out of `errorMessage`;
- present them as waiting, preparing, or transcribing status while capture remains healthy;
- reserve the realtime-summary error banner for actual analysis, Provider, ASR, or Sidecar failures;
- keep the user informed that the app is waiting for transcript input when Smart Minutes cannot refresh yet.

Suggested regression loop:

- add a view-model or state-mapper test for the early recording window with no Transcript Segments yet;
- assert that the app exposes a non-error status and does not populate `errorMessage`;
- assert that genuine runtime errors still use the error path.

Dependency note: this should be the first implementation candidate among issues 09-12 because it creates the clearer status/error channel needed by issue 09 and issue 10.

### 2026-06-25 - Diagnosing-bugs implementation pass

Root cause found: `LiveSessionViewModel.evaluateCaptureHealthHint()` wrote the "识别中：当前暂未产出文本..." health hint into `errorMessage`. `ContentView` renders `errorMessage` as the top "实时语音总结异常" banner, so a normal waiting-for-first-transcript period looked like a summary failure.

Implemented:

- Moved live capture health hints into `recordingStatusMessage` instead of `errorMessage`.
- Added `LiveCaptureHealthHint.waitingForTranscript` for the "waiting for Transcript Segment" state.
- Kept genuine analysis and provider failures on the existing `errorMessage` path.
- Cleared transient capture health hints automatically once real Transcript Segments arrive.

Verification:

- Red loop: `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testWaitingForFirstTranscriptUsesRecordingStatusInsteadOfErrorBanner` failed before the fix because `errorMessage` contained "识别中：当前暂未产出文本...".
- Green loop: the same test passed after moving the hint to `recordingStatusMessage`.
- Related gate: `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests` passed, 27 tests.
- Full Swift gate: `swift test --package-path macos/InsightKitApp` passed, 139 tests.
- Standard sync gate: `PATH=/Users/yann.jy/miniconda3/bin:$PATH bash scripts/sync_insightkit_app.sh` passed Swift and Python gates; Python reported `Ran 136 tests ... OK`.

Install status:

- Installed app: `/Users/yann.jy/Applications/InsightKit.app`.
- Installed build: `20260625123538`.
- Sync proof: `logs/workflow/latest_sync.json`.

Owner retest focus:

- Start a live recording soon after opening the Live Workspace.
- During the early waiting period before the first Transcript Segment, the app should not show the top "实时语音总结异常" banner solely because no transcript exists yet.
- A lower-severity recording status may say it is waiting for transcript input.
- Once transcript rows appear, the waiting hint should clear.
