# Record default names are hard to read

Status: ready-for-human

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

Saved transcription records can appear with technical or low-information names that are hard to read and hard to distinguish in the Records Workspace.

The owner reported that transcription record names are not readable enough for everyday use.

## What I expected

Record names should help the user identify the meeting asset without opening each Record.

A default Record name should be readable and should preferably reflect the meeting time, source, first topic, or Smart Minutes summary when available.

## Steps to reproduce

1. Launch the installed InsightKit app.
2. Create one or more Live Session Records or imported transcription Records.
3. Open the Records Workspace.
4. Review the names shown in the Record Index.
5. Observe that the names can be difficult to understand or distinguish.

## Additional context

Reported after owner retest of installed build `20260625165436`.

This issue covers default naming quality. Manual renaming is tracked separately in issue 19.

## Comments

### 2026-06-25 - Manual QA

The owner reported that transcription record names have poor readability.

### 2026-06-25 - Batch triage

Classification: `ready-for-agent`.

Why:

- Current Record list surfaces can display technical identifiers, while metadata already includes fields such as creation time, source, duration, tags, and summary preview.
- A bounded implementation can improve the display name without requiring manual rename support first.

Dependency:

- Related to issue 19, but not blocked by it.
- If issue 19 later adds a user-defined title, that title should override the generated default display name.

Implementation boundary:

- Improve default Record display names in the Record Index and Record Review.
- Prefer human-readable context such as Smart Minutes summary preview, source, and date/time.
- Preserve stable Record IDs for storage and internal lookup; do not rename folders as part of this issue.

Suggested verification:

- Add a pure display-name test for Records with and without `summaryPreview`.
- Owner retest should confirm Records are distinguishable in the Records Workspace without opening every Record.

### 2026-06-25 - Code fix installed for owner retest

Status changed to `ready-for-human`.

Implemented:

- `RecordMetadata` now has a user-facing `displayTitle`.
- Display title priority is: manual title, then Smart Minutes `summaryPreview`, then a readable source/date fallback such as `实时记录 ...` or `导入记录 ...`.
- Home recent records, Record list items, Record grid items, Record Review header, and exports use the readable display title instead of falling back directly to the technical Record ID.
- Stable Record IDs and Record Folder names are preserved.

Proof:

- RED: `swift test --package-path macos/InsightKitApp --filter RecordsIndexServiceTests/testRecordDisplayTitlePrefersManualTitleThenSummaryThenReadableFallback` failed before implementation because `displayTitle` did not exist.
- GREEN: `swift test --package-path macos/InsightKitApp --filter RecordsIndexServiceTests/testRecordDisplayTitlePrefersManualTitleThenSummaryThenReadableFallback`, 1 relevant test, 0 failures.
- Related gate: `swift test --package-path macos/InsightKitApp --filter RecordsIndexServiceTests --filter RecordDocumentExporterTests`, 16 tests, 0 failures.
- Broad Swift gate: `swift test --package-path macos/InsightKitApp`, 161 tests, 0 failures.
- Standard sync: `bash scripts/sync_insightkit_app.sh`, Swift and Python gates passed; installed build `20260625222052` to `/Users/yann.jy/Applications/InsightKit.app`.

Owner retest:

- Open Records Workspace.
- Confirm Records show readable titles in the list and review header.
- Confirm Records without Smart Minutes summary no longer show only an opaque technical ID as their main visible name.

### 2026-06-26 - Owner retest passed

The owner confirmed Records now show readable names as expected in the installed app.
