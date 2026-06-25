# Smart Minutes review source seek does not start playback

Status: ready-for-human

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

In the Smart Minutes review experience, clicking a Timeline Beat or Transcript Segment does not jump to the corresponding source position and immediately start playback.

The user expects a click on a chapter or transcript row to move the review source to that moment and play from there, but playback does not begin as expected.

## What I expected

Timeline Beats and Transcript Segments should act as review shortcuts.

When the user clicks one, InsightKit should seek the review source to that timestamp and start playback so the user can immediately verify the selected Evidence Span against the original source.

## Steps to reproduce

1. Launch the installed InsightKit app.
2. Open the Live Workspace.
3. Capture a session and generate Smart Minutes.
4. In the Smart Minutes review experience, click a Timeline Beat in Smart Minutes.
5. Observe that playback does not jump and start at the selected moment.
6. Click a Transcript Segment in `回看资料`.
7. Observe that playback still does not jump and start at the selected moment.

## Additional context

Reported during owner-led QA after build `20260625192450`.

This is separate from whether the review source is video or audio-only. The interaction should work for any playable review source.

## Comments

### 2026-06-25 - Manual QA

The owner reported that clicking chapters or transcript rows does not seek to the matching review-source position and start playback.

### 2026-06-25 - Implemented

Diagnosis:

- `LiveSessionViewModel` already created a `MediaSeekRequest` for Timeline Beat and Transcript Segment clicks.
- The Smart Minutes review source still received `isPlaying: false`, so a click could seek without starting playback.

Fix:

- Added a Live review-source playback request state.
- Timeline Beat and Transcript Segment clicks now set that state when they seek.
- The Smart Minutes `回看资料` media player now receives the playback request.
- Issue 23 later removed the separate supplemental audio-player path so the request targets one standard review media player.

Proof:

- RED-capable regression loop: `swift test --package-path macos/InsightKitApp --filter MediaSeekRequestTests/testLiveReviewTranscriptTapRequestsPlayback --filter MediaSeekRequestTests/testLiveReviewChapterTapRequestsPlayback`
- GREEN: same loop passed with 2 tests, 0 failures.
- Related gate: `swift test --package-path macos/InsightKitApp --filter MediaSeekRequestTests`, 9 tests, 0 failures.
- Broad gate: `swift test --package-path macos/InsightKitApp`, 158 tests, 0 failures.
- Installed app sync passed for `/Users/yann.jy/Applications/InsightKit.app`; proof is recorded in `logs/workflow/latest_sync.json`.

Acceptance for owner retest:

- Generate or open a Smart Minutes review with review source media.
- Confirm together with issue 23 that `回看资料` uses one media player rather than separate audio/video controls.
- Click a Timeline Beat.
- Confirm `回看资料` jumps to the selected timestamp and starts playback.
- Click a Transcript Segment.
- Confirm `回看资料` jumps to the selected timestamp and starts playback.
