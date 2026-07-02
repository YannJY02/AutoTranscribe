# Verify saved-output simultaneous presentation feasibility

Status: ready-for-human

## Parent

`.scratch/simultaneous-visual-presentation/PRD.md`

## What to build

Verify whether a camera-plus-screen Live Workspace session can produce saved media where the saved Record video visibly contains both screen content and camera presence.

This slice should produce the smallest useful proof before broader implementation work. Presenter Overlay remains a candidate mechanism, but the accepted product standard is now saved-output-first: the saved media must visibly contain both screen and camera/person presence.

User stories covered: 1, 2, 3, 8, 9, 10, 12.

## Acceptance criteria

- [x] The Live Workspace can enter a both-enabled camera-plus-screen test path without treating the two visual sources as a hard mutual exclusion.
- [x] A packaged or installed-app validation path is documented for testing Presenter Overlay with real macOS screen and camera permissions.
- [x] The validation produces a saved Record whose review media can be inspected for whether camera presence appears in the screen recording.
- [x] The result distinguishes `presenter overlay captured` from `screen-only fallback`.
- [x] If Presenter Overlay is not included in the saved Record media, the issue records a feasibility blocker and stops before custom compositor work.
- [x] App-owned automated checks cover the state transition and fallback classification that can be tested without real system overlay behavior.
- [x] Owner validation notes are appended because the system overlay itself cannot be fully proven by unit tests.
- [x] External black-box validation shows the saved-output result is feasible on this Mac.
- [x] An InsightKit-owned installed-app run saves a playable Record video whose sampled frames visibly include both screen content and camera presence.

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

### 2026-07-01 - Codex installed-app validation

Ran the installed-app validation with real camera and screen permissions through Computer Use.

Evidence:
- Sync proof: `logs/diagnostics/2026-06-30/presenter-overlay-validation-video-writer/latest_sync.json`.
- Preview proof: `logs/diagnostics/2026-06-30/presenter-overlay-validation-video-writer/live-preview-camera-screen.png`.
- Recording proof: `logs/diagnostics/2026-06-30/presenter-overlay-validation-video-writer/live-recording-running.png`.
- Review proof: `logs/diagnostics/2026-06-30/presenter-overlay-validation-video-writer/live-review-video-record.png`.
- ScreenCaptureKit log: `logs/diagnostics/2026-06-30/presenter-overlay-validation-video-writer/screencapturekit-recording.log`.
- Saved Record: `~/Documents/InsightKit/Records/20260701-0021-live-record-f2567901`.

Result:
- `recording.mp4` was saved as the Record media.
- `ffprobe` found one audio stream and one video stream, both 34.000s.
- `metadata.json` contains `"mediaType": "video"` and `"presentationStatus": "presenterOverlayCaptured"`.

### 2026-07-01 - Strict native reclassification

Owner clarified that success requires strict FaceTime-style Apple-native behavior: the saved Record video must visibly show both screen content and camera presence. Metadata, ScreenCaptureKit callbacks, and a valid screen video are not enough.

Additional proof extracted from the saved Record:
- `logs/diagnostics/2026-07-01/presenter-overlay-strict-native-review/frame-05s.png`
- `logs/diagnostics/2026-07-01/presenter-overlay-strict-native-review/frame-17s.png`
- `logs/diagnostics/2026-07-01/presenter-overlay-strict-native-review/frame-29s.png`
- `logs/diagnostics/2026-07-01/presenter-overlay-strict-native-review/ffprobe-video.json`

The sampled frames show screen-only media with no visible camera presence. Under the strict standard, this run is `screen-only fallback`, not accepted Presenter Overlay capture. Re-verify the Apple-native path before accepting this issue; if it cannot produce visible camera presence in saved media, do not build a custom compositor fallback.

### 2026-07-01 - Apple-native installed-app revalidation

Re-ran the installed app through the Live Workspace without a UI-test route. Camera and screen toggles could both be enabled, and the app showed screen capture with macOS Presenter Overlay guidance. Attempts to open or steer the macOS Presenter Overlay system control were inconclusive; a purple screen/person menu-bar affordance was visible, but no reliable system panel state was captured.

Evidence:
- Sync proof: `logs/workflow/latest_sync.json`.
- Both-enabled state: `logs/diagnostics/2026-07-01/apple-native-presenter-overlay-feasibility/desktop-insightkit-both-enabled.png`.
- System-control artifacts: `logs/diagnostics/2026-07-01/apple-native-presenter-overlay-feasibility/menu-bar-control-cluster.png`, `presenter-overlay-menu-open.png`, `control-center-open.png`.
- Saved Record state: `logs/diagnostics/2026-07-01/apple-native-presenter-overlay-feasibility/record-1047-saved-record-state.txt`.
- Temp video integrity: `logs/diagnostics/2026-07-01/apple-native-presenter-overlay-feasibility/record-1047-temp-video-integrity.txt`.
- Saved Record: `~/Documents/InsightKit/Records/20260701-1047-live-record-ac842402`.

Result:
- The saved Record contains `recording.wav` but no saved `recording.mp4`.
- `metadata.json` reports `"mediaType": "audio"` and `"presentationStatus": "presenterOverlayCaptured"` at the same time.
- The temp `recording.mp4` exists but is invalid reviewable media: `ffprobe` reports `moov atom not found`, and atom scan found `ftyp` and `mdat` but no `moov`.

Current classification: `feasibility not proven`. The app-owned state path exists, but the strict Apple-native saved-video proof has not passed. The next implementation step must either use an official Apple-native sharing/presenter path that can pass this saved-video gate, or keep the simultaneous visual presentation feature unaccepted.

### 2026-07-01 - Official picker attempt still fails saved-video gate

Implemented and installed a stricter Apple-native attempt using the official `SCContentSharingPicker` path plus an active camera capture session for macOS Presenter Overlay. The app was revalidated through the real Live Workspace.

Evidence:
- Saved Record state: `logs/diagnostics/2026-07-01/apple-native-presenter-overlay-feasibility/record-856e0c8b-saved-record-state.txt`.
- Temp video integrity: `logs/diagnostics/2026-07-01/apple-native-presenter-overlay-feasibility/record-856e0c8b-temp-video-integrity.txt`.
- Saved Record: `~/Documents/InsightKit/Records/20260701-1118-live-record-856e0c8b`.

Result:
- The saved Record contains `recording.wav` but no saved `recording.mp4`.
- Metadata now correctly reports `"presentationStatus": "visualMediaUnavailable"` instead of claiming success.
- The temp `recording.mp4` is still invalid reviewable media: `ffprobe` reports `moov atom not found`, and atom scan found no `moov`.

Current product decision:
- This issue remains `needs-info`; the strict Apple-native saved-video proof has not passed.
- The default app path should not launch this unproven Presenter Overlay capture as a completed feature.
- Camera-plus-screen should fall back to screen recording with a clear message that camera presence will not be written to the Record.

### 2026-07-01 - Screen-only fallback is not success

The default camera-plus-screen route was hardened after the strict Apple-native path failed. Installed-app validation produced a playable fallback screen video at `~/Documents/InsightKit/Records/20260701-1133-live-record-5393c4b3`, with ffprobe evidence in `logs/diagnostics/2026-07-01/apple-native-presenter-overlay-feasibility/record-5393c4b3-ffprobe.json`.

This is useful fallback behavior, not Presenter Overlay acceptance:
- The video is screen-only.
- No sampled or observed saved media shows camera presence.
- The strict Apple-native acceptance criterion remains unchecked.

### 2026-07-01 - Open-source prior-art review

Reviewed existing open-source screen-recorder and presenter-overlay projects for reusable implementation paths. The detailed notes are in `.scratch/simultaneous-visual-presentation/open-source-prior-art.md`.

Conclusion:
- QuickRecorder is the strongest behavior reference because it produces the saved-output result and its source shows both Presenter Overlay observation and a Camera Overlayer path, but it is AGPL-3.0 and should be treated as behavior reference only unless a separate license decision is made.
- EasyDemo, OpenCapture, openscreen, and ariso-ai/presenter-overlay are MIT and have reusable camera-overlay or native-helper modules, but they solve broader custom overlay/composition problems than the first InsightKit slice needs.
- No reviewed project provides a direct drop-in module for InsightKit.
- The useful implementation direction is to reproduce the saved-output result with InsightKit-owned code, not to copy QuickRecorder.

### 2026-07-02 - QuickRecorder black-box saved-video validation passed

Ran QuickRecorder `1.6.9` (`CFBundleVersion` `169`, bundle id `com.lihaoyun6.QuickRecorder`) as an external black-box reference on the same Mac. No QuickRecorder code was copied into InsightKit.

Evidence:
- Saved video: `/Users/yann.jy/Desktop/Recording at 2026-07-02 18.42.36.mp4`.
- Manual verification screenshot copied to `logs/diagnostics/2026-07-02/quickrecorder-blackbox/manual-verified-screen-plus-person.png`.
- Extracted saved-video frame: `logs/diagnostics/2026-07-02/quickrecorder-blackbox/quickrecorder-latest-frame-034s.png`.

Media probe through AVFoundation:
- `playable=true`.
- Duration: `40.00833333333333` seconds.
- Video track: `3456x2234`, nominal frame rate about `72.36`.

Result:
- The extracted saved-video frame visibly contains both screen content and camera/person presence.
- This proves an external QuickRecorder path can save a playable video with screen plus person on this Mac.
- This is not yet InsightKit acceptance: InsightKit still has not saved its own playable Record video with screen plus visible person.
- Source inspection shows QuickRecorder intentionally does not exclude its `Camera Overlayer` from screen capture, so the likely useful mechanism is a visible camera overlay captured into the same saved screen video.

Next implementation input:
- Treat QuickRecorder as feasibility evidence and behavior reference, not source-code input.
- Reimplement the accepted saved-output path from Apple platform APIs and InsightKit-owned seams.
- Do not copy QuickRecorder AGPL-3.0 code into InsightKit.

### 2026-07-02 - InsightKit saved-output camera overlay validation passed

Implemented and installed an InsightKit-owned saved-output camera overlay path. Camera-plus-screen now routes to a local camera overlay that remains visible to the screen recording, and saved Record metadata uses `screenPlusCameraCaptured` so it does not claim Apple Presenter Overlay.

Evidence:
- Installed app: `/Users/yann.jy/Applications/InsightKit.app`.
- Saved Record: `/Users/yann.jy/Documents/InsightKit/Records/20260702-1917-live-record-53301351`.
- Metadata snapshot: `logs/diagnostics/2026-07-02/insightkit-saved-output-camera-overlay/record-53301351-metadata.json`.
- Media probe: `logs/diagnostics/2026-07-02/insightkit-saved-output-camera-overlay/record-53301351-ffprobe.json`.
- Extracted saved-video frame: `logs/diagnostics/2026-07-02/insightkit-saved-output-camera-overlay/record-53301351-frame-008s.png`.

Result:
- The Record saved one playable `recording.mp4`.
- `metadata.json` reports `"mediaType": "video"` and `"presentationStatus": "screenPlusCameraCaptured"`.
- `ffprobe` reports one AAC audio stream and one H.264 video stream, both 19.890s; video is 1728x1116.
- The extracted frame visibly contains screen content and the local camera overlay.

Classification: InsightKit saved-output simultaneous presentation passed through the accepted local camera overlay mechanism. Apple Presenter Overlay remains unproven as a strict saved-video mechanism, but this issue's saved-output feasibility criterion is now satisfied.
