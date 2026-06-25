# Smart Minutes review source loses video after audio fix

Status: ready-for-human

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

After the Smart Minutes review-source audio fix, the `回看资料` area no longer shows the captured video during review.

The user can no longer visually verify the original camera or screen material from the Smart Minutes review experience.

## What I expected

Smart Minutes review should preserve the captured video while also making the source audio audible.

If a session captured camera or screen video, the review source should still show that video. Audio playback should be added without replacing the visual source with an audio-only player.

## Steps to reproduce

1. Launch the installed InsightKit app.
2. Open the Live Workspace.
3. Capture a session with camera or screen enabled and microphone or mixed audio enabled.
4. Stop the session and generate Smart Minutes.
5. In the Smart Minutes review experience, inspect `回看资料`.
6. Observe that the captured video is no longer visible.

## Additional context

Reported during owner-led QA after build `20260625192450`, which installed the issue 20 Smart Minutes review-source audio fix.

This is a regression from the earlier media-chain fix where review video display had passed owner retest. It should be handled separately from audio audibility: the desired review source is visual and audible, not audio-only.

## Comments

### 2026-06-25 - Manual QA

The owner reported that the issue 20 fix introduced a new regression: `回看资料` no longer displays video.

### 2026-06-25 - Code fix installed for owner retest

Status changed to `ready-for-human`.

Diagnosis:

- The save path still preserved captured video as the main meeting media.
- The Smart Minutes `回看资料` view incorrectly used the audio fallback URL as the only media player URL.
- When issue 20 generated a WAV review-source audio file, that audio URL replaced the visible video in the review source area.

Implementation summary:

- Added a Smart Minutes review-source presentation decision that kept captured video visible instead of replacing it with audio-only media.
- This was later superseded by issue 23, which removes the separate audio-player model and composes audio/video into one standard review media file.

TDD proof:

- RED: `swift test --package-path macos/InsightKitApp --filter LiveReviewSourcePresentationTests/testVideoRemainsPrimaryReviewSourceWhenSeparateAudioFallbackExists` failed because the presentation selected `recording.wav` as the primary review media and had no supplemental audio URL.
- GREEN: the same test passed after separating primary video media from supplemental audio.
- GREEN: `swift test --package-path macos/InsightKitApp --filter LiveReviewSourcePresentationTests` passed, 1 test, 0 failures.
- GREEN: `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testPrepareTemporaryRecordingKeepsAudibleReviewSourceWhenVideoHasNoAudioTrack` passed, 1 test, 0 failures.
- GREEN: `swift test --package-path macos/InsightKitApp` passed, 156 tests, 0 failures.

Installed-app proof:

- Installed build: `20260625203632`
- Sync proof: `logs/workflow/latest_sync.json`
- Command: `scripts/sync_insightkit_app.sh --debug --skip-tests`
- Installed smoke: launched `/Users/yann.jy/Applications/InsightKit.app` with `--ui-test-mode --ui-test-route=live` and quit successfully.

Owner retest:

- Capture a Live Workspace session with camera or screen enabled and microphone or mixed audio enabled.
- Stop the session and generate Smart Minutes.
- In Smart Minutes `回看资料`, confirm the captured video is visible.
- Confirm together with issue 23 that audio/video are no longer split into separate playback surfaces.
- Note: issue 22 still tracks click-to-seek-and-play behavior for Timeline Beats and Transcript Segments.
