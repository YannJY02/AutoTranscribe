# Implement saved-output camera overlay path

Status: ready-for-human

## Parent

`.scratch/simultaneous-visual-presentation/PRD.md`

## What to build

Implement InsightKit's own camera-plus-screen saved-output path, using the QuickRecorder validation only as behavior evidence.

When camera and screen are both enabled in Live Workspace, the saved Record video should visibly contain both screen content and camera presence as one reviewable media surface. The implementation may use a simple local camera overlay that is visible to the screen capture stream. Do not copy QuickRecorder AGPL code, and do not build a layout editor or multi-track visual review.

User stories covered: 1, 2, 3, 8, 9, 10, 12.

## Acceptance criteria

- [x] Camera-only still uses the existing camera path.
- [x] Screen-only still uses the existing screen path.
- [x] Camera-plus-screen starts screen capture and shows a local camera overlay that is visible in the captured screen output.
- [x] Stopping and saving the session produces one playable saved Record video.
- [x] Sampled frames from the saved Record video visibly contain both screen content and camera presence.
- [x] Record Review treats the result as one media surface aligned to the Media Timeline.
- [x] Metadata uses a mechanism-accurate status; it must not claim Apple Presenter Overlay if the saved result came from a captured local camera overlay.
- [x] If camera overlay startup fails, the session falls back to screen-only recording with the existing clear warning.
- [x] Automated tests cover presentation-plan routing, fallback status, final-media status derivation, and Record Review status behavior where possible without real camera/screen permissions.
- [x] Installed-app validation artifacts are recorded under `logs/diagnostics/`.

## Blocked by

None. QuickRecorder black-box saved-output validation passed on 2026-07-02 and the owner accepted the saved-output-first direction.

## Implementation notes

- Use Apple platform APIs and InsightKit-owned code only.
- Treat QuickRecorder as behavior evidence, not source-code input.
- The likely mechanism to reproduce is a simple always-on-top camera overlay window visible to ScreenCaptureKit capture, not a post-processing compositor.
- Keep the first implementation minimal: no crop controls, draggable layout persistence, multiple camera layouts, or separate camera media in Record Review.
- Preserve screen-only fallback as the safe default if the combined path degrades final media.

## Comments

### 2026-07-02 - Codex

Implemented the saved-output camera overlay path with InsightKit-owned macOS code.

Changed:
- Added a `screenWithCameraOverlay` visual preview source and `screenPlusCameraCaptured` presentation status.
- Routed camera-plus-screen Live Workspace selection to screen capture plus a local camera overlay window instead of the earlier screen-only fallback.
- Added `VideoCaptureService` support for starting an `AVCaptureSession` preview in a small floating `NSPanel` that is visible to ScreenCaptureKit while the display stream records.
- Kept the existing camera-only and screen-only paths separate.
- Preserved screen-only fallback when camera overlay startup fails.
- Final saved Record metadata now downgrades to `visualMediaUnavailable` when the final media is not a video, and uses `screenPlusCameraCaptured` only for valid saved video from the camera-overlay path.
- Record Review stays quiet for successful `screenPlusCameraCaptured` records and continues surfacing fallback or abnormal visual-media states.

Automated verification:
- `swift test --package-path macos/InsightKitApp --jobs 1 --filter LiveSessionViewModelTests/testVisualPreviewPlanRoutesCameraAndScreenToCameraOverlay --filter LiveSessionViewModelTests/testPresentationCaptureStatusIncludesScreenPlusCameraOverlay --filter LiveSessionViewModelTests/testCurrentPresentationStatusMarksCameraOverlayPathAsCaptured --filter RecordsIndexServiceTests/testRecordReviewShowsPresentationFallbackOnlyWhenCameraWasNotSaved`.
- `swift test --package-path macos/InsightKitApp --jobs 1 --filter LiveSessionViewModelTests/testSaveToRecordsPersistsScreenPlusCameraCaptureStatus --filter LiveSessionViewModelTests/testSaveToRecordsDowngradesScreenPlusCameraWhenFinalMediaIsAudioOnly --filter RecordsIndexServiceTests/testRecordReviewShowsPresentationFallbackOnlyWhenCameraWasNotSaved`.
- `swift test --package-path macos/InsightKitApp --jobs 1 --filter LiveSessionViewModelTests`.
- `swift test --package-path macos/InsightKitApp --jobs 1 --filter RecordsIndexServiceTests`.
- `swift test --package-path macos/InsightKitApp --jobs 1`.

Installed-app verification:
- Sync command: `./scripts/sync_insightkit_app.sh --skip-tests --debug --install-dir "$HOME/Applications"`.
- Installed app: `/Users/yann.jy/Applications/InsightKit.app`.
- Saved Record: `/Users/yann.jy/Documents/InsightKit/Records/20260702-1917-live-record-53301351`.
- Metadata artifact: `logs/diagnostics/2026-07-02/insightkit-saved-output-camera-overlay/record-53301351-metadata.json`.
- Media probe artifact: `logs/diagnostics/2026-07-02/insightkit-saved-output-camera-overlay/record-53301351-ffprobe.json`.
- Extracted frame artifact: `logs/diagnostics/2026-07-02/insightkit-saved-output-camera-overlay/record-53301351-frame-008s.png`.

Result:
- The saved Record contains one playable `recording.mp4`.
- Metadata reports `"mediaType": "video"` and `"presentationStatus": "screenPlusCameraCaptured"`.
- `ffprobe` reports one AAC audio stream and one H.264 video stream, both 19.890s; video is 1728x1116.
- The extracted saved-video frame visibly contains screen content plus the local camera overlay.

This issue is ready for human review. No QuickRecorder code was copied.
