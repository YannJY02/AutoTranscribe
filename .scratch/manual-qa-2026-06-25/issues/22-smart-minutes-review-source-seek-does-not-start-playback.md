# Smart Minutes review source seek does not start playback

Status: ready-for-agent

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
