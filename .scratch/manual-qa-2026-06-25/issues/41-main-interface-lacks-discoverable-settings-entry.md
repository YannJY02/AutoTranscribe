# Main interface lacks a discoverable Settings entry

Status: ready-for-human

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

The installed app's main interface does not provide an obvious entry into the Settings Workspace.

The owner also tried the bottom status bar, but clicking it did not expose a Settings option.

## What I expected

InsightKit should provide a discoverable Settings Workspace entry from the main app surface, not only through a hidden or easy-to-miss macOS menu command.

The entry should be reachable from normal Home Workspace and session workflows, and status or recovery surfaces that mention configuration should have a clear path to Settings.

## Steps to reproduce

1. Launch installed InsightKit build `20260627145522`.
2. Open the main app interface.
3. Look for a visible Settings Workspace entry in the Home Workspace or primary app controls.
4. Click the bottom status bar and check whether it exposes configuration actions.
5. Observe that there is no obvious Settings entry from the main interface or status bar.

## Blocked by

None - can start immediately.

## Additional context

This is a discoverability issue, not a request to remove existing macOS menu behavior.

Settings is now important for ASR Runtime, Provider, permission recovery, and Apple Speech prototype status, so the main user workflow needs a visible route into it.

## Comments

### 2026-06-27 - Settings Workspace entry fix installed

Status changed to `ready-for-human`.

Implementation:

- Added a visible `设置` button to the Home Workspace header with a gear icon and `home_open_settings` accessibility identifier.
- Added a `设置` action to the bottom status bar for non-home workspace routes with `bottom_status_open_settings` accessibility identifier.
- Routed both visible entries through `WorkflowCoordinator.openSettings()`, preserving the existing macOS menu command and settings window implementation.
- Added a bottom-status action model so future status-bar actions stay explicit instead of becoming one-off view code.

Verification:

- Red check: `swift test --package-path macos/InsightKitApp --filter WorkflowCoordinatorTests` initially failed because `WorkflowCoordinator.openSettings()`, `BottomStatusPayload.actions`, and `BottomStatusAction.settings` did not exist.
- `swift test --package-path macos/InsightKitApp --filter WorkflowCoordinatorTests`, 8 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp`, 213 tests, 0 failures.
- `git diff --check`, passed.
- `bash -n scripts/package_insightkit_app.sh`, passed.
- `bash -n scripts/release_preflight.sh`, passed.
- Installed sync: `./scripts/sync_insightkit_app.sh --skip-tests`, build `20260627154910`.
- `plutil -p logs/workflow/latest_sync.json` reports `status = success`, `build_version = 20260627154910`, and install path `/Users/yann.jy/Applications/InsightKit.app`.
- `/Users/yann.jy/Applications/InsightKit.app/Contents/Info.plist` has `CFBundleVersion = 20260627154910`.
- `codesign --verify --deep --strict --verbose=2 /Users/yann.jy/Applications/InsightKit.app`, passed.
- Visual GUI Proof: `logs/diagnostics/2026-06-27/issue41-home-settings-entry.png` shows the Home Workspace `设置` button.
- Visual GUI Proof: `logs/diagnostics/2026-06-27/issue41-live-bottom-status-settings-entry.png` shows the Live Workspace bottom status bar `设置` action.

Human retest:

- Run installed build `20260627154910`.
- From the Home Workspace, click the visible `设置` button and confirm the Settings Workspace opens.
- Enter Live Workspace or another non-home workspace and click the bottom status bar `设置` action.
- Expected result: both routes open the same Settings Workspace without relying on the hidden macOS app menu.

### 2026-06-27 - Owner retest passed

The owner confirmed the installed Settings Workspace entry fix passed retest.

Status remains `ready-for-human` as a completed issue awaiting normal archive/close handling.
