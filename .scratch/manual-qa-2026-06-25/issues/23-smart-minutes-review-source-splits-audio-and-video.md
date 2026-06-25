# Smart Minutes review source splits audio and video

Status: ready-for-human

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

After the follow-up fixes for Smart Minutes review-source audio, video, and click-to-play behavior, the review source still treated video and audio as separate playback surfaces.

The owner clarified that this is not the desired macOS behavior. Audio and video should not be split into separate controls.

## What I expected

When a Live Workspace session captures video and audio, InsightKit should prepare one playable review media asset.

In the Smart Minutes review experience, `回看资料` should use one standard macOS media player for that asset, so the user can play, pause, seek, and verify Timeline Beats / Transcript Segments from one control.

## Steps to reproduce

1. Launch the installed InsightKit app.
2. Open the Live Workspace.
3. Capture a session with camera or screen enabled and microphone or mixed audio enabled.
4. Stop the session and generate Smart Minutes.
5. In Smart Minutes review, inspect `回看资料`.
6. Observe that audio and video can appear as separate playback surfaces instead of one standard media player.

## Additional context

Reported after issue 22 was installed and tested.

This is the follow-up correction to issues 20, 21, and 22. Those fixes restored audibility, video visibility, and click-to-play behavior, but the final model still needed to stop splitting one source meeting asset into separate audio and video players.

## Comments

### 2026-06-25 - Implemented

Diagnosis:

- `LiveReviewSourcePresentation` explicitly exposed `supplementalAudioURL`, which let the Smart Minutes review UI render a second compact audio player.
- `prepareTemporaryRecordingForSave` preserved captured video as the main media while preparing a separate WAV review source from audio chunks.
- That model fixed sound and video separately, but it was not the standard macOS media-player model for one source recording.

Fix:

- Removed the supplemental Smart Minutes review-source audio player path.
- Added an AVFoundation review-media composer that combines the captured video track and captured audio track into one `.mp4` review media file.
- When both video and audio exist, Live Session save/review state now points `temporaryRecordingURL`, `mediaURL`, and `reviewSourceMediaURL` to the same composed video file.
- If audio is missing or composition fails, InsightKit keeps a single video player and shows a clear status instead of splitting playback.

Proof:

- RED-capable loop before the fix: `swift test --package-path macos/InsightKitApp --filter LiveReviewSourcePresentationTests/testVideoReviewSourceUsesSingleStandardPlayerEvenWhenLegacySeparateAudioExists`
  - It failed because `showsSupplementalAudio` was true and `supplementalAudioURL` was `recording.wav`.
- GREEN: `swift test --package-path macos/InsightKitApp --filter LiveReviewSourcePresentationTests/testVideoReviewSourceUsesSingleStandardPlayerEvenWhenLegacySeparateAudioExists --filter LiveSessionViewModelTests/testPrepareTemporaryRecordingComposesSinglePlayableVideoWhenVideoAndAudioAreCaptured`, 2 tests, 0 failures.
- Related gate: `swift test --package-path macos/InsightKitApp --filter LiveReviewSourcePresentationTests --filter LiveSessionViewModelTests/testPrepareTemporaryRecording --filter MediaSeekRequestTests`, 17 tests, 0 failures.
- Broad gate: `swift test --package-path macos/InsightKitApp`, 158 tests, 0 failures.

Acceptance for owner retest:

- Capture a Live Workspace session with camera or screen plus microphone or mixed audio.
- Generate Smart Minutes.
- In Smart Minutes `回看资料`, confirm there is one standard media player, not a separate video player plus an audio player.
- Confirm the single player shows the video and plays audible sound.
- Click a Timeline Beat and a Transcript Segment; confirm the same player seeks and starts playback.
