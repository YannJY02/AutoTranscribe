# Deepen Live Session Finalization and Transcript Recovery

Status: ready-for-human

## Parent

`.scratch/live-session-finalization/PRD.md`

## What to build

Create the first implementation slice for the `Live Session Finalization` module and shared `Transcript Recovery` path.

The slice should make Live Workspace stop behavior save a complete Record when final media transcription succeeds, save a recoverable partial Record when final media transcription fails, and expose a Transcript Recovery action both in the Live Workspace result state and in Record Review.

## Product Behavior

- When the user clicks stop, capture should visibly stop immediately.
- While finalization continues, the Live Workspace should show that recording has stopped and the app is saving the Record.
- If media and notes are saved but final transcript generation fails, the user should see a recoverable state, not a lost session.
- Official transcript data must come from saved media, not live chunk timestamps.
- Transcript Recovery should regenerate the official transcript from saved media.
- Successful Transcript Recovery should preserve Time-Bound Notes and keep existing Smart Minutes visible with a warning that they may need regeneration.
- Transcript Recovery should not automatically generate final Smart Minutes.

## Acceptance Criteria

- [x] A focused Live Session Finalization module exists and is testable without constructing the full Live Workspace UI.
- [x] `LiveSessionViewModel` captures an immutable stop-time snapshot and applies a finalization outcome for Record save/final transcript behavior instead of owning those branches directly.
- [x] Review media selection and audio/video composition decisions move behind the finalization module.
- [x] Final Media Transcription retry and degradation decisions move behind the finalization module for `saveToRecords`.
- [x] Successful final media transcription replaces the runtime transcript and saves the Record with the same media-timed transcript.
- [x] If final media transcription fails but media exists, the Record is still saved with media and notes and without pretending live chunk timestamps are official transcript timestamps.
- [x] Live Workspace exposes a Transcript Recovery action when the saved Record lacks a valid official transcript.
- [x] Record Review exposes the same Transcript Recovery action when reopening a Record that lacks a valid official transcript.
- [x] Transcript Recovery regenerates transcript from saved media and writes it back to the Record.
- [x] Transcript Recovery failure preserves any existing official transcript, media, notes, and Smart Minutes.
- [x] Time-Bound Notes are preserved during finalization and recovery.
- [x] Speaker rename mappings are preserved only where they can be matched reliably.
- [x] Existing Smart Minutes are not automatically deleted after transcript recovery; the UI indicates they may need regeneration.
- [x] Focused Swift tests cover finalization success, transcription failure partial-save, recovery success, recovery failure, and note preservation.
- [x] A short installed-app retest checklist is appended before moving this issue to `ready-for-human`.

## Suggested Files

- `macos/InsightKitApp/Sources/InsightKitApp/ViewModels/LiveSessionViewModel.swift`
- `macos/InsightKitApp/Sources/InsightKitApp/ViewModels/LiveSessionViewModel+Records.swift`
- `macos/InsightKitApp/Sources/InsightKitApp/ViewModels/RecordReviewDataSource.swift`
- `macos/InsightKitApp/Sources/InsightKitApp/Models/MeetingAssetSnapshot.swift`
- `macos/InsightKitApp/Sources/InsightKitApp/Services/FinalMediaTranscriber.swift`
- `macos/InsightKitApp/Sources/InsightKitApp/Services/ReviewMediaComposer.swift`
- `macos/InsightKitApp/Sources/InsightKitApp/Services/RecordDocumentExporter.swift`
- `macos/InsightKitApp/Tests/InsightKitAppTests/LiveSessionViewModelTests.swift`
- `macos/InsightKitApp/Tests/InsightKitAppTests/RecordDocumentExporterTests.swift`
- `macos/InsightKitApp/Tests/InsightKitAppTests/RecordsIndexServiceTests.swift`

## Constraints

- Preserve ADR-0001: native SwiftUI app plus Python Sidecar.
- Preserve ADR-0002: Unix socket JSON-RPC.
- Preserve ADR-0004: Record Folder written through the Python Record Writer.
- Preserve ADR-0005: saved transcript timestamps use the final Media Timeline.
- Do not move Final Insight Generation in this slice.
- Do not make `capture_timeline.json` a normal user-facing Record dependency.
- Do not claim public Distribution Ready.

## Verification Plan

- Run focused Swift tests for the new finalization and recovery modules.
- Run relevant Live Session and Record Review adapter tests.
- Run full Swift package tests if the touched surface remains broad.
- Run focused Python tests only if the Record Save Action or Record Writer behavior changes.
- Sync to `/Users/yann.jy/Applications/InsightKit.app` before asking for owner retest if user-visible behavior changes.

## Owner Retest Checklist To Fill After Implementation

- [ ] Start a short Live Workspace recording in the installed app.
- [ ] Stop recording and confirm the app says recording stopped while saving continues.
- [ ] Confirm media and notes are saved even if final transcript generation is forced or observed to fail.
- [ ] Confirm Live Workspace shows Transcript Recovery when transcript is missing.
- [ ] Reopen the Record from Records Workspace and confirm Record Review also shows Transcript Recovery.
- [ ] Run Transcript Recovery and confirm transcript appears without losing notes.

## Blocked by

None - owner accepted the product decisions on 2026-06-28.

## Comments

### 2026-06-28 - Codex

Created from the accepted Live Session Finalization architecture discussion.

### 2026-06-29 - Codex

Implemented the core finalizer/recovery slice.

Completed:

- Added `LiveSessionFinalizer`, a focused outcome-returning module for final media transcription, runtime transcript replacement, Record Save Action, and recoverable partial-save behavior.
- Added `LiveSessionReviewMediaPreparer`, a focused module for review media selection, audio-only fallback, video/audio composition, and best-effort capture timeline sidecar writing.
- Updated `saveToRecords` to capture an immutable stop-time snapshot, use `LiveSessionFinalizer`, and avoid saving stale live chunk timestamps as official transcript when final media transcription fails.
- Updated `prepareTemporaryRecordingForSave` so `LiveSessionViewModel` delegates media preparation decisions to the finalization module and only applies the returned outcome to UI state.
- Preserved queued transcript segments during stop-drain by passing a snapshot override into save.
- Added `TranscriptRecoveryService`, shared by Live Workspace and Record Review.
- Added atomic official transcript writeback through `MeetingAssetSnapshot.writeTranscriptSegments`.
- Added Live Workspace and Record Review Transcript Recovery affordances when Meeting Asset Health says transcript recovery is possible.
- Recovery writes transcript only, preserves media/notes/Smart Minutes, and warns that existing Smart Minutes may need regeneration.
- `RecordSaveAction` now allows transcript-only degraded saves when media is missing but transcript segments exist.

Remaining owner step:

- Installed-app owner retest is still required because this flow depends on real recording permissions and real media capture.

Verification:

- `swift test --filter LiveSessionFinalizationRecoveryTests` - passed, 6 tests.
- `swift test --filter LiveSessionViewModelTests` - passed, 49 tests.
- `swift test --filter MeetingAssetSnapshotTests` - passed, 9 tests.
- `swift test --filter RecordsIndexServiceTests` - passed, 17 tests.
- `swift test --filter RecordDocumentExporterTests` - passed, 5 tests.
- `swift test --filter RuntimeActionClientsTests` - passed, 7 tests.
- `swift test` - passed, 238 tests.
- `git diff --check` - passed.
- `python3 scripts/verify_project_normalization.py` - passed; proof written to `logs/diagnostics/2026-06-29/project-normalization-20260629-093313/proof.json`.
