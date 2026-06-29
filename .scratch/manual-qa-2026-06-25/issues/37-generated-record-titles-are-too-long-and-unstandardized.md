# Generated Record titles are too long and unstandardized

Status: ready-for-human

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

Generated titles in the transcription records surface can be too long and lack a consistent naming pattern.

The owner reported that even when records are readable, the visible title can still be unwieldy and non-standard.

## What I expected

Generated Record titles should be short, predictable, and scannable in the Records Workspace and Record Review header.

Long Smart Minutes summaries should not become the main title unbounded. Richer summary text can remain available as secondary preview text, search content, or Smart Minutes content.

## Steps to reproduce

1. Launch the installed InsightKit app.
2. Create or open several Records that have generated transcript and Smart Minutes content.
3. Open the Records Workspace and compare the visible Record titles.
4. Open a Record Review and inspect the header title.
5. Observe that generated titles can be long and inconsistent, making the record list harder to scan.

## Blocked by

None - code fix installed for owner retest.

## Additional context

This is separate from issue 36. Issue 36 covers Record Folder names on disk. This issue covers user-visible generated titles in the Record Index, Record Review, recent-record surfaces, and exports.

The triage pass should decide the generated-title standard, including maximum visible length, date/source prefix rules, topic extraction rules, and how manual rename should override generated titles.

## Comments

### 2026-06-26 - Manual QA

Reported during owner-led QA after the owner reviewed the current Records Workspace naming behavior.

Initial classification: `needs-triage`.

Why:

- The symptom is clear, but the desired title standard needs a product decision.
- The implementation should not accidentally replace useful Smart Minutes summary text with an over-short title.

### 2026-06-27 - Generated Record title standard installed

Status changed to `ready-for-human`.

Title standard:

- Manual Record rename still wins and is not truncated by this generated-title rule.
- Generated titles from `summaryPreview` are cleaned by collapsing whitespace and stripping leading markdown bullets.
- Generated titles are capped at 44 characters and end with `...` when truncated.
- The richer Smart Minutes summary remains available in `summaryPreview`, search content, `minutes.json`, and exports; only the main visible title is shortened.
- Records without a generated title still fall back to the source/date title such as `实时记录 ...` or `导入记录 ...`.

Implemented:

- `RecordMetadata.displayTitle` now normalizes generated titles before Records Workspace, Record Review, recent Records, and export surfaces render them.
- Existing manual rename behavior from issue 19 is preserved.

Verification:

- RED: generated-title test failed before the standard existed.
- GREEN: `swift test --package-path macos/InsightKitApp --filter RecordsIndexServiceTests/testGeneratedRecordDisplayTitleUsesShortStandardizedTitle --filter RecordsIndexServiceTests/testRecordFolderResolverFindsReadableFolderByMetadataID`, 2 tests, 0 failures.
- Related Swift gate: `swift test --package-path macos/InsightKitApp --filter RecordsIndexServiceTests`, 17 tests, 0 failures.
- Broad Swift gate: `swift test --package-path macos/InsightKitApp`, 190 tests, 0 failures.
- Installed sync: `scripts/sync_insightkit_app.sh --install-dir /Users/yann.jy/Applications --skip-tests`.
- Installed build: `20260627004202`; proof: `logs/workflow/latest_sync.json`.

Owner retest:

1. Open build `20260627004202`.
2. Create or open Records with long generated summaries.
3. Confirm Records Workspace and Record Review show short, scannable generated titles.
4. Rename a Record manually and confirm the manual title still overrides the generated title.
