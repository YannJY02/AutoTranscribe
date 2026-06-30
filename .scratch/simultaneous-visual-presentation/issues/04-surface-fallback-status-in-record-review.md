# Surface fallback status in Record Review

Status: needs-info

## Parent

`.scratch/simultaneous-visual-presentation/PRD.md`

## What to build

Show presentation-status guidance in Record Review only when it matters. Successful Presenter Overlay captures should not add persistent status UI; screen-only fallback or abnormal capture should explain that camera presence was not included in the saved Record.

User stories covered: 9, 10, 12.

## Acceptance criteria

- [ ] Records marked `presenter overlay captured` open without adding persistent presentation-status UI.
- [ ] Records marked `screen-only fallback` show a clear, non-blocking message that camera presence was not included in the recording.
- [ ] Records without presentation status continue to open normally.
- [ ] The fallback message does not interfere with playback, transcript rows, Smart Minutes, Time-Bound Notes, or Media Seek.
- [ ] Record Review still treats the saved media as one media surface.
- [ ] Automated tests cover successful Presenter Overlay records, screen-only fallback records, and older Records without presentation status.

## Blocked by

- `.scratch/simultaneous-visual-presentation/issues/03-persist-presentation-status-in-saved-records.md`
