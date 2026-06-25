# Live session stop/start can continue previous transcription backlog

Status: ready-for-human

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

Sometimes after stopping a Live Workspace transcription and then clicking "开始直播洞察" again, InsightKit does not enter the expected Live Workspace flow for the next session.

Instead, the app appears to continue transcription from the previous run. The Smart Minutes choice does not appear for the stopped session, and the user sees delayed transcript content from the prior session continue to arrive.

The owner observed that this often happens when transcription is lagging behind the real conversation, suggesting the previous session may still have pending transcript work when the next action is clicked.

## What I expected

Clicking stop should reliably close the current live Session boundary.

After stop:

- the stopped session should enter the post-session Smart Minutes choice when appropriate;
- delayed transcript work from the previous session should not make the app look like recording is still active;
- starting a new Live Workspace session should create a clean new session and must not continue or merge delayed transcript rows from the previous session.

## Steps to reproduce

1. Launch the installed InsightKit app.
2. Open the Live Workspace.
3. Click "开始直播洞察" and speak long enough for Live Transcript rows to appear.
4. While transcription appears to be slightly behind the real conversation, click "停止".
5. Click "开始直播洞察" again.
6. Observe whether the app shows the Smart Minutes choice for the stopped session or instead continues showing delayed transcription from the previous run.

## Additional context

Reported during owner-led manual QA after build `20260625140443` was installed.

This is intermittent. The key user-facing problem is the session boundary: a stopped Live Workspace session should not keep behaving like an active transcription session, and delayed transcript backlog should not hide the Smart Minutes choice or bleed into the next Live Workspace start.

This appears related to Session Phase, Live Transcript Pipeline backlog, and stop/start behavior, but the issue intentionally does not assume a root cause.

## Comments

### 2026-06-25 - Manual QA

The owner reported that the issue happens sometimes after clicking stop and then starting Live Insight again. The app may continue transcribing instead of showing the Smart Minutes generation choice, and delayed transcript rows from the previous round appear to arrive late.

### 2026-06-25 - Focused triage and code fix installed

Root cause:

- `stopLiveSession(finalState:)` set `isRunning` to false before the old Live Session had fully finalized on the background pipeline queue.
- During that short finalization window, `activeMeetingID` still existed, but `WorkflowCoordinator.livePhase` ignored it and treated the app as ready to prepare/start a new Live Session.
- `canStartSession` also only checked `!isRunning`, so the toolbar could allow a new "开始直播洞察" click while the old session still had pending transcript/finalization work.
- The stop finalization also read the active meeting ID later inside the background closure, which made the session boundary fragile if the user started another session quickly.

Implemented fix:

- `LiveSessionViewModel.canStartSession` now blocks new starts while an unresolved `activeMeetingID` still exists.
- `startLiveSession()` now respects the same `canStartSession` gate.
- `stopLiveSession(finalState:)` captures the active meeting ID at stop time before asynchronous finalization work begins.
- `WorkflowCoordinator.livePhase` now treats a non-running but still-active meeting as `livePostSession`, so the app stays in the previous session's post-session boundary instead of returning to the preparing state too early.

Verification:

- Red/green regression: `swift test --package-path macos/InsightKitApp --filter WorkflowCoordinatorTests/testActiveLiveMeetingStillBlocksNewLiveStartWhileStopIsFinalizing`
- Related gate: `swift test --package-path macos/InsightKitApp --filter WorkflowCoordinatorTests --filter LiveSessionViewModelTests` -> 34 tests, 0 failures
- Full Swift gate: `swift test --package-path macos/InsightKitApp` -> 146 tests, 0 failures
- Standard app sync: `PATH=/Users/yann.jy/miniconda3/bin:$PATH bash scripts/sync_insightkit_app.sh` -> success, including Swift and Python gates

Installed proof:

- Installed app: `/Users/yann.jy/Applications/InsightKit.app`
- Installed build: `20260625165436`
- Git revision: `1463cd7`
- Build source: `local-workspace-dirty`
- Proof file: `logs/workflow/latest_sync.json`

Owner retest:

1. Start Live Workspace and speak long enough for Transcript rows to appear.
2. Click "停止" while transcription feels slightly behind the real conversation.
3. Immediately try to start Live Insight again.
4. Expected: the previous session should stay inside its post-session boundary and reach the Smart Minutes choice/review path; delayed rows from the old session should not make a new session look like it is continuing the previous transcription.

### 2026-06-25 - Owner retest passed

The owner confirmed that issue 13 is fixed in the installed app.

Follow-up QA found additional UX and Record Review issues, filed separately as issues 14-20.
