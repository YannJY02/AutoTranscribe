# Presenter Overlay Installed-App Validation

Use this checklist to decide whether Apple's Presenter Overlay is feasible as InsightKit's official simultaneous visual presentation path.

## Setup

1. Sync a current installed app:

   ```bash
   ./scripts/sync_insightkit_app.sh --skip-tests --debug --install-dir "$HOME/Applications"
   ```

2. Open `~/Applications/InsightKit.app`.
3. Make sure macOS screen recording and camera permissions are granted for InsightKit.

## Validation Run

1. Open the Live Workspace.
2. Enable screen and camera.
3. Confirm the Live Workspace shows a `屏幕录制 + Presenter Overlay` style state.
4. Use macOS system UI, such as the video effects menu, to enable Presenter Overlay if macOS requires it.
5. Record 15-30 seconds with a visually obvious screen marker and visible camera presence.
6. Stop and save the session.
7. Open the saved Record Review media.

## Result Classification

- `presenter overlay captured`: the saved Record media shows both the screen marker and the camera presence.
- `screen-only fallback`: the saved Record media shows the screen marker but no camera presence, and InsightKit warned that camera presence would not be included.
- `feasibility blocker`: Presenter Overlay was visible in system UI but did not appear in the saved Record media.

If the result is `feasibility blocker`, do not start custom compositor work automatically. Record the finding on issue 01 and make a separate product decision.
