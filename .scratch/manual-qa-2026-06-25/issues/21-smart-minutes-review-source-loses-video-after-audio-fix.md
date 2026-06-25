# Smart Minutes review source loses video after audio fix

Status: ready-for-agent

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
