# Route both visual toggles to saved visual presentation

Status: ready-for-human

## Parent

`.scratch/simultaneous-visual-presentation/PRD.md`

## What to build

When the user enables both camera and screen in the Live Workspace, route the state to saved visual presentation instead of making one visual source silently replace the other.

The existing camera and screen toggles should remain. The user should see a clear state such as `屏幕录制 + 摄像头叠加`. Camera-only and screen-only behavior must keep working.

User stories covered: 1, 2, 3, 4, 5, 6, 7, 11.

## Acceptance criteria

- [x] Camera-only still resolves to the existing camera preview behavior.
- [x] Screen-only still resolves to the existing screen preview behavior.
- [x] Camera-plus-screen resolves to a saved visual presentation state when the saved-output path is available.
- [x] The Live Workspace keeps the existing camera and screen toggles; no separate presentation-mode button is introduced.
- [x] The both-enabled state shows clear user guidance.
- [x] If simultaneous visual presentation is unavailable or not enabled, screen capture remains usable.
- [x] The fallback message clearly says camera presence will not be included in this Record.
- [x] Turning one visual source off keeps the other active instead of stopping the whole visual preview.
- [x] Unsupported macOS versions fall back to screen-only behavior without raising InsightKit's minimum supported macOS version.

## Blocked by

None. Issue 05 implemented and validated the saved-output camera overlay path.

## Comments

### 2026-07-01 - Codex

Implemented the first app-owned routing candidate:
- `LiveVisualPreviewPlan` keeps camera-only and screen-only as first-class preview modes.
- Camera-plus-screen originally resolved to `.presenterOverlay` with macOS Presenter Overlay guidance.
- The Live Workspace keeps the existing camera and screen toggles.
- Visual mode changes synchronously stop the previous capture before starting the next one, preventing an older async stop from tearing down the new screen stream.
- Screen capture remained usable when Presenter Overlay was not visible.
- The installed-app validation confirmed camera and screen can be on together and screen preview remains active.

Verification:
- `swift test --package-path macos/InsightKitApp --jobs 1 --filter LiveSessionViewModelTests/testVisualPreviewPlanRoutesCameraAndScreenToPresenterOverlay --filter LiveSessionViewModelTests/testPresentationCaptureStatusDistinguishesOverlayFromFallback`.
- Installed-app proof: `logs/diagnostics/2026-06-30/presenter-overlay-validation-video-writer/live-preview-camera-screen.png`.

### 2026-07-01 - Strict native reclassification

This routing work remains useful only if Apple's native Presenter Overlay path can produce visible camera presence in the saved Record video. The previous installed-app proof showed screen preview and valid video, but strict saved-video frame review found screen-only media. Do not treat the both-enabled route as product-accepted until issue 01 passes the stricter Apple-native proof.

The 2026-07-01 Apple-native revalidation confirmed the routing UI can enter the both-enabled state, but it still did not produce accepted saved media: the saved Record was audio-only and the temp `recording.mp4` was invalid. Keep the guidance path only as a candidate shell around an official native capture flow; do not present it as a completed FaceTime-style feature.

### 2026-07-01 - Default route changed to screen-only fallback

A follow-up official `SCContentSharingPicker` attempt plus active camera capture session still failed the saved-video gate. The saved Record was audio-only with `presentationStatus: visualMediaUnavailable`, and the temp `recording.mp4` was invalid (`moov atom not found`).

At this point in the investigation, the owner preferred no feature over a non-native or unproven substitute, so the default camera-plus-screen route was changed back to normal screen capture. The Live Workspace now tells the user that only the screen will be saved and camera presence will not be written to this Record.

This was superseded by the 2026-07-02 saved-output-first decision: a captured local camera overlay is acceptable if the saved Record video visibly contains screen plus camera presence and the app does not claim Presenter Overlay.

### 2026-07-01 - Fallback route installed and validated

Hardened the screen-only fallback route after the official Apple-native path failed:
- Camera-plus-screen now resolves to normal screen capture, not the unproven Presenter Overlay capture flow.
- The Live Workspace fallback copy says camera presence will not be written to this Record.
- `VideoCaptureService` now sizes the video writer from the active ScreenCaptureKit stream, fixing the invalid temp mp4 seen when the writer used a fixed 1920x1080 size against a different display stream.

Validation:
- Installed-app fallback Record `~/Documents/InsightKit/Records/20260701-1133-live-record-5393c4b3` saved a playable screen-only `recording.mp4`.
- `logs/diagnostics/2026-07-01/apple-native-presenter-overlay-feasibility/record-5393c4b3-ffprobe.json` shows one audio stream and one H.264 video stream, both 18.000s.
- Installed-app fallback copy was visible during finalization: `当前仅保存屏幕；摄像头不会写入本次 Record。FaceTime 式演示者画面暂不可用。`

This validates the fallback shell, not the simultaneous visual presentation feature. The saved-output acceptance criterion remains blocked until issue 05 produces an InsightKit-owned saved video with visible screen and camera presence.

### 2026-07-02 - Route target changed to saved-output-first

QuickRecorder black-box validation proved a playable saved video with screen plus person, and source inspection showed the likely useful mechanism is a visible camera overlay captured into the screen recording. The owner accepted the saved-output-first direction.

This issue should now route camera-plus-screen toward InsightKit's own saved visual presentation path, not only Apple Presenter Overlay guidance. If the implementation uses a local camera overlay, UI copy should say camera overlay rather than Presenter Overlay. Screen-only fallback remains the safe default until issue 05 passes installed-app saved-video validation.

### 2026-07-02 - Camera-plus-screen route implemented and validated

Updated the route so camera-plus-screen resolves to `.screenWithCameraOverlay`, starts screen capture with a local camera overlay, and reports `screenPlusCameraCaptured` when final saved media remains a valid video. Camera-only and screen-only routes remain separate first-class paths. If camera overlay startup fails, the Live Workspace falls back to screen-only capture with the existing clear warning.

Verification:
- Focused route/status tests: `swift test --package-path macos/InsightKitApp --jobs 1 --filter LiveSessionViewModelTests/testVisualPreviewPlanRoutesCameraAndScreenToCameraOverlay --filter LiveSessionViewModelTests/testPresentationCaptureStatusIncludesScreenPlusCameraOverlay --filter LiveSessionViewModelTests/testCurrentPresentationStatusMarksCameraOverlayPathAsCaptured --filter RecordsIndexServiceTests/testRecordReviewShowsPresentationFallbackOnlyWhenCameraWasNotSaved`.
- Installed-app saved Record: `/Users/yann.jy/Documents/InsightKit/Records/20260702-1917-live-record-53301351`.
- Extracted saved-video frame: `logs/diagnostics/2026-07-02/insightkit-saved-output-camera-overlay/record-53301351-frame-008s.png`.

This issue is ready for human review.
