# Camera preview aspect ratio is overly wide during live recording

Status: ready-for-human

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

After enabling camera capture and starting a live recording, the camera preview appeared as an overly wide strip. The frame did not show the camera image in a normal media format, and the visible image was vertically cropped.

## What I expected

The Live Workspace should show the camera preview in a normal media aspect ratio that matches the selected source or a standard camera preview format.

The preview should fit the Capture Preview area without excessive horizontal stretching or unexpected vertical cropping.

## Steps to reproduce

1. Launch the installed InsightKit app.
2. Open the Live Workspace.
3. Enable camera capture from the source controls.
4. Start live recording.
5. Observe the camera preview in the running Live Workspace.

## Additional context

Reported during owner-led manual QA against InsightKit build `20260625003524`.

The screenshot showed the camera image displayed as a very wide horizontal preview while the session was recording. The user's face and camera background were visible, but the preview did not preserve a normal camera viewing frame.

This should be triaged separately from black-screen preview behavior because camera frames did appear in this report, but the preview sizing and cropping were wrong.

The issue may need to be checked in both preparing and running session phases, and across different window sizes.

## Comments

### 2026-06-25 - Manual QA

Reported during owner-led manual QA against InsightKit build `20260625003524`.

### 2026-06-25 - Batch dependency triage

Promoted to `ready-for-agent`.

Code triage found that the camera preview uses `.resizeAspectFill`, which fills the preview container by cropping. This matches the owner-visible overly wide/cropped camera image. Handle this after or alongside issue 01 so the preview source is reliable before visual acceptance.

See `.scratch/manual-qa-2026-06-25/triage-dependency-map.md`.

### 2026-06-25 - Diagnosing-bugs implementation pass

Root cause found: the camera preview used `resizeAspectFill`, which fills the preview container by cropping the image. The running-state preview container also allowed the preview to stretch into a very wide strip.

Implemented:

- Changed camera preview gravity to `resizeAspect`, so the full camera frame is shown instead of being vertically cropped.
- Added `LiveVisualPreviewLayout.previewSize` to keep Capture Preview in a standard 16:9 media frame.
- Applied the same bounded preview frame in preparing and running Session Phases.
- Added regression coverage:
  - `LiveSessionViewModelTests/testCameraPreviewLayerUsesAspectFitToAvoidCropping`
  - `LiveSessionViewModelTests/testRunningPreviewLayoutPreservesStandardMediaAspectRatio`

Verification:

- Red loop: target test failed with `AVLayerVideoGravityResizeAspectFill` not equal to `AVLayerVideoGravityResizeAspect`.
- Green loop: the two issue 02 tests passed after implementation.
- Full gate: `swift test --package-path macos/InsightKitApp` passed, 135 tests, 0 failures.
- Installed app sync completed together with issues 01 and 08.
- Installed app: `/Users/yann.jy/Applications/InsightKit.app`.
- Installed build: `20260625113541`.
- Sync proof: `logs/workflow/latest_sync.json`.
- Sync gates: Swift package tests passed; Python unittest suite passed with `Ran 136 tests ... OK`.

Owner retest focus:

- Camera preview should no longer appear as an overly wide cropped strip.
- Preparing and running previews should preserve a normal 16:9 media frame across the current window size.

### 2026-06-25 - Owner retest passed

The owner confirmed that the shared Capture Preview / Record Review media-chain fix was successful.
