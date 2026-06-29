# Settings banner action can crash after transcription failure

Status: ready-for-agent

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

After a transcription failure in installed build `20260627161028`, the app crashed when the owner used the visible Settings action from the in-app banner.

The crash terminates InsightKit instead of opening Settings or letting the owner recover the failed transcription configuration.

## What I expected

Any in-app Settings action should open the Settings Workspace without crashing, including actions shown from recovery banners after a Live Workspace or transcription failure.

If Settings cannot open, InsightKit should keep the current workspace alive and show a recoverable error.

## Steps to reproduce

1. Launch installed InsightKit build `20260627161028`.
2. Trigger a Live Workspace or transcription failure that shows an in-app banner with a Settings action.
3. Click the banner's Settings action.
4. Observe that the app can terminate with a crash instead of opening Settings.

## Blocked by

None - can start immediately.

## Additional context

The supplied crash report is from build `20260627161028` on macOS 26.6. It is a main-thread `EXC_BAD_ACCESS` while handling the Settings action from a banner. This is a separate crash class from the earlier microphone tap startup crash.
