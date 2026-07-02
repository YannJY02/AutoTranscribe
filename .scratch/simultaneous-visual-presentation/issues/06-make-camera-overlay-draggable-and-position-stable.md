# Make camera overlay draggable and position-stable

Status: ready-for-human

## Parent

`.scratch/simultaneous-visual-presentation/PRD.md`

## What to build

Make the saved-output camera overlay behave like a practical QuickRecorder-style camera overlayer without copying QuickRecorder AGPL code.

When camera and screen are both enabled, the local camera overlay should remain captured in the saved Record video, but the user should be able to move and resize it before or during recording. The overlay should remember its last frame per display and restore it the next time that display is used. If the display layout changes, the restored overlay should stay within the visible screen area.

User stories covered: 1, 2, 3, 8, 9.

## Acceptance criteria

- [x] The camera overlay window can be dragged by its background instead of staying fixed.
- [x] The camera overlay window can be resized with a stable 4:3 aspect ratio and a usable minimum size.
- [x] The overlay remains a non-activating floating window that can join all Spaces and full-screen auxiliary contexts.
- [x] The overlay remains visible to ScreenCaptureKit so the saved-output path can still capture it.
- [x] The overlay frame is remembered per display.
- [x] Restored overlay frames are clamped into the current visible display frame.
- [x] The local camera self-view is mirrored like mature camera overlay tools.
- [x] The implementation uses InsightKit-owned AppKit / AVFoundation code and does not copy QuickRecorder AGPL code.
- [x] Automated tests cover default placement, per-display persistence, and visible-frame clamping.

## Blocked by

None.

## Comments

### 2026-07-02 - Codex

Implemented QuickRecorder-like overlay placement with InsightKit-owned code:
- Added `CameraOverlayPlacement` and `CameraOverlayPlacementStore`.
- Changed the camera overlay panel to use a non-activating, resizable, full-size-content `NSPanel`.
- Enabled drag-by-background through the window and overlay content view.
- Added per-display persisted frames through `UserDefaults`.
- Clamped restored frames into the current visible display frame.
- Preserved floating/cross-Space behavior and rounded clipped preview.
- Mirrored the camera preview for local self-view.

Verification:
- Red loop confirmed the new placement seam was missing before implementation.
- `swift test --package-path macos/InsightKitApp --jobs 1 --filter CameraOverlayPlacementTests`.
- `swift test --package-path macos/InsightKitApp --jobs 1 --filter LiveSessionViewModelTests/testVisualPreviewPlanRoutesCameraAndScreenToCameraOverlay --filter LiveSessionViewModelTests/testCurrentPresentationStatusMarksCameraOverlayPathAsCaptured`.
- `swift test --package-path macos/InsightKitApp --jobs 1`.
- Installed app sync: `./scripts/sync_insightkit_app.sh --skip-tests --debug --install-dir "$HOME/Applications"`.
- Installed-app placement proof: `logs/diagnostics/2026-07-02/camera-overlay-placement/overlay-restored-position.png`.
- Installed-app notes: `logs/diagnostics/2026-07-02/camera-overlay-placement/manual-validation.txt`.

Boundary:
- QuickRecorder was used only as behavior reference. No QuickRecorder source code was copied.
- Computer Use could not directly coordinate-drag the non-activating overlay panel because its tool surface targets the key window. System Events confirmed the independent `InsightKit Camera Overlay` window could move to `{520, 650}`, and after toggling screen off/on the overlay restored at that moved position with the camera image visible.
