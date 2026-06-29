# Session pages are obscured by the bottom status bar

Status: ready-for-human

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

In Smart Minutes, Record Review, and related session pages, the bottom status bar can cover the lower part of the page.

The owner reported that transcript content can become incomplete or hard to read because the bottom bar overlaps the visible content area.

## What I expected

Session pages should reserve enough bottom space for the bottom status bar.

Transcript rows, Smart Minutes modules, media controls, and notes should remain fully visible and scrollable without being hidden behind the bottom bar.

## Steps to reproduce

1. Launch the installed InsightKit app.
2. Open a session page such as Smart Minutes review, Record Review, or another replay/review surface.
3. Scroll transcript or review content toward the bottom of the page.
4. Observe whether the final transcript rows or lower page controls are hidden behind the bottom status bar.
5. Toggle the bottom status bar between collapsed and developer mode if available.

## Blocked by

None - can start immediately.

## Additional context

This is a layout and content-inset issue across Session Shell surfaces. It should be handled separately from media playback bugs because the problem is that content is obscured, not that the media or transcript data is missing.

The acceptance check should cover both collapsed and expanded bottom status states.

## Comments

### 2026-06-26 - Manual QA

Reported during owner-led QA after the playback and Record Review fixes.

Initial classification: `ready-for-agent`.

Why:

- The failure is user-visible and affects review/readability.
- The expected behavior is clear: bottom chrome should not cover transcript or review content.
- It can be verified without changing transcription or Smart Minutes generation.

### 2026-06-27 - Bottom status bar layout fix installed

Diagnosis:

- `ContentView` used `safeAreaInset(edge: .bottom)` for the bottom status bar.
- Mixed AppKit/SwiftUI workspace surfaces such as `HSplitView` and nested Record Review shells could still render content under the bottom chrome instead of treating the status bar as a real layout row.

Fix:

- Added `BottomStatusBarLayout` as the single source for bottom bar height and reserved content height.
- Non-home workspace routes now render as a `VStack`: route content fills the remaining area, and `BottomStatusBarView` occupies an explicit bottom row.
- The Home Workspace still has no bottom status bar reserve.

Verification:

- RED loop failed before implementation because `BottomStatusBarLayout` did not exist.
- Focused GREEN passed: `swift test --package-path macos/InsightKitApp --filter BottomStatusBarLayoutTests` -> 3 tests, 0 failures.
- Full Swift gate passed: `swift test --package-path macos/InsightKitApp` -> 188 tests, 0 failures.
- Standard sync's Python unittest gate remains blocked by the local Homebrew Python environment missing `pytest`, `faster-whisper`, and `silero-vad`; this is recorded as an environment gate issue, not an issue 35 code failure.
- Installed sync succeeded with the already-passed Swift gate using `scripts/sync_insightkit_app.sh --install-dir /Users/yann.jy/Applications --skip-tests`.
- Installed build: `20260627001915`; proof: `logs/workflow/latest_sync.json`.

Human retest:

- Run installed build `20260627001915`.
- Open Smart Minutes review, Record Review, and another non-home workspace.
- Scroll transcript/review content to the bottom and confirm the final rows/controls remain visible above the bottom status bar.
- Toggle developer mode in the bottom status bar and confirm content remains unobscured.

### 2026-06-27 - Owner retest passed

The owner confirmed issue 35 is resolved after the bottom-status-bar layout fix. Session page content is no longer obscured by the bottom status bar in the checked workflow.
