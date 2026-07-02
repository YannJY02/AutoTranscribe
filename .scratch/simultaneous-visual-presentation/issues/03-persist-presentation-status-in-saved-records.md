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
- [x] A saved Record can represent `screen plus camera captured`.
- [x] A saved Record can represent `screen-only fallback`.
- [x] Missing or unknown presentation status does not break older Records.
- [x] The presentation status is lightweight metadata, not a new multi-source media model.
- [x] The saved Record still presents one reviewable media asset aligned to the Media Timeline.
- [x] The status can be read by Record Review without making Record Review choose between separate visual source files.
- [x] Automated tests cover saving and reading Presenter Overlay status, screen-only fallback status, and older Records without the status.

## Blocked by

None. The route issue has been implemented and this support issue is ready for human review.

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

### 2026-07-01 - Strict native reclassification

The metadata plumbing works, but metadata is no longer acceptance proof for simultaneous visual presentation. Under the strict FaceTime-style Apple-native standard, a saved Record can only be called successful Presenter Overlay capture when the saved video visibly includes camera presence. Keep this metadata only as supporting evidence or fallback reporting; do not use it as the primary success signal.

The 2026-07-01 Apple-native revalidation exposed a stronger metadata problem: a saved Record with `"mediaType": "audio"` still wrote `"presentationStatus": "presenterOverlayCaptured"`. That status is therefore not reliable enough to drive product success or hide fallback/abnormal states. A later implementation pass should derive final presentation status from the actual saved media result, not just from live ScreenCaptureKit observation.

### 2026-07-01 - Final media downgrade implemented

Implemented final-media status validation before saving Record metadata. If live capture thought Presenter Overlay was present but the final saved media is not a video file, the saved status is downgraded to `visualMediaUnavailable`.

Verification:
- `swift test --package-path macos/InsightKitApp --jobs 1 --filter LiveSessionViewModelTests/testSaveToRecordsDowngradesPresenterOverlayWhenFinalMediaIsAudioOnly`.
- Installed-app saved Record: `~/Documents/InsightKit/Records/20260701-1118-live-record-856e0c8b/metadata.json` reports `"mediaType": "audio"` and `"presentationStatus": "visualMediaUnavailable"`.
- Installed-app fallback run: `~/Documents/InsightKit/Records/20260701-1137-live-record-35606308/metadata.json` reports `"mediaType": "audio"` and `"presentationStatus": "visualMediaUnavailable"` when the temp video is invalid.
- Focused test coverage also preserves the camera-plus-screen fallback marker across Live Workspace UI reset: `LiveSessionViewModelTests/testSessionUIResetPreservesVisualFallbackSelection`.

This support issue is ready for human review. It does not make simultaneous visual presentation accepted; issue 01 still controls the Apple-native saved-video proof.

### 2026-07-02 - Saved-output-first decision update

The metadata rule now applies to both accepted mechanisms: Apple Presenter Overlay when it passes saved-video proof, or a captured local camera overlay when issue 05 implements it with InsightKit-owned code. Metadata must name the real mechanism and must not claim Presenter Overlay if the saved result came from a captured local camera overlay.

### 2026-07-02 - Screen-plus-camera status persisted

Added `screenPlusCameraCaptured` as the mechanism-accurate saved Record status for the accepted local camera overlay path. The installed-app proof Record at `/Users/yann.jy/Documents/InsightKit/Records/20260702-1917-live-record-53301351` writes `"presentationStatus": "screenPlusCameraCaptured"` and keeps one playable saved video.

Verification:
- `swift test --package-path macos/InsightKitApp --jobs 1 --filter LiveSessionViewModelTests/testSaveToRecordsPersistsScreenPlusCameraCaptureStatus --filter LiveSessionViewModelTests/testSaveToRecordsDowngradesScreenPlusCameraWhenFinalMediaIsAudioOnly --filter RecordsIndexServiceTests/testRecordReviewShowsPresentationFallbackOnlyWhenCameraWasNotSaved`.
- Metadata artifact: `logs/diagnostics/2026-07-02/insightkit-saved-output-camera-overlay/record-53301351-metadata.json`.
