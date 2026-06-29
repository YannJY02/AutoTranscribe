# Live transcription failure can leave session unsaved and still recording

Status: ready-for-agent

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

The owner reported that transcription failed again in installed build `20260627161028`.

After the failure and crash, there was no new saved Record visible from the latest QA attempt, and the latest Live Workspace state appeared to remain active instead of being finalized into a recoverable post-session record.

## What I expected

When Live Workspace transcription fails, InsightKit should preserve the meeting state in a recoverable way.

The owner should either get a saved Record with the available transcript/media artifacts or a clear recoverable failure state that can retry final transcription, rather than losing the session behind a crash or stale recording state.

## Steps to reproduce

1. Launch installed InsightKit build `20260627161028`.
2. Use the current local ASR configuration with Qwen3-ASR MLX and Diarization enabled.
3. Start a Live Workspace session with mixed audio.
4. Let transcription run, then stop or wait until the transcription failure appears.
5. Observe that transcription fails and the latest session may not appear as a saved Record after recovery.

## Blocked by

None - can start immediately.

## Additional context

The latest QA configuration had Qwen3-ASR MLX selected, Diarization enabled, and the Apple Speech experimental audio final-media prototype toggle enabled. The crash in issue 43 can mask or interrupt this failure path, but the missing recoverable transcription result is a separate user-visible problem.
