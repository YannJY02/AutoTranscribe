# Live Sidecar memory spike can freeze and restart the system

Status: ready-for-human

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

During Live Workspace QA, InsightKit became unstable enough that the Mac froze and restarted.

The owner observed InsightKit using about 30 GB of runtime memory before the restart.

The Apple diagnostic from the same event shows a system watchdog panic:

`watchdog timeout: no checkins from watchdogd in 92 seconds`

The panic process snapshot shows the top resident-memory process was a `python3.11` Sidecar process with `31,549,955,160` resident bytes, about 29.4 GiB.

## What I expected

Live recording should stay within bounded resource usage.

If local ASR, MLX, camera capture, Insight Refresh, or Sidecar work begins consuming unsafe memory, InsightKit should stop or degrade the live workflow with a recoverable message rather than allowing the system to become unresponsive.

The app should never let a live session destabilize the operating system.

## Steps to reproduce

1. Launch the installed InsightKit app.
2. Open the Live Workspace.
3. Start a live recording session using the current local ASR setup.
4. Continue the session until realtime transcription or Insight Refresh begins failing with Sidecar GPU stream errors.
5. Monitor memory usage while the live session continues.
6. Observe that Sidecar memory can grow to roughly 30 GB and the system can freeze or restart.

## Additional context

Reported during owner-led manual QA against installed InsightKit build `20260625090217`.

This occurred in the same QA window as the continuing Sidecar GPU stream error, including:

`There is no Stream(gpu, 2) in current thread.`

The diagnostic evidence points to a resource-containment failure in the local Sidecar process. It should be triaged separately from the visible GPU stream error because the user impact is much more severe: system-wide freeze/restart rather than only failed Live Workspace output.

The main app process was not the high-memory process in the panic snapshot; the high-memory process was the Sidecar Python runtime.

## Acceptance criteria

- [x] The memory spike has a red-capable automated loop that fails when live ASR keeps one Qwen MLX session per caller thread.
- [x] Qwen MLX live chunk processing no longer caches one heavyweight session per Sidecar caller thread.
- [x] The fix is installed into `/Users/yann.jy/Applications/InsightKit.app`.
- [ ] Owner retests the installed app with Activity Monitor open and confirms Sidecar memory remains bounded during a short Live Workspace session.

## Comments

### 2026-06-25 - Manual QA

Owner reported InsightKit occupied about 30 GB runtime memory and the computer froze/restarted.

Diagnostic extraction:
- panic date: `2026-06-25 09:18:33 +0200`
- panic type: watchdog timeout
- top resident-memory process: `python3.11`
- resident memory: `31,549,955,160` bytes
- app bundle under test: installed InsightKit build `20260625090217`

Current check after diagnostic review did not find the prior app/Sidecar PIDs still running.

### 2026-06-25 - Diagnosis and fix

Diagnosed with the `diagnosing-bugs` loop using a resource-safe regression test instead of reproducing the 30 GB freeze.

Red/green feedback loop:

`/Users/yann.jy/miniconda3/bin/python3.11 -m pytest tests/test_qwen_mlx_thread_affinity.py::test_qwen_mlx_live_chunks_do_not_create_unbounded_thread_sessions -q`

Before the fix, the loop failed deterministically because 4 concurrent live chunk caller threads retained 4 Qwen MLX cache keys:

`created=4 cache_keys=[('qwen-mlx', 'fake-qwen-model', ...), ...]`

Root cause found: the prior Qwen MLX thread-affinity fix cached sessions by `threading.get_ident()`. In the Sidecar, live ASR chunk work can arrive on different RPC handler threads. That turned caller-thread growth into heavyweight Qwen MLX session growth, matching the panic evidence where the Sidecar `python3.11` process reached about 29.4 GiB resident memory.

Fix applied: Qwen MLX now runs through a single long-lived `_QwenMLXWorker` thread per model source. The worker owns the MLX session and all live chunk calls queue into that same owner thread. Runtime reset and cache discard now shut down cached workers.

Verification:
- Red loop failed before the fix and passed after the fix.
- `tests/test_qwen_mlx_thread_affinity.py` - `2 passed`.
- Related ASR/Sidecar tests - `16 passed, 1 warning`.
- Full Python pytest suite - `210 passed, 1 warning`.
- Sync-script Swift and Python gates passed when run with `/Users/yann.jy/miniconda3/bin` first in `PATH`.
- Standard app sync succeeded after moving the package output to `/tmp` to avoid `dist/macos` extended-attribute signing detritus.
- Installed app path: `/Users/yann.jy/Applications/InsightKit.app`
- Installed build: `20260625094746`
- Installed git revision: `1463cd7`
- Installed build source: `local-workspace-dirty`
- Installed bundle `codesign --verify --deep --strict` passed.
- Installed bundle contains `_QwenMLXWorker` in `Contents/Resources/insightkit_runtime/scripts/transcriber.py`.

Manual retest should be short and guarded: open Activity Monitor or another memory view, start a brief Live Workspace session, and stop immediately if the Sidecar memory climbs abnormally. Do not intentionally continue toward a system freeze.
