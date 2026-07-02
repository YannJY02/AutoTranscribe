# Saved-Output Visual Presentation Validation

Use this document to keep the validation boundary clear for simultaneous visual presentation. The current acceptance standard is saved-output-first: the saved Record video must visibly contain both screen content and camera presence.

Apple Presenter Overlay remains a preferred mechanism when it passes that saved-video standard. A local camera overlay captured by ScreenCaptureKit is also acceptable under the 2026-07-02 product decision, but it must be described as a camera overlay rather than Presenter Overlay.

## Setup

1. Sync a current installed app:

   ```bash
   ./scripts/sync_insightkit_app.sh --skip-tests --debug --install-dir "$HOME/Applications"
   ```

2. Open `~/Applications/InsightKit.app`.
3. Make sure macOS screen recording and camera permissions are granted for InsightKit.

## Presenter Overlay Validation Run

1. Open the Live Workspace.
2. Enable screen and camera.
3. Confirm the Live Workspace shows a Presenter Overlay-specific state or guidance.
4. Use macOS system UI, such as the video effects menu, to enable Presenter Overlay if macOS requires it.
5. Record 15-30 seconds with a visually obvious screen marker and visible camera presence.
6. Stop and save the session.
7. Open the saved Record Review media.

## Result Classification

- `presenter overlay captured`: the saved Record media shows both the screen marker and the camera presence.
- `screen-only fallback`: the saved Record media shows the screen marker but no camera presence, and InsightKit warned that camera presence would not be included.
- `feasibility blocker`: Presenter Overlay was visible in system UI but did not appear in the saved Record media.

If the result is `feasibility blocker`, do not treat callbacks, metadata, or a temporary video file as success. Record the finding on issue 01 and use issue 05 for the accepted saved-output camera overlay path.

## 2026-07-01 Codex Validation Result

Validated with `/Users/yann.jy/Applications/InsightKit.app` synced from local dirty workspace.

Evidence:
- Sync proof: `logs/diagnostics/2026-06-30/presenter-overlay-validation-video-writer/latest_sync.json`
- Preview screenshot: `logs/diagnostics/2026-06-30/presenter-overlay-validation-video-writer/live-preview-camera-screen.png`
- Running recording screenshot: `logs/diagnostics/2026-06-30/presenter-overlay-validation-video-writer/live-recording-running.png`
- Review screenshot: `logs/diagnostics/2026-06-30/presenter-overlay-validation-video-writer/live-review-video-record.png`
- ScreenCaptureKit log: `logs/diagnostics/2026-06-30/presenter-overlay-validation-video-writer/screencapturekit-recording.log`
- Saved Record: `~/Documents/InsightKit/Records/20260701-0021-live-record-f2567901`

Observed:
- Camera and screen toggles can be on together.
- Screen preview remains live in the both-enabled state.
- The saved Record contains `recording.mp4`, `capture_timeline.json`, transcript, notes, minutes, and metadata.
- `ffprobe` reports one audio stream and one video stream, both 34.000s.
- `metadata.json` has `"mediaType": "video"` and `"presentationStatus": "presenterOverlayCaptured"`.

Original classification: `presenter overlay captured`.

## 2026-07-01 Strict Native Reclassification

Reclassified after owner feedback that the feature must use strict FaceTime-style Apple-native behavior and must visibly show camera presence in the saved Record video.

Additional evidence:
- Extracted frame: `logs/diagnostics/2026-07-01/presenter-overlay-strict-native-review/frame-17s.png`
- Frame set: `logs/diagnostics/2026-07-01/presenter-overlay-strict-native-review/frame-05s.png`, `frame-17s.png`, `frame-29s.png`
- Video probe: `logs/diagnostics/2026-07-01/presenter-overlay-strict-native-review/ffprobe-video.json`
- Source Record: `~/Documents/InsightKit/Records/20260701-0021-live-record-f2567901/recording.mp4`

Observed:
- The saved media is a valid screen video.
- The sampled saved-video frames do not visibly include camera presence.
- The previous `presenterOverlayCaptured` metadata classification is not sufficient proof of FaceTime-style presentation.

Classification: `screen-only fallback` under the strict saved-video visibility standard.

## 2026-07-01 Apple-Native Installed-App Revalidation

Validated `/Users/yann.jy/Applications/InsightKit.app` after syncing the local workspace to build `20260701103530`.

Evidence:
- Sync proof: `logs/workflow/latest_sync.json`
- Both-enabled UI screenshot: `logs/diagnostics/2026-07-01/apple-native-presenter-overlay-feasibility/desktop-insightkit-both-enabled.png`
- System control attempts: `logs/diagnostics/2026-07-01/apple-native-presenter-overlay-feasibility/menu-bar-control-cluster.png`, `presenter-overlay-menu-open.png`, `control-center-open.png`
- Saved Record state: `logs/diagnostics/2026-07-01/apple-native-presenter-overlay-feasibility/record-1047-saved-record-state.txt`
- Temp video integrity check: `logs/diagnostics/2026-07-01/apple-native-presenter-overlay-feasibility/record-1047-temp-video-integrity.txt`
- Saved Record: `~/Documents/InsightKit/Records/20260701-1047-live-record-ac842402`
- Temp capture folder: `/private/var/folders/qj/rpkv85p52_j3qx851dzbcvsr0000gn/T/InsightKit/live-F677C4D8-961C-430C-9A7A-135AAC842402`

Observed:
- The installed app allowed camera and screen toggles to be on together.
- The Live Workspace preview showed screen capture and guidance to confirm macOS Presenter Overlay, but did not visibly show camera presence.
- The saved Record directory contains `recording.wav`, `metadata.json`, `notes.md`, `minutes.json`, and `transcript.json`, but no saved `recording.mp4`.
- `metadata.json` reports `"mediaType": "audio"` while also reporting `"presentationStatus": "presenterOverlayCaptured"`.
- A temp `recording.mp4` existed, but `ffprobe` reported `moov atom not found`; atom scan found `ftyp` and `mdat`, but no `moov`, so the temp video is not valid reviewable media.

Classification: `feasibility not proven`; the current installed-app behavior fails the strict saved-Record standard.

Follow-up gate:
- Do not treat ScreenCaptureKit callbacks, `presenterOverlayCaptured` metadata, or temporary video bytes as success.
- A future pass must prove an Apple-native path by saving a playable Record video whose sampled frames visibly include both screen content and camera presence.

## 2026-07-01 Official Picker + Camera Session Revalidation

Validated `/Users/yann.jy/Applications/InsightKit.app` after adding the official `SCContentSharingPicker` path and keeping an active camera capture session for macOS Presenter Overlay to consume.

Evidence:
- Saved Record state: `logs/diagnostics/2026-07-01/apple-native-presenter-overlay-feasibility/record-856e0c8b-saved-record-state.txt`
- Temp video integrity check: `logs/diagnostics/2026-07-01/apple-native-presenter-overlay-feasibility/record-856e0c8b-temp-video-integrity.txt`
- Saved Record: `~/Documents/InsightKit/Records/20260701-1118-live-record-856e0c8b`
- Temp capture folder: `/private/var/folders/qj/rpkv85p52_j3qx851dzbcvsr0000gn/T/InsightKit/live-36E24246-E427-4863-AF56-9605856E0C8B`

Observed:
- The saved Record directory contains `recording.wav`, `metadata.json`, `notes.md`, `minutes.json`, and `transcript.json`, but no saved `recording.mp4`.
- `metadata.json` now correctly reports `"mediaType": "audio"` and `"presentationStatus": "visualMediaUnavailable"`.
- A temp `recording.mp4` existed, but `ffprobe` again reported `moov atom not found`; atom scan found `ftyp`, `wide`, and `mdat`, but no `moov`, so the temp video is not valid reviewable media.

Classification: `feasibility not proven`; the stricter Apple-native path still does not pass the saved-Record video requirement.

Product action:
- Do not ship the FaceTime-style simultaneous visual presentation feature from this evidence.
- Default camera-plus-screen behavior should fall back to normal screen recording and clearly state that camera presence will not be saved.
- Do not build a custom camera-tile compositor without a new owner decision.

## 2026-07-01 Screen-Only Fallback Hardening

After the official Apple-native path failed the saved-video gate, the default camera-plus-screen behavior was changed to normal screen recording with a clear warning that camera presence will not be saved.

Evidence:
- Valid fallback video Record: `~/Documents/InsightKit/Records/20260701-1133-live-record-5393c4b3`
- Valid fallback video state: `logs/diagnostics/2026-07-01/apple-native-presenter-overlay-feasibility/record-5393c4b3-screen-fallback-video-state.txt`
- Valid fallback video probe: `logs/diagnostics/2026-07-01/apple-native-presenter-overlay-feasibility/record-5393c4b3-ffprobe.json`
- Visual-media-unavailable fallback state: `logs/diagnostics/2026-07-01/apple-native-presenter-overlay-feasibility/record-35606308-visual-media-unavailable-state.txt`

Observed:
- Using the real installed app, a camera-plus-screen run saved a playable `recording.mp4` after the screen writer was changed to use the active ScreenCaptureKit stream size instead of a fixed 1920x1080 writer size.
- The valid fallback video has one audio stream and one H.264 video stream, both 18.000s.
- The saved video is still screen-only and has no visible camera presence, so it is not accepted simultaneous visual presentation.
- A later short/unstable run that did not produce valid video saved audio only and correctly wrote `"presentationStatus": "visualMediaUnavailable"`.
- The Live Workspace surfaced the fallback copy: `当前仅保存屏幕；摄像头不会写入本次 Record。FaceTime 式演示者画面暂不可用。`

Classification: fallback hardening passed; Apple Presenter Overlay simultaneous presentation remains unproven and unshipped.

## 2026-07-02 QuickRecorder Black-Box Reference Validation

Validated QuickRecorder `1.6.9` (`CFBundleVersion` `169`, bundle id `com.lihaoyun6.QuickRecorder`) as an external reference on the same Mac. No QuickRecorder source code was copied into InsightKit.

Evidence:
- Saved video: `/Users/yann.jy/Desktop/Recording at 2026-07-02 18.42.36.mp4`
- Manual verification screenshot: `logs/diagnostics/2026-07-02/quickrecorder-blackbox/manual-verified-screen-plus-person.png`
- Extracted saved-video frame: `logs/diagnostics/2026-07-02/quickrecorder-blackbox/quickrecorder-latest-frame-034s.png`

Observed:
- AVFoundation loads the saved video as playable.
- The saved video is 40.00833333333333 seconds with a 3456x2234 video track.
- The extracted frame at about 34 seconds visibly contains both screen content and camera/person presence.
- The owner also manually verified the latest saved QuickRecorder video.

Classification: external QuickRecorder saved-output path passes the screen-plus-person visual result.

Boundary:
- This does not mark InsightKit's simultaneous visual presentation issue accepted, because InsightKit has not yet saved its own Record video with screen plus visible person.
- Source inspection indicates the useful QuickRecorder mechanism is a visible Camera Overlayer captured into the selected screen recording. InsightKit may reproduce that product shape with project-owned code, but should not claim strict Apple Presenter Overlay when using a captured local camera overlay.

## 2026-07-02 InsightKit Saved-Output Camera Overlay Validation

Validated `/Users/yann.jy/Applications/InsightKit.app` after implementing the InsightKit-owned saved-output camera overlay path.

Evidence:
- Saved Record: `/Users/yann.jy/Documents/InsightKit/Records/20260702-1917-live-record-53301351`
- Metadata snapshot: `logs/diagnostics/2026-07-02/insightkit-saved-output-camera-overlay/record-53301351-metadata.json`
- Media probe: `logs/diagnostics/2026-07-02/insightkit-saved-output-camera-overlay/record-53301351-ffprobe.json`
- Extracted saved-video frame: `logs/diagnostics/2026-07-02/insightkit-saved-output-camera-overlay/record-53301351-frame-008s.png`

Observed:
- The saved Record contains one playable `recording.mp4`.
- Metadata reports `"mediaType": "video"` and `"presentationStatus": "screenPlusCameraCaptured"`.
- `ffprobe` reports one AAC audio stream and one H.264 video stream, both 19.890s; video is 1728x1116.
- The extracted saved-video frame visibly contains both screen content and the local camera overlay.

Classification: InsightKit saved-output camera overlay passed. This validates the accepted local-overlay mechanism, not strict Apple Presenter Overlay.
