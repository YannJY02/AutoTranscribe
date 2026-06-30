# Persist presentation status in saved Records

Status: ready-for-human

## Parent

`.scratch/simultaneous-visual-presentation/PRD.md`

## What to build

Save lightweight presentation status with a Record created from simultaneous visual presentation, so later review can tell whether camera presence was captured by Presenter Overlay or the session fell back to screen-only recording.

The status should be enough for Record Review and QA to distinguish expected fallback from a bug. It should not introduce a broad new Record schema or require users to choose between separate visual sources.

User stories covered: 8, 9, 10, 12.

## Acceptance criteria

- [x] A saved Record can represent `presenter overlay captured`.
- [x] A saved Record can represent `screen-only fallback`.
- [x] Missing or unknown presentation status does not break older Records.
- [x] The presentation status is lightweight metadata, not a new multi-source media model.
- [x] The saved Record still presents one reviewable media asset aligned to the Media Timeline.
- [x] The status can be read by Record Review without making Record Review choose between separate visual source files.
- [x] Automated tests cover saving and reading Presenter Overlay status, screen-only fallback status, and older Records without the status.

## Blocked by

- `.scratch/simultaneous-visual-presentation/issues/02-route-both-visual-toggles-to-presenter-overlay-guidance.md`

## Comments

### 2026-07-01 - Codex

Implemented lightweight Record metadata persistence:
- Added optional `RecordMetadata.presentationStatus`.
- Plumbed `LivePresentationCaptureStatus` through `LiveSessionFinalizer`, `RecordSaveActionRequest`, `InsightRPCClient.recordsSave`, Python `record.save`, and `RecordWriter`.
- Python writes `metadata.json` key `presentationStatus` only when a status is present, so older Records remain compatible.
- `RecordWriter` lookup no longer reads every historical `metadata.json` before saving new Records; it filters by the meeting short id first. This fixed the real `record.save` timeout found during validation.
- Video capture now keeps writer state checks on `writerQueue`, which fixed the real case where preview frames were visible but the saved Record fell back to audio-only.

Verification:
- `pytest tests/test_record_writer.py::TestRecordWriter::test_metadata_includes_presentation_status_when_provided tests/test_record_writer.py::TestRecordWriter::test_existing_record_lookup_skips_unrelated_metadata tests/test_runtime_action_boundary.py::test_record_save_contract_success_invalid_input_and_write_failure -q`.
- `swift test --package-path macos/InsightKitApp --jobs 1 --filter LiveSessionViewModelTests/testSaveToRecordsPersistsPresentationCaptureStatus --filter RecordsIndexServiceTests/testRefreshIndexReadsOptionalPresentationStatusAndKeepsLegacyRecordsCompatible`.
- Installed-app saved Record: `~/Documents/InsightKit/Records/20260701-0021-live-record-f2567901/metadata.json` includes `"presentationStatus": "presenterOverlayCaptured"` and one playable `recording.mp4`.
