# Generated summary does not open the summary review interface

Status: ready-for-human

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

After the transcription or live session ended and the app should have entered the summary experience, the Session Shell still looked like the in-progress transcription view: the main area continued to emphasize Transcript Segments and only a basic Smart Minutes summary was visible.

The user expected to be taken into a completed summary or review interface, but the visible page looked almost the same as the page shown during transcription.

The confusing part is that the summary had actually been generated; the problem was that the app did not visibly transition into the expected summary review experience.

## What I expected

When Final Insight Generation or Smart Minutes generation completes, the app should clearly enter a completed review state that foregrounds the generated summary and its sections.

The user should be able to tell that the summary is finished without inferring it from the small Smart Minutes text beside the transcript.

If the app intentionally keeps the same Session Shell after generation, it should still make the completed summary state obvious and expose the full Smart Minutes review affordances.

## Steps to reproduce

1. Launch the installed InsightKit app.
2. Open the Live Workspace.
3. Start a session and capture enough speech to produce Transcript Segments.
4. Stop the session and choose to generate Smart Minutes or final summary content.
5. Wait until the summary content has been generated.
6. Observe that the visible interface can remain transcript-dominant and look similar to the in-progress transcription page, instead of entering a clear summary review interface.

## Additional context

Reported during owner-led manual QA against installed InsightKit build `20260625103254`.

The owner emphasized that this is not a missing-summary problem: the summary had already been generated. The issue is the missing or unclear transition into the expected summary interface after generation completes.

This is separate from issue 07, where Final Insight Generation timed out. This issue covers the successful-generation case where the generated result is available but not presented through the expected completed summary experience.

## Comments

### 2026-06-25 - Manual QA

The owner reported that after transcription ended and the app should have entered the summary interface, the app still showed a page dominated by transcript information and a basic summary, similar to the recording/transcription page, even though the summary was actually ready.

### 2026-06-25 - Focused triage

Promoted to `ready-for-agent` for implementation at that point. Later comments record the installed fix and current `ready-for-human` state.

Code triage found this as a completed-summary presentation problem, not a missing-generation problem. `LiveSessionViewModel.buildFinalInsight()` can set `sessionPhase = .reviewing` after successful Final Insight Generation, but `LiveCenterView.reviewingView` still centers the media player and Transcript Segment list. The generated Smart Minutes summary is mostly visible in the left chapter sidebar, so the main workspace can still look like the live transcription view.

Bounded implementation target:

- make the completed summary/review state visually distinct after Smart Minutes or Final Insight Generation succeeds;
- foreground generated summary sections in the center review experience or provide an obvious review mode switch;
- keep transcript and media available, but make "summary is ready" clear without relying on a small sidebar summary;
- avoid changing issue 07 timeout handling, because this issue is the successful-generation presentation case.

Suggested regression loop:

- add a pure presentation-state test or small layout planner test that receives `sessionPhase = .reviewing` plus generated Smart Minutes data;
- assert that the chosen review presentation foregrounds Smart Minutes rather than defaulting to transcript-only emphasis;
- if no test seam exists, create a small view-model/layout decision seam before changing the SwiftUI view.

Dependency note: this can be implemented after issue 09 and issue 10 because it is mostly UX/presentation, while those issues affect runtime error-state clarity.

### 2026-06-25 - Code fix installed

Implemented a completed-summary review presentation path for successful Smart Minutes / Final Insight results.

Root cause:

- `LiveSessionViewModel.buildFinalInsight()` could successfully enter `reviewing`, but `LiveCenterView.reviewingView` still foregrounded the media player and Transcript Segment list.
- Smart Minutes existed in the workbench data, but the center-stage data contract did not expose it, so the main workspace could not choose a summary-first review presentation.

Implemented:

- added a small `LiveReviewPresentationPlan` decision seam;
- exposed generated Smart Minutes through `CenterStageDataSource`;
- changed the Live Workspace reviewing state to show a summary-first center view when generated Smart Minutes exist;
- kept transcript and media available below the generated summary so review evidence is still accessible.

Verification:

- `swift test --package-path macos/InsightKitApp --filter LiveReviewPresentationPlanTests`
- `swift test --package-path macos/InsightKitApp`
- standard sync script passed Swift and Python gates and installed build `20260625140443`

Installed proof:

- installed app: `/Users/yann.jy/Applications/InsightKit.app`
- installed build: `20260625140443`
- proof: `logs/workflow/latest_sync.json`

Owner retest should confirm that after successful summary generation, the center workspace visibly enters a generated-summary review experience instead of remaining transcript-dominant.

### 2026-06-25 - Conditional owner retest passed

The owner reported that issue 12 conditionally passes: when the newly filed issue 13 stop/start backlog problem does not occur, the generated-summary review experience works normally.

Residual dependency:

- issue 13 can still prevent the flow from reliably reaching the post-session Smart Minutes choice, so issue 12 should remain recorded as conditionally passed rather than independently closing all Live Workspace summary-transition behavior.

### 2026-06-25 - Owner retest passed

The owner confirmed issue 12 is resolved after the related stop/start backlog path was also handled.

Generated Smart Minutes now open into the expected summary review experience and are no longer an active blocker for continuing manual QA.
