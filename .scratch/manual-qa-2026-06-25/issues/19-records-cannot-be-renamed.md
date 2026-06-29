# Records cannot be renamed

Status: ready-for-human

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

The owner cannot find a way to rename a saved Record after it appears in the Records Workspace.

If the app creates an unclear or inaccurate Record name, the user has no obvious in-app way to correct it.

## What I expected

InsightKit should let the user rename a saved Record from the Records Workspace or Record Review.

The new name should persist in the Record Index and should be used in review and export contexts where a human-readable title is expected.

## Steps to reproduce

1. Launch the installed InsightKit app.
2. Create or open a saved Record.
3. Open the Records Workspace or Record Review.
4. Try to rename the Record from the list item, context menu, detail view, or toolbar.
5. Observe that no clear rename action is available.

## Additional context

Reported after owner retest of installed build `20260625165436`.

This issue is separate from improving automatic default names. Even with better defaults, users need a manual correction path.

## Comments

### 2026-06-25 - Manual QA

The owner reported that saved transcription Records cannot currently be renamed.

### 2026-06-25 - Batch triage

Classification: `ready-for-agent`.

Why:

- This is a clear Records Workspace feature gap.
- The user expectation is stable: rename a saved Record and see the new name persist in list, review, search, and export contexts.

Dependency:

- Related to issue 18, but not blocked by it.
- The implementation should define how a manual title overrides any generated default display name.

Implementation boundary:

- Add an in-app rename action for saved Records.
- Persist the new human-readable name in Record metadata.
- Keep Record folder IDs stable unless a separate migration issue explicitly decides otherwise.
- Do not implement full metadata editing beyond the Record name in this issue.

Suggested verification:

- Add RecordsIndexService or RecordMetadata tests for persisting a renamed title.
- Add a UI-facing test seam proving the Record Index uses the manual title after rename.
- Owner retest should confirm a Record can be renamed from the app without touching files.

### 2026-06-25 - Code fix installed for owner retest

Status changed to `ready-for-human`.

Implemented:

- Records can be renamed from the Record list context menu.
- Records can also be renamed from the Record Review toolbar.
- The manual title is persisted in `metadata.json` as `title`.
- Search includes the manual title.
- Manual title overrides generated default display names while keeping Record Folder IDs stable.

Proof:

- RED: `swift test --package-path macos/InsightKitApp --filter RecordsIndexServiceTests/testRenameRecordPersistsManualTitleAndSearchUsesIt` failed before implementation because `renameRecord` and `title` did not exist.
- GREEN: `swift test --package-path macos/InsightKitApp --filter RecordsIndexServiceTests/testRenameRecordPersistsManualTitleAndSearchUsesIt`, 1 relevant test, 0 failures.
- Related gate: `swift test --package-path macos/InsightKitApp --filter RecordsIndexServiceTests --filter RecordDocumentExporterTests`, 16 tests, 0 failures.
- Broad Swift gate: `swift test --package-path macos/InsightKitApp`, 161 tests, 0 failures.
- Standard sync: `bash scripts/sync_insightkit_app.sh`, Swift and Python gates passed; installed build `20260625222052` to `/Users/yann.jy/Applications/InsightKit.app`.

Owner retest:

- Open Records Workspace.
- Rename a saved Record from the list context menu or Record Review toolbar.
- Return to the Record list or search for the new title.
- Confirm the new name persists after reopening the app.

### 2026-06-26 - Owner retest passed

The owner confirmed saved Records can be renamed and the new names persist as expected.
