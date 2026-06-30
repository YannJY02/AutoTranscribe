# Route both visual toggles to Presenter Overlay guidance

Status: ready-for-human

## Parent

`.scratch/simultaneous-visual-presentation/PRD.md`

## What to build

When the user enables both camera and screen in the Live Workspace, route the state to Apple Presenter Overlay guidance instead of making one visual source silently replace the other.

The existing camera and screen toggles should remain. The user should see a clear state such as `屏幕录制 + Presenter Overlay`, plus guidance when macOS requires system-level confirmation. Camera-only and screen-only behavior must keep working.

User stories covered: 1, 2, 3, 4, 5, 6, 7, 11.

## Acceptance criteria

- [x] Camera-only still resolves to the existing camera preview behavior.
- [x] Screen-only still resolves to the existing screen preview behavior.
- [x] Camera-plus-screen resolves to a Presenter Overlay presentation state when the system path is available.
- [x] The Live Workspace keeps the existing camera and screen toggles; no separate presentation-mode button is introduced.
- [x] The both-enabled state shows clear user guidance for enabling or confirming Presenter Overlay through macOS when required.
- [x] If Presenter Overlay is unavailable or not enabled, screen capture remains usable.
- [x] The fallback message clearly says camera presence will not be included in this Record.
- [x] Turning one visual source off keeps the other active instead of stopping the whole visual preview.
- [x] Unsupported macOS versions fall back to screen-only behavior without raising InsightKit's minimum supported macOS version.

## Blocked by

- `.scratch/simultaneous-visual-presentation/issues/01-verify-presenter-overlay-capture-feasibility.md`

## Comments

### 2026-07-01 - Codex

Implemented the app-owned routing path:
- `LiveVisualPreviewPlan` keeps camera-only and screen-only as first-class preview modes.
- Camera-plus-screen resolves to `.presenterOverlay` with macOS Presenter Overlay guidance.
- The Live Workspace keeps the existing camera and screen toggles.
- Visual mode changes synchronously stop the previous capture before starting the next one, preventing an older async stop from tearing down the new screen stream.
- Screen capture remains usable when Presenter Overlay is not visible.
- The installed-app validation confirmed camera and screen can be on together and screen preview remains active.

Verification:
- `swift test --package-path macos/InsightKitApp --jobs 1 --filter LiveSessionViewModelTests/testVisualPreviewPlanRoutesCameraAndScreenToPresenterOverlay --filter LiveSessionViewModelTests/testPresentationCaptureStatusDistinguishesOverlayFromFallback`.
- Installed-app proof: `logs/diagnostics/2026-06-30/presenter-overlay-validation-video-writer/live-preview-camera-screen.png`.
