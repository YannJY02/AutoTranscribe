# Live Session Finalization and Transcript Recovery PRD

Status: ready-for-human

## Problem Statement

Live Workspace stop behavior now carries too much product risk in one broad ViewModel path. When the user stops recording, InsightKit must preserve captured media and notes, produce a trustworthy media-timed transcript when possible, save a recoverable Record, and avoid making the session look lost or still recording.

This lane deepens Live Session Finalization into a focused module and adds Transcript Recovery so a failed final transcript can be regenerated from saved media later.

## Goal

After the user stops a Live Workspace session, InsightKit should either save a complete Record or save a clearly recoverable partial Record. A saved Record must not treat live chunk timestamps as the official transcript when final media transcription failed.

## User Stories

1. As a user, I want stopping a recording to clearly stop capture immediately, so I know the app is no longer recording.
2. As a user, I want the app to keep saving in the background after stop, so my media and notes are not lost while the record is being finalized.
3. As a user, I want media and notes saved even when final transcription fails, so the meeting is recoverable.
4. As a user, I want a clear Transcript Recovery action when the transcript is missing or stale, so I can regenerate it from the saved media.
5. As a user, I want the recovery action available both right after stopping and later in Record Review, so I can recover after leaving the Live Workspace.
6. As a user, I want my Time-Bound Notes preserved during transcript recovery, so my own work is never lost.
7. As a user, I want speaker-name edits preserved when they can be matched reliably, so recovery does not undo obvious corrections.
8. As a future agent, I want Live Session Finalization behind a focused module interface, so media selection, final transcript generation, record save, and degradation behavior can be tested without constructing the whole Live Workspace.
9. As a future agent, I want Transcript Recovery behind one shared module, so Live Workspace and Record Review do not implement separate recovery logic.
10. As a future agent, I want saved transcripts to respect the final Media Timeline, so ADR-0005 remains protected.

## Accepted Product Decisions

1. First scope only covers Live Workspace stop and post-stop finalization, not Import Workspace.
2. The new finalization module returns a result outcome; it does not directly mutate UI state.
3. The finalization module owns review media selection and audio/video composition decisions.
4. The finalization module owns Final Media Transcription retry and failure degradation.
5. The finalization module calls Record Save Action through a small adapter.
6. The finalization module reads an immutable stop-time snapshot, not live mutable ViewModel properties.
7. The finalization module replaces the runtime transcript after successful final media transcription through a small adapter.
8. `capture_timeline.json` remains diagnostics-only and should not become core Record schema.
9. Final Insight Generation is not moved in this first slice.
10. Failure handling should preserve captured content whenever possible.
11. If final media transcription fails but media exists, still save the Record.
12. Do not store live chunk transcript as the official transcript when final media transcription fails.
13. User-facing failure messages should emphasize the user's next action; technical detail belongs in logs or diagnostics.
14. After stop/save, stay in the Live Workspace review/result state rather than auto-navigating away.
15. After stop, immediately show that recording stopped while saving/finalization continues.
16. First slice includes a minimal Transcript Recovery button.
17. Transcript Recovery appears in both the Live Workspace result state and reopened Record Review.
18. Transcript Recovery regenerates transcript only; it does not automatically generate Smart Minutes.
19. Transcript Recovery may overwrite the official transcript only when the new transcript comes from saved media. Failed recovery must preserve any old official transcript.
20. Existing Smart Minutes are not automatically deleted after transcript recovery; show that they may need regeneration.
21. Time-Bound Notes must be preserved. Speaker rename should be preserved only where labels can be matched reliably.
22. Live Workspace and Record Review share the same Transcript Recovery module.
23. First implementation success means "stops save reliably and failed transcript is recoverable", not "all Smart Minutes work is automatic".
24. Proof requires automatic tests and installed-app validation.
25. Installed-app validation is two-layered: agent-run logic tests first, owner retest in `/Users/yann.jy/Applications/InsightKit.app` afterward.
26. This lane is recorded in `.scratch/live-session-finalization/` before implementation.

## Implementation Decisions

- Create a `Live Session Finalization` module seam for stop-drain, review media selection, Final Media Transcription, runtime transcript replacement, Record Save Action, and result outcome creation.
- Keep `LiveSessionViewModel` as the app-facing adapter that captures a stop-time snapshot, invokes finalization, and applies the outcome to `Capture State`, `Session Phase`, status messages, media URLs, and recovery presentation.
- Create or deepen a shared `Transcript Recovery` module seam that can be invoked from Live Workspace and Record Review.
- Keep small adapters for record saving, runtime transcript replacement, final media transcription, media composition, media inspection, and Record file writes. Do not depend on the full `InsightRPCClientProtocol` interface in the new module.
- Preserve ADR-0001, ADR-0002, ADR-0004, and ADR-0005.

## Out of Scope

- Replacing the native SwiftUI app or Python sidecar.
- Replacing Unix socket JSON-RPC.
- Reworking Import Workspace finalization.
- Automatically generating final Smart Minutes after Transcript Recovery.
- Treating diagnostics sidecars as core Record Folder schema.
- Public distribution readiness, signing, notarization, App Store, or privacy work.

## Testing Decisions

- Add focused Swift tests for the finalization module using constructed snapshots and fake adapters.
- Add focused Swift tests for Transcript Recovery from a saved Record.
- Keep Live Session adapter tests for applying finalization outcomes to user-visible state.
- Keep Record Review tests for showing and invoking Transcript Recovery when transcript is missing or stale.
- Use installed-app owner retest after implementation, because recording permissions, real media, and review behavior are user-visible.

## Published Issues

- `.scratch/live-session-finalization/issues/01-deepen-live-session-finalization-and-transcript-recovery.md`

## Comments

### 2026-06-28 - Codex

Published after owner accepted the architecture-review top recommendation and all product decisions above.

### 2026-06-29 - Codex

Implemented issue `01-deepen-live-session-finalization-and-transcript-recovery` and moved it to `ready-for-human`.

- `LiveSessionFinalizer` now owns final media transcription retry/degradation, runtime transcript replacement, Record Save Action, and partial-save outcome creation for `saveToRecords`.
- `LiveSessionReviewMediaPreparer` now owns review media selection, audio-only fallback, video/audio composition, and capture timeline sidecar writing.
- `TranscriptRecoveryService` is shared by Live Workspace and Record Review.
- Meeting Asset Health drives transcript recovery visibility.
- The remaining work is owner retest in the installed app because real recording permissions and real captured media are part of the acceptance surface.

The accepted implementation order can now continue to the ASR Runtime Profile slice.
