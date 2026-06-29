# Smart Minutes finalization lacks speaker rename controls

Status: ready-for-human

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

After a Live Workspace recording finishes and the user moves into the Smart Minutes finalization or generated Smart Minutes result view, the owner cannot find a way to edit speaker names there.

Meanwhile, Record Review appears to have gained an extra visible speaker-editing control even though it already had a speaker-editing workflow. This makes the control placement feel duplicated in one surface and missing in the surface where the owner actually needs it.

## What I expected

Speaker-name correction should be available at the point where the user is reviewing or preparing to trust the generated Smart Minutes.

The same speaker mapping should update transcript rows, Speaker Perspective content, exports, and any visible Smart Minutes modules that show speaker names.

Record Review should avoid duplicated speaker-editing entry points; the app should present one clear correction workflow per surface.

## Steps to reproduce

1. Launch the installed InsightKit app.
2. Create a Live Workspace recording with transcript rows that contain speaker labels.
3. Stop the recording and proceed into the Smart Minutes finalization or generated Smart Minutes result view.
4. Look for a way to rename `SPEAKER_00` or another speaker label before relying on the generated Smart Minutes.
5. Observe that the expected speaker-name correction workflow is missing from that Smart Minutes surface.
6. Open the saved Record in Record Review and observe that speaker-editing controls may appear duplicated there instead.

## Blocked by

None - can start immediately.

## Additional context

This supersedes issue 28's original scope. The owner clarified that the actual missing workflow is in the Smart Minutes finalization/result surface, not merely audio-only Record Review.

Use the project language: Smart Minutes, Record Review, Speaker Perspective, Transcript Segment, and Record.

## Comments

### 2026-06-26 - Manual QA

The owner clarified that speaker-name editing must be available where Smart Minutes are reviewed or finalized after recording.

Initial classification: `ready-for-agent`.

### 2026-06-26 - Code fix installed for owner retest

Status changed to `ready-for-human`.

Implemented:

- Smart Minutes finalization and generated Smart Minutes review now show a `说话人校正` control when the session contains editable speaker labels.
- The rename action updates the Live Session Transcript Segments, Smart Minutes speaker summaries, the last generated Insight package, and the Workbench speaker-facing metadata.
- If the matching Record has already been saved, the same rename is written to the Record `transcript.json` so later Record Review and document export use the corrected speaker name.
- Record Review no longer shows the extra horizontal speaker-rename strip that made the existing speaker workflow feel duplicated.

Proof:

- RED: `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testLiveSmartMinutesSpeakerRenameUpdatesRuntimeMinutesPackageAndPersistedRecord` failed before implementation because `LiveSessionViewModel` had no Smart Minutes speaker rename API.
- GREEN: the same focused test passed after implementation.
- Related gates passed:
  - `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests`, 44 tests, 0 failures.
  - `swift test --package-path macos/InsightKitApp --filter RecordsIndexServiceTests --filter RecordDocumentExporterTests`, 18 tests, 0 failures.
  - `swift test --package-path macos/InsightKitApp`, 180 tests, 0 failures.
- Standard sync: `bash scripts/sync_insightkit_app.sh` passed Swift and Python gates, including 139 Python tests, and installed build `20260626214019` to `/Users/yann.jy/Applications/InsightKit.app`.
- `codesign --verify --deep --strict --verbose=2 /Users/yann.jy/Applications/InsightKit.app` passed.

Human retest:

1. Launch `/Users/yann.jy/Applications/InsightKit.app`, build `20260626214019`.
2. Create a Live Workspace recording that produces `SPEAKER_00` or another speaker label.
3. Stop recording and check the Smart Minutes finalization stage for `说话人校正`.
4. Rename the speaker before or after generating Smart Minutes.
5. Confirm the transcript rows, Smart Minutes speaker summary, and exported Markdown/PDF use the corrected name.
6. Open the saved Record and confirm Record Review still has a clear speaker rename workflow without the extra horizontal strip.

### 2026-06-26 - Owner retest passed

The owner confirmed the installed Smart Minutes speaker-rename fix passed manual verification.
