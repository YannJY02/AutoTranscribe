# Smart Minutes review source playback has no audio

Status: ready-for-agent

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
