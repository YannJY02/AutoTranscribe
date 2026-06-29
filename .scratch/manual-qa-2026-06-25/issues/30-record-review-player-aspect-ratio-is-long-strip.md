# Record Review player aspect ratio is a long strip

Status: ready-for-human

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

During media playback, the video or audio playback area can appear as a strange long strip.

The playback surface does not feel like a mature media player with a stable, readable media frame.

## What I expected

Record Review and Smart Minutes review playback should present media in a standard, inspectable frame:

- video should preserve its natural aspect ratio without becoming an overly narrow strip;
- audio-only playback should use an intentional audio-player layout instead of a stretched video-shaped frame;
- the player should remain visually stable across audio-only, camera, screen, and composed review media.

## Steps to reproduce

1. Launch the installed InsightKit app.
2. Open a saved Record or Smart Minutes review state with playable media.
3. Play the media.
4. Observe the media player's frame and aspect ratio.
5. Notice that the playback area appears as a long strip rather than a standard media frame.

## Blocked by

None - can start immediately.

## Additional context

This issue focuses on the media player's visual presentation. It is separate from issue 29, which covers missing draggable timeline controls.

The owner expectation is that playback should align with mature software conventions for video and audio review.

## Comments

### 2026-06-26 - Manual QA

The owner reported that playback media has a strange long-strip aspect ratio.

Initial classification: `ready-for-agent`.

Why:

- The issue is a visible Record Review / Smart Minutes review media-layout problem.
- It can be diagnosed independently from playback audio quality and draggable timeline controls.

### 2026-06-26 - Diagnosing Bugs

Diagnosis:

- Review media players were stretched to the full center-column width while only capping height.
- Wide windows could therefore create a shallow, long playback surface.
- Video display did not explicitly set an aspect-preserving `videoGravity`.

Fix:

- `MediaPlayerView` now sets AVKit video gravity to `.resizeAspect`, so video content is not stretched.
- `ReviewMediaPlayerLayout` constrains video to a stable 16:9 review frame instead of filling all available width.
- Audio-only review uses a compact 96 pt audio bar instead of a stretched video-shaped frame.
- Record Review, Smart Minutes review, and Import review now share the same review-player wrapper.

Verification:

- RED loop failed before implementation because the shared layout policy did not exist.
- `swift test --package-path macos/InsightKitApp --filter MediaSeekRequestTests` passed: 15 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp` passed: 175 tests, 0 failures.
- `bash scripts/sync_insightkit_app.sh` installed build `20260626192237`.
- `codesign --verify --deep --strict --verbose=2 /Users/yann.jy/Applications/InsightKit.app` passed.

Human retest:

- Run installed build `20260626192237`.
- Open a saved Record and a Smart Minutes review state with playable media.
- Confirm video appears in a stable, inspectable frame rather than a long strip.
- Confirm audio-only playback appears as an intentional compact audio player, not a stretched video frame.

### 2026-06-26 - Partial owner retest

The owner confirmed video playback now uses a normal frame, but audio-only playback still appears with a strange aspect/frame.

Status changed back to `ready-for-agent` for the residual audio-only player layout problem. The next fix should keep the video framing behavior intact and focus on audio-only Record Review / Smart Minutes review playback.

### 2026-06-27 - Residual audio-only frame fix installed

Diagnosis:

- The first fix correctly stabilized video at a standard aspect-preserving frame, but audio-only review still used a shallow 760 x 96 player bar that could read as another long strip.
- Record Review also only inferred review-player layout from the media file extension. The residual fix now lets Record Review pass canonical Record metadata into the review player so audio records always use the audio layout, even if a container extension would otherwise look video-like.

Fix:

- `ReviewMediaPlayerLayout` now uses a more intentional 520 x 128 audio panel while keeping the existing 16:9 video frame behavior.
- `ReviewMediaKind` maps Record metadata (`audio` / `video`) into the shared review-player wrapper.
- Record Review now passes `ReviewMediaKind(recordMediaType:)` when rendering saved Record media.

Verification:

- RED loop failed before implementation because `ReviewMediaKind` and the metadata-driven audio layout override did not exist.
- Focused GREEN passed: `swift test --package-path macos/InsightKitApp --filter MediaSeekRequestTests/testReviewMediaPlayerLayoutUsesCompactAudioPanel --filter MediaSeekRequestTests/testReviewMediaPlayerLayoutCanUseRecordMetadataForAudioContainer --filter MediaSeekRequestTests/testReviewMediaKindMapsRecordMediaType`.
- Related gate passed: `swift test --package-path macos/InsightKitApp --filter MediaSeekRequestTests` -> 17 tests, 0 failures.
- Full Swift gate passed: `swift test --package-path macos/InsightKitApp` -> 185 tests, 0 failures.
- Standard sync first reached Python unittest and was blocked by the local Homebrew Python environment missing `pytest`, `faster-whisper`, and `silero-vad`; this is recorded as an environment gate issue, not an issue 30 code failure.
- Installed sync succeeded with the already-passed Swift gate using `scripts/sync_insightkit_app.sh --install-dir /Users/yann.jy/Applications --skip-tests`.
- Installed build: `20260627001232`; proof: `logs/workflow/latest_sync.json`.

Human retest:

- Run installed build `20260627001232`.
- Open an audio-only saved Record from Records Workspace.
- Confirm the playback surface appears as an intentional compact audio player, not a long strip.
- Also spot-check a video saved Record to confirm the prior normal video frame remains intact.

### 2026-06-27 - Owner retest passed

The owner confirmed issue 30 is resolved after the residual audio-only player-frame fix. The Record Review playback surface no longer appears as a long strip for the checked cases.
