# Speaker labels cannot be edited after transcription

Status: ready-for-human

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

When speaker labels are wrong, generic, or missing, there is no obvious way to edit speaker information from the Live Workspace, Record Review, or Smart Minutes review experience.

The owner cannot correct speaker names or merge mislabeled speaker turns after transcription.

## What I expected

InsightKit should let the user correct speaker labels after transcription.

At minimum, a user should be able to rename speaker labels and have the correction reflected consistently in Transcript Segments, Smart Minutes Speaker Perspectives, and exported documents.

## Steps to reproduce

1. Launch the installed InsightKit app.
2. Complete a Live Session or open an existing Record.
3. Find transcript rows or Smart Minutes content with generic or incorrect speaker labels.
4. Try to rename or correct the speaker label from the review experience.
5. Observe that no clear editing action is available.

## Additional context

Reported after owner retest of installed build `20260625165436`.

This issue is separate from automatic speaker diarization quality. Even if automatic diarization improves, users still need a way to correct labels when the app is wrong.

## Comments

### 2026-06-25 - Manual QA

The owner reported that speaker information cannot currently be modified after transcription.

### 2026-06-25 - Batch triage

Classification: `ready-for-agent`.

Why:

- This is a clear feature gap with a stable acceptance path: users need to rename or correct speaker labels after transcription.
- It does not require solving automatic diarization accuracy first.

Dependency:

- Related to issue 15, but not blocked by it.
- A first implementation can support renaming a speaker label across a Record before adding advanced merge/split tools.

Implementation boundary:

- Allow users to rename speaker labels in Record Review and/or Live review after transcript exists.
- Persist the correction into the Record so Transcript Segments, Smart Minutes speaker sections, search, and export use the corrected names.
- Do not attempt automatic speaker identity recognition in this issue.

Suggested verification:

- Add tests that update a speaker label in a persisted Record and confirm transcript/export-facing data uses the new label.
- Owner retest should confirm a wrong generic label can be corrected without editing files by hand.

### 2026-06-25 - Code fix installed for owner retest

Status changed to `ready-for-human`.

Implemented:

- Record Review now exposes a `说话人` menu listing speaker labels found in the transcript.
- A speaker label can be renamed from that menu or from a transcript row context menu.
- The rename is written back to `transcript.json`, and Record Review reloads Transcript Segments plus Smart Minutes speaker summaries from the corrected labels.
- Record export now uses the corrected speaker labels because export reads the updated transcript.

Proof:

- RED: `swift test --package-path macos/InsightKitApp --filter RecordsIndexServiceTests/testRecordReviewRenamesSpeakerAndExportUsesCorrectedLabel` failed before implementation because `renameSpeaker` did not exist.
- GREEN: `swift test --package-path macos/InsightKitApp --filter RecordsIndexServiceTests/testRecordReviewRenamesSpeakerAndExportUsesCorrectedLabel`, 1 relevant test, 0 failures.
- Related gate: `swift test --package-path macos/InsightKitApp --filter RecordsIndexServiceTests --filter RecordDocumentExporterTests`, 16 tests, 0 failures.
- Broad Swift gate: `swift test --package-path macos/InsightKitApp`, 161 tests, 0 failures.
- Standard sync: `bash scripts/sync_insightkit_app.sh`, Swift and Python gates passed; installed build `20260625222052` to `/Users/yann.jy/Applications/InsightKit.app`.

Owner retest:

- Open a saved Record in Records Workspace.
- Use the Record Review `说话人` menu or a transcript row context menu to rename a generic speaker label such as `SPEAKER_00`.
- Confirm transcript rows and Smart Minutes speaker summaries update, and exported Markdown/PDF use the corrected name.

### 2026-06-26 - Owner retest passed

The owner confirmed the installed Record Review speaker-label rename workflow works as expected.
