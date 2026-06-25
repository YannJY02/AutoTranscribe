# Live Insight Refresh fails with GPU stream sidecar error during recording

Status: ready-for-human

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

During a live recording session, the app showed a real-time summary error:

`Insight 侧车错误: There is no Stream(gpu, 1) in current thread.`

During a later retest after a Qwen MLX thread-cache fix, the same behavior still reproduced with:

`Insight 侧车错误: There is no Stream(gpu, 2) in current thread.`

The Live Workspace stayed in the recording state, but the real-time speech summary entered an abnormal state and did not run normally.

## What I expected

Live recording should continue and the real-time speech summary should either produce Insight Refresh output or degrade with a clear, recoverable message.

The user should not see a raw GPU stream error from the Sidecar as the main Live Workspace status.

## Steps to reproduce

1. Launch the installed InsightKit app.
2. Open the Live Workspace.
3. Enable camera capture and start live recording.
4. Let the live session run until the app attempts real-time speech summary or Insight Refresh.
5. Observe the top error banner and Live Workspace status.

## Additional context

Reported during owner-led manual QA against InsightKit build `20260625003524`.

The screenshot showed a live session with Meeting ID `live-69D16BDA-0900-49B1-933A-F8B77970C6FB`. The visible status changed from a no-transcript warning to a Sidecar error while the session continued recording.

This should be triaged as a runtime/Sidecar problem affecting Insight Refresh, not as a camera preview problem. The user-visible impact is that real-time speech summary becomes unavailable during a live session.

## Acceptance criteria

- [x] Runtime warmup and live ASR chunk transcription no longer reuse a Qwen MLX session on the wrong thread.
- [x] Concurrent live chunks no longer create or expose multiple conflicting Qwen MLX GPU stream owners.
- [x] Sidecar short-connection RPC calls to `asr.transcribe_chunk` do not return `There is no Stream(gpu, 2) in current thread`.
- [x] Installed app contains the Qwen MLX worker fix.
- [ ] Owner retests Live Workspace and confirms realtime speech summary no longer shows the raw GPU stream Sidecar error.

## Comments

### 2026-06-25 - Manual QA

Reported during owner-led manual QA against InsightKit build `20260625003524`.

### 2026-06-25 - Version check

The running app was verified as `/Users/yann.jy/Applications/InsightKit.app/Contents/MacOS/InsightKitApp`.

Installed bundle metadata:
- build version: `20260625003524`
- git revision: `1463cd7`
- build source: `local-workspace-clean`

The running Sidecar reported build `20260625003524`. Sidecar smoke checks passed, and `asr.runtime.status` reported `ready=true`, selected ASR engine `qwen-mlx`, and warm state `ready`.

Local older app bundles still exist:
- `dist/macos/InsightKit 3.app` - build `20260621211558`, git revision `bffae07`
- `dist/macos/InsightKit 2.app` - build `20260525160626`, git revision `277cf76`

Commits after `bffae07` are documentation/workflow changes only, so this report is unlikely to be caused by accidentally launching an Xcode Debug app or stale non-installed bundle. It may still be a regression relative to an older known-good app or to a different workflow such as packaged URL import instead of live recording.

### 2026-06-25 - Post-session manual QA evidence

The same Live Workspace session later reached a post-session/finalization state, but the top banner still showed:

`Insight 侧车错误: There is no Stream(gpu, 1) in current thread.`

The visible workspace state showed post-session finalization/review instead of active recording, Smart Minutes had no meeting content, and the transcript remained empty. The owner reported that real-time speech summary was still unresponsive rather than recovering or producing output.

This adds evidence that the issue is not limited to the moment of live recording. The failed Insight Refresh state can remain visible after the session stops and leaves the user without useful Smart Minutes or transcript output.

### 2026-06-25 - Diagnosis and fix

Diagnosed with the `diagnosing-bugs` loop.

Red/green feedback loop:

`/Users/yann.jy/miniconda3/bin/python3.11 -m pytest tests/test_qwen_mlx_thread_affinity.py -q`

Before the fix, this reproduced the same failure text:

`RuntimeError: There is no Stream(gpu, 1) in current thread.`

Root cause found: Qwen MLX sessions can own per-thread GPU stream state. Runtime warmup created and cached the Qwen MLX session on the background prewarm thread, then live ASR chunk transcription reused that cached session on a different Sidecar handling thread.

Fix applied: Qwen MLX session caching is now scoped per thread and model source, while the existing Whisper and FunASR cache behavior remains unchanged.

Verification:
- `tests/test_qwen_mlx_thread_affinity.py` - passed.
- Relevant ASR/Sidecar tests - `22 passed`.
- Full Python test suite - `209 passed, 1 warning`.
- `scripts/verify_project_normalization.py --output-root logs/diagnostics/2026-06-25/project-normalization-issue03-qwen-thread-affinity` - passed, `findings: 0`.
- `scripts/smoke_test_rpc.py` - `12 passed, 0 failed`.
- Installed app sync - success, build `20260625090217`, build source `local-workspace-dirty`.

Owner retest later showed the same class of error still reproducing, so this fix was insufficient by itself.

### 2026-06-25 - Owner retest failed on installed build

The owner retested the installed app after the Qwen MLX thread-affinity fix.

Retest build:
- app path: `/Users/yann.jy/Applications/InsightKit.app`
- build version: `20260625090217`
- git revision: `1463cd7`
- build source: `local-workspace-dirty`
- app process path: `/Users/yann.jy/Applications/InsightKit.app/Contents/MacOS/InsightKitApp`
- sidecar process path: `/Users/yann.jy/Applications/InsightKit.app/Contents/Resources/insightkit_runtime/scripts/insight_sidecar.py`

The Live Workspace still showed a Sidecar error during recording:

`Insight 侧车错误: There is no Stream(gpu, 2) in current thread.`

Visible session context:
- meeting ID: `live-E9B84874-76B6-49A1-83E1-C2F0000FC3ED`
- session phase: recording, about `00:30`
- transcript remained empty with `等待转写输入…`
- top banner still showed a no-text/noise/low-volume warning while the bottom status showed the GPU stream Sidecar error

Additional verification during the failed retest:
- running app and sidecar were confirmed to be the installed bundle, not the Xcode Debug app
- installed bundle metadata matched build `20260625090217`
- `scripts/smoke_test_rpc.py --socket-path /tmp/insightkit-app-501.sock --no-start-sidecar` passed `12 passed, 0 failed`

This keeps the issue open. The previous thread-scoped cache fix ruled out one cross-thread reuse path, but the real Live Workspace path still creates or uses MLX GPU stream state in a way that fails during live ASR chunk processing.

### 2026-06-25 - Linked issue 06 worker fix

Issue 06 found that the previous thread-scoped Qwen MLX cache created a separate heavyweight session for each Sidecar caller thread. That explains the later memory spike and can also keep surfacing GPU stream errors during live chunk processing.

Follow-up fix in `scripts/transcriber.py` replaced caller-thread session caching with a single long-lived `_QwenMLXWorker` thread per model source. All live chunk transcription now runs on the worker thread that owns the MLX session.

Installed app build `20260625094746` contains this worker fix and is ready for owner retest. This issue remains open until Live Workspace is manually retested because issue 03 is the user-visible speech-summary failure, while issue 06 is the higher-severity memory containment failure.

### 2026-06-25 - RPC regression coverage added

Continued the `diagnosing-bugs` loop for issue 03 after the issue 06 worker fix.

New red-capable loop:

`/Users/yann.jy/miniconda3/bin/python3.11 -m pytest tests/test_qwen_mlx_thread_affinity.py::test_qwen_mlx_rpc_live_chunks_do_not_return_gpu_stream_sidecar_error -q`

The loop starts a real `InsightRPCServer`, runs `asr.prewarm`, then sends concurrent short-connection `asr.transcribe_chunk` RPC calls. The fake Qwen MLX session raises the same error text if any live chunk runs outside the single GPU stream owner thread:

`There is no Stream(gpu, 2) in current thread.`

Mutation check: temporarily restoring the old caller-thread-scoped loader in memory produced `mutation_red_errors=3`, proving this loop catches the failure mode instead of only checking that the current code runs.

Current verification:
- `tests/test_qwen_mlx_thread_affinity.py` - `4 passed`.
- Related ASR/Sidecar/RPC tests - `23 passed, 1 warning`.
- Full Python pytest suite - `212 passed, 1 warning`.

No additional runtime app code change was needed beyond the Qwen MLX worker fix already installed in build `20260625094746`. The remaining gate is a short owner retest in the installed Live Workspace.
