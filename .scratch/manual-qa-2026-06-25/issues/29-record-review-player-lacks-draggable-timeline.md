# Record Review player lacks a draggable media timeline

Status: ready-for-human

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

Record Review media playback does not provide a clear draggable progress bar or scrubber.

The owner can play media, but cannot easily drag the playback position like in mature media software.

## What I expected

Record Review should provide standard media controls for reviewing meeting assets:

- visible playback progress;
- draggable timeline / scrubber;
- current time and duration where appropriate;
- predictable behavior when the user drags to a different media time.

## Steps to reproduce

1. Launch the installed InsightKit app.
2. Open a saved Record in Record Review.
3. Play the audio or video media.
4. Try to drag the playback progress to another point in the media.
5. Observe that the player does not provide a usable draggable timeline.

## Blocked by

None - can start immediately.

## Additional context

This issue focuses on the user control surface for media seeking. It is separate from issue 22, which covered whether clicking Timeline Beats or Transcript Segments seeks and starts playback.

The owner expectation is that playback controls should feel closer to mature media software.

## Comments

### 2026-06-26 - Manual QA

The owner reported that playback lacks a draggable progress bar.

Initial classification: `ready-for-agent`.

Why:

- The expected behavior is a standard Record Review media-control affordance.
- It can be implemented and verified independently from transcript-generated seek shortcuts.

### 2026-06-26 - Diagnosing Bugs

Diagnosis:

- Record Review, Smart Minutes review, and Import review used `MediaPlayerView` directly with per-screen height caps.
- Audio files used `.minimal` AVKit controls, which does not present a mature draggable media timeline.
- The playback surface therefore lacked a standard scrubber especially in audio-only review.

Fix:

- `MediaPlayerView` now uses AVKit `.default` controls for both audio and video review media.
- Review entry points now use `ReviewMediaPlayerView`, a shared wrapper for Record Review, Smart Minutes review, and Import review.
- The wrapper keeps playback user-controlled while exposing the standard AVKit control surface.

Verification:

- RED loop failed before implementation because `ReviewMediaPlayerLayout` and `videoGravity` did not exist and audio still expected `.minimal`.
- `swift test --package-path macos/InsightKitApp --filter MediaSeekRequestTests` passed: 15 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp` passed: 175 tests, 0 failures.
- `bash scripts/sync_insightkit_app.sh` installed build `20260626192237`.
- `codesign --verify --deep --strict --verbose=2 /Users/yann.jy/Applications/InsightKit.app` passed.

Human retest:

- Run installed build `20260626192237`.
- Open a saved Record with audio or video media.
- Confirm the player exposes a visible media timeline / scrubber.
- Drag the timeline to another point.
- Expected result: playback seeks predictably and continues under normal user control.

### 2026-06-26 - Owner retest passed

The owner confirmed the Record Review player now provides the expected draggable timeline behavior.
