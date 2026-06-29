# Record Review playback auto-pauses after opening a record

Status: ready-for-human

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

After opening a saved Record from the Records Workspace / 转写记录, the Record Review media player cannot play normally. Playback starts and then automatically pauses, so the user cannot review the source media continuously.

## What I expected

When a Record is opened from the Records Workspace, Record Review should play the saved meeting media normally.

The player should only pause when the user pauses it, reaches the end, or a clear media-unavailable state is shown.

## Steps to reproduce

1. Launch the installed InsightKit app.
2. Open the Records Workspace / 转写记录.
3. Open a saved Record that has playable review media.
4. In Record Review, press play on the media player.
5. Observe that playback cannot continue normally and automatically pauses.

## Additional context

Reported during owner-led QA after testing installed build `20260625214038`.

This is separate from issue 24. Issue 24 covers Smart Minutes review-source audio/video synchronization after a Live Workspace session. This issue covers Record Review playback after reopening a saved Record from the Records Workspace.

It may share the same media-player surface, but the user-visible entry point and acceptance check are different.

## Comments

### 2026-06-25 - Manual QA

Reported during owner-led QA.

Initial classification: `ready-for-agent`.

Why:

- The steps, actual behavior, and expected behavior are clear enough to diagnose.
- It is independently verifiable from Smart Minutes live review because it starts from a saved Record in the Records Workspace.
- No owner decision is needed before a diagnosing-bugs loop.

### 2026-06-26 - Diagnosing Bugs

Diagnosis:

- Record Review passed `isPlaying: false` into `MediaPlayerView`.
- `MediaPlayerView` interpreted `false` as an instruction to pause the underlying `AVPlayer`.
- After the user pressed play, the player emitted playback-time updates; those updates refreshed SwiftUI state, and the next view update applied `pause()` again.
- That made playback look like it started and then immediately auto-paused.

Fix:

- `MediaPlayerView` now distinguishes three playback intents:
  - `nil` means user-controlled playback;
  - `true` means host-controlled play;
  - `false` means host-controlled pause.
- Record Review no longer passes `false`, so normal user playback is not interrupted by view refreshes.
- Import processing playback and Smart Minutes review-source playback also avoid forced pause when no auto-play request exists.

Verification:

- `swift test --package-path macos/InsightKitApp --filter MediaSeekRequestTests` passed: 12 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp` passed: 172 tests, 0 failures.
- `bash scripts/sync_insightkit_app.sh` installed build `20260626190326`.
- `codesign --verify --deep --strict --verbose=2 /Users/yann.jy/Applications/InsightKit.app` passed.

Human retest:

- Run installed build `20260626190326`.
- Open Records Workspace / 转写记录.
- Open a saved Record with playable media.
- Press play in Record Review.
- Expected result: media continues playing until the user pauses it, seeks, reaches the end, or the app shows a clear media-unavailable state.

### 2026-06-26 - Owner retest passed

The owner confirmed Record Review playback no longer auto-pauses after opening a saved Record.
