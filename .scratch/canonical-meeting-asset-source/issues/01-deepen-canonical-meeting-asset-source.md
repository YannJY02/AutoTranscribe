# Deepen Canonical Meeting Asset Source

Status: ready-for-human

## Parent

`.scratch/canonical-meeting-asset-source/PRD.md`

## What to build

Create the first implementation slice for the Canonical Meeting Asset Source.

The slice should make Record Review, export, and user-visible Record edits agree on one official Record Folder interpretation. It should introduce a meeting-asset read entrypoint that returns content plus health, and a write entrypoint for user-visible changes that preserve old official files when writes fail.

## Product Behavior

- A saved Record's Record Folder is the only official meeting-asset source.
- Record Review opens complete Records normally.
- Record Review opens partial or damaged Records in a clear degraded state instead of crashing or silently substituting temporary data.
- Exported Markdown/PDF matches the same transcript, Smart Minutes, notes, and media state shown in Record Review.
- Speaker rename and Time-Bound Notes update the official Record Folder files.
- `insight_package.json` is the official Smart Minutes source for new logic.
- `minutes.json` remains readable only as a legacy or degraded fallback.
- Record Index and search data can speed up listing and lookup, but clicked Records reload official content from the Record Folder.

## Acceptance Criteria

- [x] A focused meeting-asset read module exists and can load a Record Folder without constructing Record Review UI.
- [x] The read module returns loaded content and Meeting Asset Health for media, transcript, Smart Minutes, notes, metadata, fallback use, and damaged files.
- [x] Record Review consumes the read module instead of owning independent official-file rules.
- [x] `RecordDocumentExporter` consumes the same meeting asset content used by Record Review instead of separately reading transcript or summary content.
- [x] `insight_package.json` is treated as the official Smart Minutes source.
- [x] `minutes.json` remains a fallback for old Records and is surfaced as fallback health, not as the normal official source.
- [x] Speaker rename writes through the canonical write path and updates official `transcript.json`.
- [x] Time-Bound Notes save through the canonical write path and update official `notes.md`.
- [x] User-visible writes preserve the previous official file when the new write fails before a complete replacement is available.
- [x] Missing transcript with available media produces health that can drive Transcript Recovery.
- [x] Missing Smart Minutes produces health that can drive Smart Minutes generation.
- [x] Missing media still allows transcript, notes, and Smart Minutes review with a clear media-degraded state.
- [x] Record Index and search code are not made authoritative for Record Review content.
- [x] No `asset_manifest.json` or new Record Folder schema is introduced in this slice.
- [x] Focused Swift tests cover complete Record load, legacy `minutes.json` fallback, missing transcript, missing media, damaged transcript, export parity, speaker rename writeback, notes writeback, and failed-write preservation.
- [x] A short installed-app retest checklist is appended before moving this issue to `ready-for-human`.

## Suggested Files

- `macos/InsightKitApp/Sources/InsightKitApp/Models/MeetingAssetSnapshot.swift`
- `macos/InsightKitApp/Sources/InsightKitApp/ViewModels/RecordReviewDataSource.swift`
- `macos/InsightKitApp/Sources/InsightKitApp/Services/RecordDocumentExporter.swift`
- `macos/InsightKitApp/Sources/InsightKitApp/Services/RecordsIndexService.swift`
- `macos/InsightKitApp/Sources/InsightKitApp/Services/NotesFileIO.swift`
- `macos/InsightKitApp/Tests/InsightKitAppTests/RecordReviewDataSourceTests.swift`
- `macos/InsightKitApp/Tests/InsightKitAppTests/RecordDocumentExporterTests.swift`
- `macos/InsightKitApp/Tests/InsightKitAppTests/RecordsIndexServiceTests.swift`

## Constraints

- Preserve ADR-0001: native SwiftUI app plus Python Sidecar.
- Preserve ADR-0002: Unix socket JSON-RPC.
- Preserve ADR-0004: local Record Folders written through the Python Record Writer.
- Preserve ADR-0005: saved transcript timestamps use the final Media Timeline.
- Do not add `asset_manifest.json`.
- Do not migrate all historical Records in this slice.
- Do not treat diagnostics sidecars such as `capture_timeline.json` as official user-visible Record content.
- Do not claim public Distribution Ready.

## Verification Plan

- Run focused Swift tests for the meeting-asset read and write paths.
- Run Record Review adapter tests touched by the change.
- Run RecordDocumentExporter tests proving export parity with the loaded meeting asset.
- Run RecordsIndexService tests if search/listing behavior is touched.
- Run `git diff --check`.
- Run `python3 scripts/verify_project_normalization.py`.
- Sync to `/Users/yann.jy/Applications/InsightKit.app` before owner retest if user-visible behavior changes.

## Owner Retest Checklist To Fill After Implementation

- [ ] Open an existing complete Record and confirm media, transcript, Smart Minutes, and notes display normally.
- [ ] Export Markdown or PDF and confirm it matches the visible Record Review content.
- [ ] Rename a speaker in Record Review, reopen the Record, and confirm the name persists.
- [ ] Add or edit a Time-Bound Note, reopen the Record, and confirm the note persists.
- [ ] Open or create a Record with missing transcript and confirm the app shows a recoverable transcript state.
- [ ] Open or create a Record with missing media and confirm text content still opens with a clear media warning.

## Blocked by

None - owner accepted the product decisions on 2026-06-29.

## Comments

### 2026-06-29 - Codex

Created from the accepted Canonical Meeting Asset Source architecture discussion.

### 2026-06-29 - Codex

Implemented the first Canonical Meeting Asset Source slice.

- Deepened `MeetingAssetSnapshot` into the focused Record Folder read entrypoint.
- Added `MeetingAssetHealth` for metadata, media, transcript, Smart Minutes, notes, fallback use, damaged files, transcript recovery readiness, and Smart Minutes generation readiness.
- Kept `insight_package.json` as the official Smart Minutes source and reported `minutes.json` as legacy fallback health.
- Routed Record Review speaker rename through the canonical transcript write path.
- Routed Time-Bound Notes save through the canonical notes write path.
- Used atomic file replacement for official writes so failed writes preserve the previous official file.
- Routed `RecordDocumentExporter` transcript, notes, media, and Smart Minutes rendering through the same meeting asset snapshot.
- Added `insight_package.json` to the rebuildable search index while keeping Record Review content loaded from the Record Folder, not the index.
- Did not add `asset_manifest.json` or a new Record Folder schema.

Verification:

- `swift test --filter MeetingAssetSnapshotTests` - passed, 9 tests.
- `swift test --filter RecordsIndexServiceTests` - passed, 17 tests.
- `swift test --filter RecordDocumentExporterTests` - passed, 5 tests.
- `swift test --filter RuntimeActionClientsTests` - passed, 7 tests.
- `swift test` - passed, 232 tests.
- `git diff --check` - passed.
- `python3 scripts/verify_project_normalization.py` - passed; proof written to `logs/diagnostics/2026-06-29/project-normalization-20260629-023914/proof.json`.

Owner retest:

No immediate human-in-loop validation is required for this code slice. The installed-app checklist above remains the recommended owner retest path after the next installed build, because the visible behavior should remain consistent while the source of truth is now stricter.
