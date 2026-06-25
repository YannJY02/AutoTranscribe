# Live summary error banner cannot open Settings Workspace

Status: ready-for-human

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

When the Live Workspace showed a real-time speech summary error banner, clicking the banner action `打开设置` did not visibly open the Settings Workspace and appeared to do nothing.

## What I expected

The error recovery action should open the Settings Workspace so the user can inspect or repair runtime, provider, or permission configuration.

If the app cannot open settings, it should show clear feedback instead of silently doing nothing.

## Steps to reproduce

1. Launch the installed InsightKit app.
2. Open the Live Workspace.
3. Start or resume a live session until the real-time speech summary error banner appears.
4. Click `打开设置` in the error banner.
5. Observe that no Settings Workspace appears and no visible recovery action occurs.

## Additional context

Reported during owner-led manual QA against InsightKit build `20260625003524`.

The visible banner showed:

`Insight 侧车错误: There is no Stream(gpu, 1) in current thread.`

This should be triaged separately from the Sidecar runtime failure. Even when Insight Refresh fails, the recovery entry point should still be reliable and visible.

## Acceptance criteria

- [x] Computed live/transcription error banners pass their own `actionRoute` when the user clicks the banner action.
- [x] `WorkflowCoordinator` can execute an explicit `open_settings` action even when the banner was computed by `ContentView` and not stored in `coordinator.bannerMessage`.
- [x] The installed app contains the fix.
- [x] Owner retests the installed app and confirms the realtime speech-summary error banner opens the Settings Workspace.

## Comments

### 2026-06-25 - Manual QA

The owner clicked `打开设置` from the real-time speech summary error banner and reported that it was unresponsive.

### 2026-06-25 - Batch dependency triage

Promoted to `ready-for-agent`.

Code triage found a likely no-op path: live/transcription error banners can be computed directly by `ContentView.activeBanner`, but the button calls `WorkflowCoordinator.performBannerAction()`, which currently returns early if `coordinator.bannerMessage` is nil. This is independent and should be fixed before or alongside further runtime diagnosis because it is the main recovery route for Sidecar and provider errors.

See `.scratch/manual-qa-2026-06-25/triage-dependency-map.md`.

### 2026-06-25 - Diagnosis and fix

Diagnosed with the `diagnosing-bugs` loop.

Red-capable feedback loop:

`/Users/yann.jy/miniconda3/bin/python3.11 -m pytest tests/test_live_error_banner_settings_action.py -q`

Before the fix, this failed because `ContentView` called `coordinator.performBannerAction()` without passing the computed banner's `actionRoute`, and `WorkflowCoordinator.performBannerAction()` returned early when `coordinator.bannerMessage` was nil.

Root cause:

Live and transcription error banners can be computed directly by `ContentView.activeBanner`, so they do not necessarily exist as `coordinator.bannerMessage`. The banner button still delegated to `WorkflowCoordinator.performBannerAction()` with no route argument. Because the coordinator only looked at its stored banner, the action became a no-op for computed error banners.

Fix applied:

- `ContentView.bannerBar` now calls `coordinator.performBannerAction(for: banner.actionRoute)`.
- `WorkflowCoordinator.performBannerAction(for:)` now accepts an explicit route while preserving the existing stored-banner fallback.
- `WorkflowCoordinator` now has an injectable `settingsOpener`, so the Settings Workspace action can be verified without opening a real window in tests.

Verification:

- `/Users/yann.jy/miniconda3/bin/python3.11 -m pytest tests/test_live_error_banner_settings_action.py -q` - `2 passed`.
- `swift test --package-path macos/InsightKitApp --filter WorkflowCoordinatorTests/testComputedBannerActionCanOpenSettingsWithoutStoredBannerMessage` - passed.
- `swift test --package-path macos/InsightKitApp --filter WorkflowCoordinatorTests` - `4 passed`.
- `swift test --package-path macos/InsightKitApp` - `129 passed`.
- `rg -n "\\[DEBUG-" macos scripts tests .scratch || true` - no debug instrumentation found.
- `PATH=/Users/yann.jy/miniconda3/bin:$PATH bash scripts/sync_insightkit_app.sh` - success.

Installed app:

- path: `/Users/yann.jy/Applications/InsightKit.app`
- build version: `20260625102417`
- git revision: `1463cd7`
- build source: `local-workspace-dirty`
- sync proof: `logs/workflow/latest_sync.json`

The remaining gate is owner retest in the installed app.

### 2026-06-25 - Owner retest passed

The owner confirmed during manual QA that the realtime speech-summary error banner action `打开设置` now opens the Settings Workspace.

A new, separate realtime speech-summary banner issue was observed during the same QA pass: `调用超时: insight.refresh_live`. That behavior is tracked as issue 09 and should not reopen this settings-route issue.
