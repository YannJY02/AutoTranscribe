# Route both visual toggles to Presenter Overlay guidance

Status: needs-info

## Parent

`.scratch/simultaneous-visual-presentation/PRD.md`

## What to build

When the user enables both camera and screen in the Live Workspace, route the state to Apple Presenter Overlay guidance instead of making one visual source silently replace the other.

The existing camera and screen toggles should remain. The user should see a clear state such as `屏幕录制 + Presenter Overlay`, plus guidance when macOS requires system-level confirmation. Camera-only and screen-only behavior must keep working.

User stories covered: 1, 2, 3, 4, 5, 6, 7, 11.

## Acceptance criteria

- [ ] Camera-only still resolves to the existing camera preview behavior.
- [ ] Screen-only still resolves to the existing screen preview behavior.
- [ ] Camera-plus-screen resolves to a Presenter Overlay presentation state when the system path is available.
- [ ] The Live Workspace keeps the existing camera and screen toggles; no separate presentation-mode button is introduced.
- [ ] The both-enabled state shows clear user guidance for enabling or confirming Presenter Overlay through macOS when required.
- [ ] If Presenter Overlay is unavailable or not enabled, screen capture remains usable.
- [ ] The fallback message clearly says camera presence will not be included in this Record.
- [ ] Turning one visual source off keeps the other active instead of stopping the whole visual preview.
- [ ] Unsupported macOS versions fall back to screen-only behavior without raising InsightKit's minimum supported macOS version.

## Blocked by

- `.scratch/simultaneous-visual-presentation/issues/01-verify-presenter-overlay-capture-feasibility.md`
