# Record Review back navigation skips the Records Workspace

Status: ready-for-human

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

After entering a saved Record from the Records Workspace, the available exit action returns all the way to the Home Workspace.

The owner expected the action to return to the previous Records Workspace list instead.

## What I expected

Record Review should follow normal back-navigation behavior.

When the user opens a Record from the Records Workspace, the back action should return to the Records Workspace list. It should not skip back two levels to the Home Workspace unless the user explicitly chooses to go home.

## Steps to reproduce

1. Launch the installed InsightKit app.
2. Open the Records Workspace.
3. Select a saved Record to enter Record Review.
4. Use the available exit or back action from Record Review.
5. Observe that the app returns to the Home Workspace instead of the Records Workspace list.

## Blocked by

None - can start immediately.

## Additional context

This is an interaction-flow issue, not a media playback issue. The expected mental model is "back to previous level" rather than "exit to app start."

## Comments

### 2026-06-26 - Manual QA

The owner reported that Record Review navigation currently jumps back too far in the app hierarchy.

Initial classification: `ready-for-agent`.

### 2026-06-26 - Code fix installed

Fix installed in `/Users/yann.jy/Applications/InsightKit.app` build `20260626222305`.

Diagnosis:

- The app-level navigation toolbar only knew about `Home Workspace` versus non-home routes.
- Because `Record Review` lived inside the `Records Workspace`, the toolbar still exposed a generic `返回首页` action while the user expected a one-level back action.

Fix:

- Added shared `RecordsWorkspaceNavigation` state for whether a saved Record is currently open.
- The top navigation action now becomes `返回列表` while viewing a Record Review, and closes the Record Review without leaving the Records Workspace.
- The action remains `返回首页` from the Records Workspace list and other non-home workflows.

Verification:

- RED/GREEN: `swift test --package-path macos/InsightKitApp --filter WorkflowCoordinatorTests/testPrimaryNavigationFromRecordReviewReturnsToRecordsListInsteadOfHome`
- Related gate: `swift test --package-path macos/InsightKitApp --filter WorkflowCoordinatorTests`
- Full Swift gate: `swift test --package-path macos/InsightKitApp` -> 183 tests, 0 failures
- Sync/install: `bash scripts/sync_insightkit_app.sh` passed Swift/Python gates, including 139 Python tests
- Installed build: `20260626222305`
- Code signing: `codesign --verify --deep --strict --verbose=2 /Users/yann.jy/Applications/InsightKit.app` passed

Owner retest:

1. Launch build `20260626222305`.
2. Open the Records Workspace.
3. Open any saved Record.
4. Use the top-left navigation action or the in-review back action.
5. Expected: the app returns to the Records Workspace list, not Home Workspace.

### 2026-06-26 - Owner retest passed

The owner confirmed Record Review back navigation now returns to the Records Workspace list as expected.
