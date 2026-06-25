# Smart Minutes review source playback has no audio

Status: ready-for-human

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

In the Smart Minutes review experience, the owner cannot hear audio from the review source material.

The review source area may show replay material, but playback does not produce audible sound.

## What I expected

When Smart Minutes include review source material, the user should be able to play back the original meeting media with sound.

Playback from the Smart Minutes review experience should make it possible to verify Transcript Segments, Timeline Beats, and Evidence Spans against the original audio.

## Steps to reproduce

1. Launch the installed InsightKit app.
2. Open the Live Workspace.
3. Capture a session with microphone or mixed audio.
4. Generate Smart Minutes.
5. In the Smart Minutes review experience, use the review source playback area.
6. Observe that the review source material cannot be heard.

## Additional context

Reported after owner retest of installed build `20260625165436`.

This is separate from issue 08, which covered whether review media visually appears. This issue covers audible playback from the Smart Minutes review source area.

## Comments

### 2026-06-25 - Manual QA

The owner reported that Smart Minutes review source material currently cannot be heard during playback.

### 2026-06-25 - Batch triage

Classification: `ready-for-agent`.

Why:

- The issue has a concrete user-visible failure: the Smart Minutes review source can be shown, but playback is not audible.
- It is separate from issue 08, which already covered whether review media visually appears.

Dependency:

- May share MediaPlayer or saved-media paths with earlier media work, but it has a separate acceptance check: the user must hear audio.
- Independent from Smart Minutes export in issue 17.

Implementation boundary:

- Ensure the review source media player can audibly play the saved meeting media from the Smart Minutes review experience.
- If no playable audio exists, show an explicit audio-unavailable state instead of a silent player.
- Do not change transcript or Smart Minutes generation behavior in this issue.

Suggested verification:

- Add a MediaPlayer or review-source presentation test proving audio-capable media is surfaced as playable.
- Owner retest should confirm that review source playback in Smart Minutes produces sound for a normal microphone or mixed-audio session.

### 2026-06-25 - Code fix installed for owner retest

Status changed to `ready-for-human`.

Implementation summary:

- Added a separate Smart Minutes review-source media URL instead of reusing the visual review `mediaURL`.
- Kept captured video as the normal review media while generating a WAV audio source from captured audio chunks for the Smart Minutes review source.
- Changed the Smart Minutes `回看资料` section to play the review-source URL, so a video-only MP4 no longer appears as a silent player.
- Added an explicit audio-unavailable status when video exists but no playable audio was captured.

TDD proof:

- RED: `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testPrepareTemporaryRecordingKeepsAudibleReviewSourceWhenVideoHasNoAudioTrack` failed because `LiveSessionViewModel` did not expose a review-source media URL or status.
- GREEN: the same test passed after adding `reviewSourceMediaURL`, `reviewSourceStatusMessage`, and review-source audio preparation.
- GREEN: `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testPrepareTemporaryRecording` passed, 7 tests, 0 failures.
- GREEN: `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests` passed, 37 tests, 0 failures. One immediately previous run hit a non-reproduced `signal 11`, then the same suite passed on rerun.
- GREEN: `swift test --package-path macos/InsightKitApp` passed, 155 tests, 0 failures.

Installed-app proof:

- Installed build: `20260625192450`
- Sync proof: `logs/workflow/latest_sync.json`
- Command: `scripts/sync_insightkit_app.sh --debug --skip-tests`
- Installed smoke: launched `/Users/yann.jy/Applications/InsightKit.app` in UI-test Live route and quit successfully.

Owner retest:

- Capture a Live Workspace session with microphone or mixed audio and camera or screen enabled.
- Generate Smart Minutes.
- In the Smart Minutes review experience, play `回看资料` and confirm audio is audible.
- If no audio input was captured, confirm the app shows a clear no-playable-audio message instead of a silent player.
