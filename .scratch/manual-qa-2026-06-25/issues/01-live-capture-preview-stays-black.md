# Live capture preview stays black after enabling camera or screen capture

Status: ready-for-human

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

In the Live Workspace, after enabling the camera preview and screen capture controls, the central preview area remained black. No live camera image or screen image was shown.

## What I expected

When camera or screen capture is enabled, the Live Workspace should show a visible live preview in the central Capture Preview area.

If the selected source cannot be shown because of permission, source selection, or device availability, the app should show an actionable message instead of a silent black preview.

## Steps to reproduce

1. Launch the installed InsightKit app.
2. Open the Live Workspace.
3. From the preparing state, enable camera capture from the source controls.
4. Enable screen capture or screen monitoring from the source controls.
5. Observe the central Capture Preview area.

## Additional context

Reported during owner-led manual QA against InsightKit build `20260625003524`.

The observed screen showed the Live Workspace with a large black preview rectangle in the center. The owner expected a live camera or screen preview after clicking the camera and screen controls.

Background context: the Live Workspace has a shared Capture Preview surface for camera and screen capture. This issue should be triaged across both source modes rather than assuming only one source is affected.

Consistency is not yet measured. Permission state and whether camera-only or screen-only preview fail independently should be checked during triage.

## Comments

### 2026-06-25 - Manual QA

Reported during owner-led manual QA against InsightKit build `20260625003524`.

### 2026-06-25 - Batch dependency triage

Promoted to `ready-for-agent`.

Code triage found that the Live Workspace currently reacts to the camera toggle, but the screen toggle is only local UI state and is not wired into a ScreenCaptureKit preview path. `VideoPreviewView` also only attaches the camera preview layer, so this issue should be handled before aspect-ratio and review-media work.

See `.scratch/manual-qa-2026-06-25/triage-dependency-map.md`.

### 2026-06-25 - Diagnosing-bugs implementation pass

Root cause found: the preparing-state Capture Preview only listened to the camera toggle. The screen toggle changed local UI state but never selected a screen preview path, and `VideoPreviewView` could only attach the camera `AVCaptureVideoPreviewLayer`. When no layer existed, the preview area stayed silently black.

Implemented in the workspace:

- Added `LiveVisualPreviewPlan` so camera and screen toggle combinations resolve to an explicit visual preview source.
- Routed both camera and screen source changes through `LiveSessionViewModel.applyVisualPreviewSelection`.
- Added screen preview rendering from the latest ScreenCaptureKit sample buffer, throttled to one retained preview image instead of buffering frames.
- Added visible, actionable preview status messages for permission, missing device, and still-waiting-for-frame states.
- Added regression coverage: `LiveSessionViewModelTests/testVisualPreviewPlanRoutesScreenOnlySelectionToScreenPreview`.

Verification:

- Red loop: `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testVisualPreviewPlanRoutesScreenOnlySelectionToScreenPreview` initially failed because `LiveVisualPreviewPlan` did not exist.
- Green loop: same targeted test passed after implementation.
- Full gate: `swift test --package-path macos/InsightKitApp` passed, 131 tests, 0 failures.

Install status:

- Installed app sync completed together with issues 02 and 08.
- Installed app: `/Users/yann.jy/Applications/InsightKit.app`.
- Installed build: `20260625113541`.
- Sync proof: `logs/workflow/latest_sync.json`.
- Sync gates: Swift package tests passed; Python unittest suite passed with `Ran 136 tests ... OK`.

Owner retest focus:

- Camera-only preview should show either a live camera image or a camera permission/device message.
- Screen-only preview should show either a live screen image or a screen permission/source message.
- The preview area should no longer stay silently black after source controls are enabled.

### 2026-06-25 - Owner retest passed

The owner confirmed that the shared Capture Preview / Record Review media-chain fix was successful.
