# Plan and Start Runtime Core Modules Rewrite

Status: ready-for-human

## Parent

`.scratch/sidecar-action-registry/PRD.md`

## Stage

3 - Runtime Core Modules

## What to build

Plan and start the internal Python runtime rewrite behind the stable action boundary. This issue should produce a dependency-aware rewrite plan and implement the first small runtime-core slice only when the automated proof gate is clear.

Core candidates include ASR Runtime Profile, transcript store, Record Writer, Smart Minutes generation, provider probing, job queue, runtime status, and long-running work orchestration. ASR Runtime Profile is the preferred first slice unless discovery finds a higher-risk blocker.

## Product Behavior

- Runtime internals can improve without changing Swift app-facing action contracts.
- The first rewritten core slice must improve a real InsightKit product flow, not just rearrange files.
- Installed or packaged app behavior should remain provably compatible with the sidecar after the slice.
- Settings, diagnostics, and proof should agree on the same ASR runtime state when the ASR Runtime Profile slice is selected.

## Acceptance Criteria

- [x] A runtime-core dependency map identifies ASR, transcript, Record Writer, Smart Minutes, provider, job queue, status, and long-running work seams.
- [x] The first implementation slice is selected by product risk and verification value.
- [x] ASR Runtime Profile is evaluated as the default first slice before any other core module is selected.
- [x] If ASR Runtime Profile is selected, it reports configured engine, active engine, fallback/degradation, live ASR readiness, final-media ASR readiness, warm state, diarization state, technical status, and user-facing recovery hint.
- [x] If ASR Runtime Profile is selected, Apple Speech is represented as a peer ASR Engine with explicit capability and limitation reporting.
- [x] If ASR Runtime Profile is selected, Settings, diagnostics, and proof consume the same profile snapshot.
- [x] The selected slice has a small module interface and focused tests.
- [x] The selected slice runs behind the Stage 2 action boundary.
- [x] Existing app-facing action contracts remain unchanged.
- [x] Automated proof covers unit tests and at least one runtime integration path.
- [x] Key-stage proof includes packaged-app or installed-app plus sidecar end-to-end smoke where feasible.
- [x] Human-in-loop is only requested if a clearly documented behavior cannot be automated.

## Suggested Files

- `scripts/asr_runtime_profile.py`
- `scripts/asr_runtime_bootstrap.py`
- `scripts/transcription_runner.py`
- `insightkit/ipc/session_handler.py`
- `insightkit/ipc/insight_coord.py`
- `insightkit/ipc/job_queue.py`
- `insightkit/ipc/record_handler.py`
- `insightkit/data/store.py`
- `tests/test_record_writer.py`
- `tests/test_transcription_runner_local_fallback.py`
- `tests/test_job_queue.py`
- `tests/test_asr_runtime_profile.py`

## Constraints

- Do not change Swift-facing action contracts unless a new decision is accepted.
- Do not perform a broad cleanup before the replacement slice is proven.
- Do not let external integration drive core module order.
- Do not mark completion without automated proof.

## Verification Plan

- Run focused tests for the chosen core module.
- If ASR Runtime Profile is chosen, run focused tests for configured/active engine reporting, live/final-media readiness, warm state, degradation, diarization state, Apple Speech peer-engine reporting, and recovery hints.
- Run integration tests for the affected product action.
- Run a packaged-app or installed-app sidecar smoke if the slice touches runtime behavior used by the app.
- Run `git diff --check`.
- Run `python3 scripts/verify_project_normalization.py`.
- Write a proof JSON under `logs/diagnostics/<date>/`.

## Human-In-Loop Exception

Allowed only for permission-sensitive live capture, system audio, visual review quality, or other explicitly documented non-automatable behavior.

## Blocked by

Stage 1 registry and Stage 2 action boundary should be in place or included in the same controlled implementation plan.

## Comments

### 2026-06-29 - Codex

Created as Stage 3 of the Python runtime staged rewrite.

### 2026-06-29 - Codex

Completed the first Stage 3 runtime-core slice: ASR Runtime Profile.

- Added `.scratch/sidecar-action-registry/runtime-core-dependency-map.md` and selected ASR Runtime Profile first because it improves Settings, diagnostics, final-media transcription readiness, and proof with low app-facing contract churn.
- Deepened `scripts/asr_runtime_profile.py` into the shared ASR profile module. It now reports configured/active engine, live ASR readiness, final-media ASR readiness, warm state, diarization, degradation, technical status, and user-facing recovery hint.
- Kept Python-side selectable engines unchanged while representing `apple-speech` as a peer ASR Engine with explicit capability/limitation reporting.
- Wired `asr.runtime.status`, diagnostics quick check, Swift status decoding, Settings presentation, and `scripts/verify_asr_runtime_profile.py` to consume the same profile snapshot.
- Preserved existing JSON-RPC fields and app-facing action contracts. This completes the ASR status/profile slice, but does not mark issue 02's full product action contract hardening as done.
- Fixed a `LiveSessionViewModel` deinit lifecycle crash exposed by full Swift suite ordering by giving `deinit` a cleanup-only path that does not trigger asynchronous live-session finalization work.

Verification:

- `python3 -m pytest tests/test_asr_runtime_profile.py tests/test_asr_runtime_status.py tests/test_asr_engine_switch_status.py tests/test_asr_dispatcher.py tests/test_asr_prewarm_rpc.py tests/test_diagnostics_quick_check.py -q` - passed, 25 tests.
- `python3 scripts/verify_asr_runtime_profile.py` - passed; latest proof written to `logs/diagnostics/2026-06-29/asr-runtime-profile-20260629-095119/proof.json`.
- `python3 -m pytest -q` - passed, 233 tests, 1 warning.
- `python3 scripts/smoke_test_rpc.py --socket-path /tmp/insightkit-asr-profile-smoke.sock --startup-timeout-sec 10` - passed, 13 RPC methods.
- `swift test --filter ASRRuntimeStatusPresentationTests` - passed, 4 tests.
- `swift test --filter LiveSessionViewModelTests` - passed, 50 tests.
- `swift test` - passed, 240 tests.
- `bash scripts/sync_insightkit_app.sh --skip-tests --install-dir /Users/yann.jy/Applications` - passed; installed build `20260629095655`.
- `python3 scripts/run_packaged_app_url_import_smoke.py --startup-timeout-sec 45 --job-discovery-timeout-sec 45 --timeout-sec 180` - passed; proof written to `logs/diagnostics/2026-06-29/packaged-app-url-import-smoke-20260629-095710/proof.json`.
- `git diff --check` - passed.
- `python3 scripts/verify_project_normalization.py` - passed.

Human-in-loop:

No owner retest is required for this ASR Runtime Profile slice. The installed app plus sidecar smoke covers startup, URL import, transcription, final insight generation, record writing, and export proof.
