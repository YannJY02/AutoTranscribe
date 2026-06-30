# Verify Presenter Overlay capture feasibility

Status: ready-for-human

## Parent

`.scratch/simultaneous-visual-presentation/PRD.md`

## What to build

Verify whether Apple's Presenter Overlay can be captured into InsightKit's saved Record media when the Live Workspace uses camera and screen together.

This slice should produce the smallest useful proof before any broader implementation work. If Presenter Overlay appears only in system sharing UI but not in the saved Record media, record that as a feasibility blocker and do not proceed to app-owned composition automatically.

User stories covered: 1, 2, 3, 8, 9, 10, 12.

## Acceptance criteria

- [x] The Live Workspace can enter a both-enabled camera-plus-screen test path without treating the two visual sources as a hard mutual exclusion.
- [x] A packaged or installed-app validation path is documented for testing Presenter Overlay with real macOS screen and camera permissions.
- [ ] The validation produces a saved Record whose review media can be inspected for whether camera presence appears in the screen recording.
- [x] The result distinguishes `presenter overlay captured` from `screen-only fallback`.
- [ ] If Presenter Overlay is not included in the saved Record media, the issue records a feasibility blocker and stops before custom compositor work.
- [x] App-owned automated checks cover the state transition and fallback classification that can be tested without real system overlay behavior.
- [ ] Owner validation notes are appended because the system overlay itself cannot be fully proven by unit tests.

## Blocked by

None - can start immediately.

## Comments

### 2026-06-30 - Codex

Implemented the app-owned feasibility seam and stopped before broader product implementation.

Changed:
- Camera-plus-screen visual selection now resolves to a Presenter Overlay presentation state instead of camera-only.
- The Live Workspace keeps using screen capture for the system combined-stream path and shows Presenter Overlay guidance.
- `VideoCaptureService` observes ScreenCaptureKit's official overlay video-effect callback and presenter-overlay frame attachment so installed-app validation can distinguish observed overlay from screen-only fallback.
- Added a lightweight `LivePresentationCaptureStatus` classifier for `presenter overlay captured` versus `screen-only fallback`.
- Added installed-app validation checklist: `.scratch/simultaneous-visual-presentation/presenter-overlay-validation.md`.

Verification:
- `swift test --package-path macos/InsightKitApp --jobs 1 --filter LiveSessionViewModelTests/testVisualPreviewPlanRoutesCameraAndScreenToPresenterOverlay --filter LiveSessionViewModelTests/testPresentationCaptureStatusDistinguishesOverlayFromFallback` -> 2 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp --jobs 1 --filter LiveSessionViewModelTests` -> 52 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp --jobs 1` -> 242 tests, 0 failures.
- `python3 scripts/verify_project_normalization.py` -> passed; proof: `logs/diagnostics/2026-06-30/project-normalization-20260630-224332/proof.json`.

Owner validation required:
- Run the installed-app checklist with real camera and screen permissions.
- Classify the result as `presenter overlay captured`, `screen-only fallback`, or `feasibility blocker`.
- Do not mark this issue accepted if the saved Record media does not visibly include Presenter Overlay.
