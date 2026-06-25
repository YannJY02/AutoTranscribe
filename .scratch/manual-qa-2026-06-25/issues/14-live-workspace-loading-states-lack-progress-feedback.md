# Live Workspace loading states lack progress feedback

Status: ready-for-human

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

During model loading or Session Phase transitions, InsightKit can appear idle or stuck because the Live Workspace does not provide enough user-facing progress feedback.

The owner does not consider this a functional bug, but it makes the experience feel frozen during operations such as model warmup, runtime startup, or moving between recording, post-session finalization, and Smart Minutes generation.

## What I expected

When InsightKit is doing slow background work, the app should clearly show what is happening and whether the user should wait.

The Live Workspace should distinguish normal loading, model warmup, finalization, and generation states from a stalled or failed state.

## Steps to reproduce

1. Launch the installed InsightKit app.
2. Open the Live Workspace.
3. Start a Live Session or trigger Smart Minutes generation.
4. Observe the app while the local runtime, model warmup, Session Phase transition, or Smart Minutes generation is taking time.
5. Notice that the UI can look idle enough that a user may think the app is stuck.

## Additional context

Reported after owner retest of installed build `20260625165436`.

This is an experience issue around Capture State and Session Phase feedback, not a report that the underlying runtime failed.

## Comments

### 2026-06-25 - Manual QA

The owner reported that model loading and status transitions need clearer progress messages or loading indicators so less technical users do not mistake normal waiting for a frozen app.

### 2026-06-25 - Batch triage

Classification: `ready-for-agent`.

Why:

- The report is specific enough to implement without more owner input.
- The app already has Capture State, Session Phase, Runtime Warmup, and recording status concepts, so the work can be bounded to clearer user-facing loading/progress feedback.
- This should not change the ASR engine, provider, or Sidecar behavior.

Implementation boundary:

- Add visible progress/state feedback for normal waiting states such as runtime startup, model warmup, post-session finalization, and Smart Minutes generation.
- Keep error banners reserved for actual failures.
- Do not broaden this into runtime performance tuning.

Suggested verification:

- Add a presentation-state or ViewModel test that maps normal loading states to user-facing messages.
- Run the related Swift test target.
- Owner retest should confirm the app no longer looks frozen during normal loading or phase transitions.

### 2026-06-25 - Code fix installed for owner retest

Status changed to `ready-for-human`.

Implementation summary:

- Added a Live Workspace progress presentation for normal waiting states: runtime preparation, Runtime Warmup, post-recording finalization, and Smart Minutes generation.
- Exposed the progress presentation through the Center Stage panel data source so the Live Center can render it without depending on one concrete ViewModel.
- Added a visible non-error progress banner with title and message accessibility identifiers.
- Set Smart Minutes generation to enter the visible refreshing state immediately after the user starts generation.

TDD proof:

- RED: `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testLiveWorkspaceProgressExplainsRuntimePreparation` failed because `LiveSessionViewModel` had no `liveProgressPresentation`.
- RED: `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testLiveWorkspaceProgressExplainsModelWarmup` failed because warmup returned no progress presentation.
- RED: `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testLiveWorkspaceProgressExplainsPostRecordingFinalization` failed because `LiveSessionViewModel` had no `isFinalizingLiveSession`.
- RED: `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testLiveWorkspaceProgressExplainsSmartMinutesGeneration` failed because Smart Minutes generation returned no progress presentation.
- RED: `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testCenterStageDataSourceExposesLiveProgressPresentation` failed because `CenterStageDataSource` did not expose the progress presentation.
- GREEN: each test above passed after its corresponding implementation slice.
- GREEN: `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests` passed, 34 tests, 0 failures.
- GREEN: `swift test --package-path macos/InsightKitApp` passed, 151 tests, 0 failures.

Installed-app proof:

- Installed build: `20260625183127`
- Sync proof: `logs/workflow/latest_sync.json`
- Command: `scripts/sync_insightkit_app.sh --debug --skip-tests`
- Installed smoke: launched `/Users/yann.jy/Applications/InsightKit.app` in UI-test Live route and quit successfully.

Known verification gap:

- Direct `xcodebuild` UI test did not reach app behavior because the existing generated Xcode project is stale and does not include the already-existing `LiveVisualPreviewSource` file. Swift Package tests and installed-app launch smoke passed.

Owner retest:

- Start a Live Session and confirm the app shows clear progress while preparing the runtime and warming the model.
- Stop recording and confirm the app shows that it is organizing/saving the session before the Smart Minutes choice appears.
- Generate Smart Minutes and confirm the app shows that Smart Minutes are being generated before entering review.

### 2026-06-25 - Owner retest passed

The owner confirmed issue 14 passes in the installed app.
