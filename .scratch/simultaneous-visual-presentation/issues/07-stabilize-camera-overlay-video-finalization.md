# Stabilize camera overlay video finalization

Status: ready-for-human

## Agent Brief

**Category:** bug

**Summary:** Camera-plus-screen Records can fall back to audio because the temporary MP4 is not finalized into a playable video.

**Current behavior:**
After the accepted saved-output camera overlay path, a real installed-app run saved a Record whose Review playback had no video. The saved Record only contained `recording.wav`; `metadata.json` reported `mediaType: audio` and `presentationStatus: visualMediaUnavailable`. The temp folder still had a non-empty `recording.mp4`, but `ffprobe` reported `moov atom not found`, so the file was not playable.

**Desired behavior:**
When the user records with camera and screen enabled, the video writer should finalize a playable MP4 whenever screen frames were captured. Record Review should receive one playable video media surface for successful camera-overlay runs. If a video file is invalid, InsightKit may still fall back to audio, but it must not treat a non-empty broken MP4 as valid video proof.

**Key interfaces:**
- `VideoCaptureService` video writer setup and finish path should use the actual captured screen-frame dimensions when possible.
- `LiveSessionReviewMediaPreparer` should accept a video file only when media inspection can read a positive duration.
- `LivePresentationCaptureStatus` should continue to downgrade to `visualMediaUnavailable` when no playable video reaches the saved Record.

**Acceptance criteria:**
- [x] Camera-plus-screen recording produces a saved Record with a playable `recording.mp4` when screen frames are captured.
- [x] The saved Record metadata reports `mediaType: video` and `presentationStatus: screenPlusCameraCaptured` for successful camera-overlay video.
- [x] A non-empty but unplayable temp MP4 does not get passed to Record Review as a video.
- [x] Automated tests cover using first-frame video dimensions for writer setup.
- [x] Automated tests cover rejecting invalid non-empty MP4 files during review-media preparation.
- [x] Installed-app validation records whether the latest saved Record has a playable MP4 or correctly falls back to audio with `visualMediaUnavailable`.

**Out of scope:**
- Reopening strict Apple Presenter Overlay as the implementation mechanism.
- Adding a layout editor or custom compositor.
- Changing the accepted local camera overlay wording.

## Comments

### 2026-07-02 - Codex triage

Verified the owner-reported symptom against local artifacts:
- Latest suspicious saved Record: `/Users/yann.jy/Documents/InsightKit/Records/20260702-2045-live-record-92b51212`.
- Saved Record contains `recording.wav` but no saved `recording.mp4`.
- Metadata reports `"mediaType": "audio"` and `"presentationStatus": "visualMediaUnavailable"`.
- Temp folder still contains `/private/var/folders/qj/rpkv85p52_j3qx851dzbcvsr0000gn/T/InsightKit/live-067DDAA1-6B14-4E4E-8792-596F92B51212/recording.mp4`.
- `file` identifies that temp file as MP4 container bytes, but `ffprobe` reports `moov atom not found`.

Classification: confirmed bug in the saved-output camera overlay finalization path. Record Review is exposing the failure because there is no playable saved video.

### 2026-07-02 - Implementation and validation

Fixed the video finalization path by deferring the MP4 writer until the first captured screen frame, deriving writer dimensions from that real frame, and appending frames through `AVAssetWriterInputPixelBufferAdaptor`. The review-media finalizer now also rejects non-empty MP4 files unless `AVFoundation` can read a duration, so a broken temp file is not promoted to Record Review as video proof.

Installed-app validation used `/Users/yann.jy/Applications/InsightKit.app` synced from the local workspace. A real camera-plus-screen Live Workspace run produced:
- Saved Record: `/Users/yann.jy/Documents/InsightKit/Records/20260702-2109-live-record-74ee0db8`.
- Metadata: `"mediaType": "video"` and `"presentationStatus": "screenPlusCameraCaptured"`.
- `recording.mp4`: playable 10.000s media with one AAC audio stream and one H.264 video stream at 1728x1116.
- Extracted frame: `logs/diagnostics/2026-07-02/camera-overlay-video-finalization/20260702-2109-live-record-74ee0db8-frame-005s.png`, visibly showing screen content plus the camera overlay.
- Record Review screenshot: `logs/diagnostics/2026-07-02/camera-overlay-video-finalization/20260702-2109-live-record-74ee0db8-review-playback.png`, showing the saved video displayed in app playback.
- Metadata snapshot: `logs/diagnostics/2026-07-02/camera-overlay-video-finalization/20260702-2109-live-record-74ee0db8-metadata.json`.
- Media probe: `logs/diagnostics/2026-07-02/camera-overlay-video-finalization/20260702-2109-live-record-74ee0db8-ffprobe.json`.

Automated verification:
- `swift test --package-path macos/InsightKitApp --jobs 1 --filter LiveSessionViewModelTests/testPrepareTemporaryRecordingRejectsUnplayableNonEmptyVideoRecording --filter VideoRecordingTimelineTests/testRecordingDimensionsPreferFirstSampleBufferPixelSize --filter CameraOverlayPlacementTests`.
