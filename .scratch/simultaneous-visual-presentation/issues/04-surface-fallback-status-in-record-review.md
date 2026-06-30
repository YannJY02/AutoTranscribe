# Surface fallback status in Record Review

Status: ready-for-human

## Parent

`.scratch/simultaneous-visual-presentation/PRD.md`

## What to build

Show presentation-status guidance in Record Review only when it matters. Successful Presenter Overlay captures should not add persistent status UI; screen-only fallback or abnormal capture should explain that camera presence was not included in the saved Record.

User stories covered: 9, 10, 12.

## Acceptance criteria

- [x] Records marked `presenter overlay captured` open without adding persistent presentation-status UI.
- [x] Records marked `screen-only fallback` show a clear, non-blocking message that camera presence was not included in the recording.
- [x] Records without presentation status continue to open normally.
- [x] The fallback message does not interfere with playback, transcript rows, Smart Minutes, Time-Bound Notes, or Media Seek.
- [x] Record Review still treats the saved media as one media surface.
- [x] Automated tests cover successful Presenter Overlay records, screen-only fallback records, and older Records without presentation status.

## Blocked by

- `.scratch/simultaneous-visual-presentation/issues/03-persist-presentation-status-in-saved-records.md`

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
