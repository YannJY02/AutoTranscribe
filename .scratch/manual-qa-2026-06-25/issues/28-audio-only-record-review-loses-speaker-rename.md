# Audio-only Record Review loses speaker rename controls

Status: wontfix

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

When reviewing a Record that has audio playback but no recorded video, the previously fixed speaker rename workflow disappears.

The owner can no longer find the speaker rename entry point in that audio-only Record Review state.

## What I expected

Speaker rename should be available whenever a Record has Transcript Segments with speaker labels, regardless of whether the Record contains video, audio-only media, or no visual preview.

At minimum, Record Review should keep the `说话人` menu or transcript-row rename action available for audio-only records.

## Steps to reproduce

1. Launch the installed InsightKit app.
2. Open or create a Record that has audio playback but no recorded video.
3. Open the Record in Record Review.
4. Look for the speaker rename controls, such as the `说话人` menu or transcript-row rename action.
5. Observe that the speaker rename workflow is no longer available.

## Blocked by

None - can start immediately.

## Additional context

This is a regression of issue 16 for the audio-only Record Review state.

The expected behavior is not automatic diarization improvement. It is the manual speaker-label correction workflow remaining available in every Record Review media state.

## Comments

### 2026-06-26 - Manual QA

The owner reported that the speaker rename feature disappears when the Record has no video.

Initial classification: `ready-for-agent`.

Why:

- The previous speaker rename workflow already exists and passed owner retest.
- The failing condition is specific: audio-only Record Review should still expose speaker correction.

### 2026-06-26 - Diagnosing Bugs

Diagnosis:

- The data layer still supported speaker rename for saved Records: `RecordReviewDataSource.renameSpeaker` persists label changes into `transcript.json`.
- The regression was in the visible Record Review controls. The existing rename entry points depended on a crowded top toolbar menu and row context menus, which made the workflow easy to lose in the audio-only review state.
- Audio-only review should not need a video preview to expose speaker correction; the real condition is whether the Record has transcript rows with speaker labels.

Fix:

- Added `RecordSpeakerRenamePresentation` to define speaker-rename visibility independent of media type.
- Added a visible `说话人` strip in Record Review whenever editable transcript speakers exist.
- Added a visible row-level pencil action for transcript rows with speaker labels while keeping the existing context-menu rename path.
- Empty speaker labels are normalized to `未标注`, so unlabeled rows can still be corrected.

Verification:

- RED loop: focused tests failed before implementation because `RecordSpeakerRenamePresentation` did not exist.
- `swift test --package-path macos/InsightKitApp --filter RecordsIndexServiceTests/testAudioOnlyRecordReviewShowsVisibleSpeakerRenameStrip --filter RecordsIndexServiceTests/testTranscriptRowWithSpeakerShowsVisibleRenameAction --filter RecordsIndexServiceTests/testRecordReviewRenamesSpeakerAndExportUsesCorrectedLabel` passed: 3 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp --filter RecordsIndexServiceTests` passed: 14 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp` passed before sync, and `bash scripts/sync_insightkit_app.sh` reran the full sync gate successfully.
- `bash scripts/sync_insightkit_app.sh` installed build `20260626200713`.
- `codesign --verify --deep --strict --verbose=2 /Users/yann.jy/Applications/InsightKit.app` passed.

Human retest:

1. Launch `/Users/yann.jy/Applications/InsightKit.app`, build `20260626200713`.
2. Open an audio-only saved Record with transcript speaker labels.
3. Confirm the visible `说话人` strip appears in Record Review.
4. Click a speaker chip or a row pencil button, rename `SPEAKER_00`, and confirm visible rows update.
5. Export the Record and confirm the corrected speaker label is used in the exported document.

Current classification: `ready-for-human`.

### 2026-06-26 - Owner clarified original problem was mis-scoped

The owner clarified that the missing speaker-name editing control was not primarily an audio-only Record Review problem.

Record Review already had a speaker-editing path, and the later visible speaker strip can feel like a duplicate control there. The actual missing surface is the Smart Minutes finalization / Smart Minutes result view reached after recording, where the owner expects speaker names to be editable before relying on the generated minutes.

This issue is superseded by issue 32, which records the corrected user-facing problem.

Current classification: `wontfix`.
