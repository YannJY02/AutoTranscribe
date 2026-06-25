# Live notes entry is not discoverable or usable during recording

Status: ready-for-human

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

During live recording, the right-side notes area did not provide an obvious or usable writing surface. The owner could not reliably write notes and could not find a clear notes entry point.

The visible notes input appeared too small and too far down in the workspace to support active note-taking during a session.

## What I expected

The Live Workspace should reserve enough visible space for Time-Bound Notes during recording.

The notes entry point should be easy to find, large enough for real writing, and clearly connected to the live session timeline.

## Steps to reproduce

1. Launch the installed InsightKit app.
2. Open the Live Workspace.
3. Start a live recording session.
4. Look at the right-side notes area.
5. Try to write a note while the session is recording.

## Additional context

Reported during owner-led manual QA against InsightKit build `20260625003524`.

The screenshot showed a right-side notes panel with "录制中，可在下方输入笔记" and a very small input field near the bottom of the window. From the owner's perspective, the app did not provide a sufficient writing area or an obvious note-taking workflow.

This should be triaged as a Live Workspace UX issue around Time-Bound Notes. Triage should separately verify whether typed notes are actually rejected, whether the input field is simply too small, and whether submitted notes appear in the notes list.

## Comments

### 2026-06-25 - Manual QA

Reported during owner-led manual QA against InsightKit build `20260625003524`.

### 2026-06-25 - Batch dependency triage

Promoted to `ready-for-agent`.

Code triage found that the Time-Bound Notes data path exists, but the editor uses a small single-line field at the bottom of the right panel. This is an independent Live Workspace UX issue, not blocked by the runtime or media-preview issues.

See `.scratch/manual-qa-2026-06-25/triage-dependency-map.md`.

### 2026-06-25 - Diagnosing-bugs implementation pass

Root cause found: `TimestampNotesEditor` exposed Time-Bound Notes through a small single-line `NSTextField` at the bottom of the right panel. The note data path worked, but the visible writing surface was too small and too far from the panel header to support live note-taking.

Implemented:

- Replaced the single-line note field with a multi-line `TextEditor` writing surface.
- Moved the editable note composer above the existing notes list so the entry point is visible when recording starts.
- Added `TimeBoundNotesEditorLayout` to keep the composer at least 112 points tall and prevent regressions to a tiny single-line field.
- Preserved the `live_note_input` and `live_note_submit_button` accessibility identifiers for automation and accessibility.
- Updated the Live Workspace UI test to look for the multi-line note input and submit via the button.

Verification:

- Red loop: `swift test --package-path macos/InsightKitApp --filter TimestampNotesEditorLayoutTests` failed with the old 22-point, bottom-positioned, single-line configuration.
- Red loop: `PATH=/Users/yann.jy/miniconda3/bin:$PATH python -m pytest tests/test_time_bound_notes_editor_ux.py -q` failed while `usesSingleLineMode = true` remained in `TimestampNotesEditor`.
- Green loop: both target gates passed after implementation.
- Full Swift gate: `swift test --package-path macos/InsightKitApp` passed, 138 tests, 0 failures.
- Python source regression gate: `PATH=/Users/yann.jy/miniconda3/bin:$PATH python -m pytest tests/test_time_bound_notes_editor_ux.py -q` passed, 2 tests.
- Standard sync gate: `PATH=/Users/yann.jy/miniconda3/bin:$PATH bash scripts/sync_insightkit_app.sh` passed Swift and Python gates.

Install status:

- Installed app: `/Users/yann.jy/Applications/InsightKit.app`.
- Installed build: `20260625115936`.
- Sync proof: `logs/workflow/latest_sync.json`.

Owner retest focus:

- During recording, the right-side notes panel should show a large multi-line writing area near the top.
- Typed notes should submit through `添加笔记` and appear in the notes list as Time-Bound Notes.
- The notes panel should no longer feel like a tiny bottom input field with no obvious writing space.

### 2026-06-25 - Owner retest passed

The owner confirmed that the Time-Bound Notes UX fix was successful in the installed app.
