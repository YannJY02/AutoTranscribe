# Surface fallback status in Record Review

Status: ready-for-human

## Parent

`.scratch/simultaneous-visual-presentation/PRD.md`

## What to build

Show presentation-status guidance in Record Review only when it matters. Successful Presenter Overlay captures should not add persistent status UI; screen-only fallback or abnormal capture should explain that camera presence was not included in the saved Record.

User stories covered: 9, 10, 12.

## Acceptance criteria

- [x] Records marked `presenter overlay captured` open without adding persistent presentation-status UI.
- [x] Records marked `screen plus camera captured` open without adding persistent presentation-status UI.
- [x] Records marked `screen-only fallback` show a clear, non-blocking message that camera presence was not included in the recording.
- [x] Records without presentation status continue to open normally.
- [x] The fallback message does not interfere with playback, transcript rows, Smart Minutes, Time-Bound Notes, or Media Seek.
- [x] Record Review still treats the saved media as one media surface.
- [x] Automated tests cover successful Presenter Overlay records, screen-only fallback records, and older Records without presentation status.

## Blocked by

None. The presentation-status metadata issue has been implemented and this support issue is ready for human review.

## Comments

### 2026-07-01 - Codex

Implemented Record Review fallback presentation:
- `RecordReviewDataSource` exposes a presentation-status message only when metadata says `screenOnlyFallback`.
- `RecordsView` renders that message below the media player with the existing non-blocking warning style.
- `presenterOverlayCaptured`, camera-only, screen-only, `none`, and legacy nil status do not add persistent presentation-status UI.
- Record Review still uses the single saved media URL; no source chooser was introduced.

Verification:
- `swift test --package-path macos/InsightKitApp --jobs 1 --filter RecordsIndexServiceTests/testRecordReviewShowsPresentationFallbackOnlyWhenCameraWasNotSaved`.
- Installed-app success path: `logs/diagnostics/2026-06-30/presenter-overlay-validation-video-writer/live-review-video-record.png`.

### 2026-07-01 - Strict native reclassification

The fallback UI remains useful, but the previous installed-app path is not a success path under the strict saved-video standard. Record Review should not hide fallback status merely because metadata says `presenterOverlayCaptured`; visible saved-media evidence must decide whether camera presence was actually captured.

The 2026-07-01 Apple-native revalidation found a saved audio-only Record whose metadata still said `presenterOverlayCaptured`. Record Review should treat that shape as abnormal or fallback unless a playable saved video exists and visible-frame review has proven camera presence.

### 2026-07-01 - Audio-only visual-media-unavailable status surfaced

Added Record Review handling for `visualMediaUnavailable`. Records with that status show a non-blocking message that no video was saved and review contains only audio, transcript, and notes. Successful Presenter Overlay records still do not add persistent status UI.

Verification:
- `swift test --package-path macos/InsightKitApp --jobs 1 --filter RecordsIndexServiceTests/testRecordReviewShowsPresentationFallbackOnlyWhenCameraWasNotSaved`.
- Installed-app saved Record: `~/Documents/InsightKit/Records/20260701-1118-live-record-856e0c8b` has `presentationStatus: visualMediaUnavailable`.
- Installed-app saved Record: `~/Documents/InsightKit/Records/20260701-1137-live-record-35606308` also has `presentationStatus: visualMediaUnavailable` after an invalid temp video fallback run.

This support issue is ready for human review. It reports fallback/abnormal saved media accurately, but it does not satisfy the FaceTime-style simultaneous presentation requirement.

### 2026-07-02 - Saved-output-first decision update

Record Review should continue to stay quiet for successful simultaneous visual presentation, whether the mechanism is Apple Presenter Overlay or a captured local camera overlay. It should surface guidance only when the saved Record is screen-only, audio-only, or otherwise missing visible camera presence.

### 2026-07-02 - Screen-plus-camera success remains quiet in Record Review

Added Record Review coverage for `screenPlusCameraCaptured`. Successful saved-output camera overlay Records do not add persistent presentation-status UI; fallback and visual-media-unavailable Records still show non-blocking guidance.

Verification:
- `swift test --package-path macos/InsightKitApp --jobs 1 --filter RecordsIndexServiceTests/testRecordReviewShowsPresentationFallbackOnlyWhenCameraWasNotSaved`.
