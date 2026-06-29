# Use final media timeline for saved transcript timestamps

Status: accepted

## Context

Live transcription can produce useful draft text while a session is running, but its chunk timestamps come from the app's live audio processing path. That processing path can warm up, buffer, flush, or finalize at different times than the final `recording.*` media file.

## Decision

Saved records must treat the final media file as the canonical timeline for transcript timestamps. Live Transcript Deltas remain useful as draft feedback during capture, but `transcript.json`, Smart Minutes evidence, Timeline Beats, Time-Bound Notes, and Media Seek links should use timestamps derived from the final audio/video media timeline.

## Consequences

- Live Workspace finalization should re-transcribe or align against the completed media before writing a Record Folder.
- Import Workspace already follows the same shape because it transcribes the selected media file.
- Tests should distinguish live draft timing from media-timed record output.
- If final media transcription fails or returns no speech, the app should not silently present live chunk timestamps as if they were media timestamps.
