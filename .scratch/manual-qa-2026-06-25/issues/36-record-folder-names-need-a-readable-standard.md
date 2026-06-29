# Record Folder names need a readable standard

Status: ready-for-human

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

Generated Record Folder names are hard to understand when inspected outside the app.

The owner reported that the saved records file/folder names do not communicate what the meeting asset is, making them difficult to browse, recover, or reason about from Finder.

## What I expected

Record Folder names should follow a predictable, readable standard while preserving a stable identity for app lookup.

A good standard should make it clear when the record was created, whether it came from Live Workspace or Import Workspace, and ideally include a short safe topic/title slug plus a stable short identifier.

## Steps to reproduce

1. Launch the installed InsightKit app.
2. Create a new Live Workspace Record or imported transcription Record.
3. Open the Records Workspace.
4. Use the Record's Finder/reveal action, or inspect the configured Records root directory.
5. Observe that the generated Record Folder name is difficult to interpret without opening its metadata.

## Blocked by

None - code fix installed for owner retest.

## Additional context

Issue 18 improved the user-facing display title while intentionally preserving stable Record IDs and Record Folder names. This issue is the separate storage-name standard: how Record Folders should be named on disk without breaking existing records, links, exports, or recovery.

The triage pass should decide whether the folder name itself should become human-readable, whether a readable alias should be added, or whether Finder-facing reveal/export flows should present a readable label while keeping opaque folder IDs.

## Comments

### 2026-06-26 - Manual QA

Reported during owner-led QA after the Records Workspace naming improvements.

Initial classification: `needs-triage`.

Why:

- The problem is clear, but the fix has persistence and compatibility consequences.
- A naming standard should be decided before changing Record Folder creation or migration behavior.

### 2026-06-27 - Readable Record Folder naming standard installed

Status changed to `ready-for-human`.

Naming standard:

- New Record folders use `YYYYMMDD-HHMM-{live|import}-{topic-slug}-{shortid}`.
- `topic-slug` is derived from the passed Record title first, then generated Smart Minutes title/overview if the title is generic.
- `shortid` is derived from the stable `meeting_id` so Finder names stay readable while app identity remains stable.
- `metadata.json.id` remains the canonical Record ID; existing legacy folders named only by ID remain supported.
- Repeated writes for the same `meeting_id` reuse the existing folder by reading `metadata.json`, preventing duplicate folders when Smart Minutes are generated after the first save.

Implemented:

- Python `RecordWriter` now creates readable folders for new Records and reuses existing folders by metadata ID.
- Swift `RecordsIndexService` now resolves a Record folder by scanning `metadata.json` when the folder name is not the raw ID.
- Record Review, Reveal in Finder, rename persistence, delete, native export, and completed-import artifact loading now use the same resolver.

Verification:

- RED: new `RecordWriter` tests failed while folders were still named directly by `meeting_id`.
- GREEN: `python -m pytest tests/test_record_writer.py -q`, 22 tests, 0 failures.
- Related Python gate: `python -m pytest tests/test_record_writer.py tests/test_record_e2e.py tests/test_transcription_runner_local_fallback.py -q`, 32 tests, 0 failures.
- Swift resolver gate: `swift test --package-path macos/InsightKitApp --filter RecordsIndexServiceTests`, 17 tests, 0 failures.
- Broad Swift gate: `swift test --package-path macos/InsightKitApp`, 190 tests, 0 failures.
- Installed sync: `scripts/sync_insightkit_app.sh --install-dir /Users/yann.jy/Applications --skip-tests`.
- Installed build: `20260627004202`; proof: `logs/workflow/latest_sync.json`.

Owner retest:

1. Create one imported Record and one Live Workspace Record in build `20260627004202`.
2. Use "在访达中显示" from Records Workspace or Record Review.
3. Confirm new folders follow `YYYYMMDD-HHMM-{live|import}-{topic-slug}-{shortid}` and are understandable in Finder.
4. Confirm opening, renaming, exporting, deleting, and reopening the same Record still work.
