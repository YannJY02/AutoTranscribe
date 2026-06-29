# Final Insight Generation times out after a live session

Status: ready-for-human

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

After a Live Workspace session reached post-session finalization, the app showed a realtime speech-summary error:

`调用超时: insight.build_final`

The Session Shell showed the session in review/post-session state and Smart Minutes content was partially visible, but the finalization status still reported an error. The user-facing result is confusing: the app appears to have transcript and Smart Minutes evidence, but the final insight pass is marked as failed or timed out.

## What I expected

When a live session stops, Final Insight Generation should either complete and leave the Session Shell in a clean review state, or degrade with a clear recoverable action that does not make the whole realtime speech summary look broken.

If Smart Minutes already has usable content, the app should preserve it and clearly explain what still needs retrying.

## Steps to reproduce

1. Launch the installed InsightKit app.
2. Open the Live Workspace.
3. Start a live recording session and speak enough for transcript segments and Smart Minutes content to appear.
4. Stop the session and let it enter post-session finalization or review.
5. Wait for Final Insight Generation or trigger the visible Insight Refresh/finalization action.
6. Observe that the error banner and bottom status can show `调用超时: insight.build_final`.

## Additional context

Reported during owner-led manual QA against installed InsightKit build `20260625094746`.

Visible session context:
- meeting ID: `live-CE6088C3-93DB-4FDE-AD59-9BAD0732FDFD`
- session phase: review/post-session state
- last refresh shown around `9:57`
- Smart Minutes summary text was visible, so the timeout should be treated as a final insight/retry-state problem rather than a total absence of meeting content

This is separate from the earlier raw Qwen MLX GPU stream Sidecar error. The visible error here is a timeout from the final insight action.

## Comments

### 2026-06-25 - Manual QA

The owner reported that post-session finalization showed `调用超时: insight.build_final` even though Smart Minutes content and transcript rows were visible.

### 2026-06-25 - Batch dependency triage

Promoted to `ready-for-agent`.

Code triage found that `InsightRPCClient.buildFinal` currently uses the default RPC timeout path, while long ASR chunk work already has its own longer timeout. This issue is separate from Capture Preview and Time-Bound Notes. It should preserve partial transcript or Smart Minutes evidence when Final Insight Generation times out.

See `.scratch/manual-qa-2026-06-25/triage-dependency-map.md`.

### 2026-06-25 - Issue 07 implemented

Used `diagnosing-bugs`.

Root cause: `InsightRPCClient.buildFinal` called `insight.build_final` through the default RPC timeout. The default timeout is appropriate for short RPC actions, but Final Insight Generation can legitimately take longer because it waits for provider-backed final insight output.

Change:

- Added `finalInsightTimeoutSec` to `InsightRPCClient.Config`.
- Added env override `INSIGHTKIT_FINAL_INSIGHT_RPC_TIMEOUT_SEC`, defaulting to `60`.
- Routed `insight.build_final` through `max(config.timeoutSec, config.finalInsightTimeoutSec)`.
- Added a Swift regression test with a local fake Unix socket Sidecar that waits 2 seconds before returning a valid final insight package.

Red loop:

- `swift test --package-path macos/InsightKitApp --filter InsightRPCClientFinalInsightTimeoutTests/testBuildFinalUsesDedicatedFinalInsightTimeout`
- Before the fix, the test failed with `timeout("insight.build_final")`.

Verification:

- `swift test --package-path macos/InsightKitApp --filter InsightRPCClientFinalInsightTimeoutTests/testBuildFinalUsesDedicatedFinalInsightTimeout` - passed.
- `swift test --package-path macos/InsightKitApp` - 130 tests passed.
- `PATH=/Users/yann.jy/miniconda3/bin:$PATH bash scripts/sync_insightkit_app.sh` - passed.
- Installed app: `/Users/yann.jy/Applications/InsightKit.app`.
- Installed build: `20260625103254`.
- Sync proof: `logs/workflow/latest_sync.json`.

Remaining human check:

- Retest a short Live Workspace session in the installed app and stop the session.
- Expected: normal slow Final Insight Generation should complete without the `调用超时: insight.build_final` banner.
- If a provider genuinely exceeds 60 seconds, the app can still show a timeout; that should become a follow-up UX/retry issue rather than reopening this narrow timeout-regression fix.

### 2026-06-25 - Owner retest passed

The owner confirmed issue 07 is resolved.

The `insight.build_final` timeout is no longer an active blocker for continuing manual QA.
