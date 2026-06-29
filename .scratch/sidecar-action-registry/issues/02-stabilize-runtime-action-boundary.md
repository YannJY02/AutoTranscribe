# Stabilize Runtime Action Boundary

Status: ready-for-human

## Parent

`.scratch/sidecar-action-registry/PRD.md`

## Stage

2 - Action Boundary

## What to build

Define and test the app-facing contracts for the first runtime product actions. Each action should have a stable product name, input shape, output shape, capability/degradation behavior, and product-level error meaning.

This stage can reuse existing internal implementations, but the boundary Swift depends on should become stable.

## Product Behavior

- Swift action-specific clients call product actions instead of broad low-level runtime methods.
- Runtime responses distinguish success, unavailable, degraded, busy, retryable failure, incomplete input, and technical failure where relevant.
- App-facing action contracts remain stable even if the Python internals change later.

## Acceptance Criteria

- [x] Contract docs or tests define input and output shapes for the first action batch.
- [x] `record.save` contract covers successful save, invalid input, write failure, and record-path result.
- [x] `transcript.recover` contract covers missing media, successful transcript, retryable runtime failure, and write failure.
- [x] `media.transcribe_final` contract covers media input, transcript segments, ASR unavailable, and runtime busy.
- [x] `runtime.transcript.replace` contract covers successful replacement, unsupported runtime, and invalid segment input.
- [x] `smart_minutes.generate` contract covers generated Insight Package, provider unavailable, insufficient transcript, and retryable failure.
- [x] Boundary tests can run without a full installed-app session.
- [x] Existing internal handlers may be reused behind the boundary.
- [x] Automated proof is written to a durable diagnostics path.
- [x] Human-in-loop validation is not required for this stage unless a specific gap is documented.

## Suggested Files

- `insightkit/ipc/server.py`
- `insightkit/ipc/session_handler.py`
- `insightkit/ipc/insight_coord.py`
- `insightkit/ipc/job_queue.py`
- `insightkit/ipc/record_handler.py`
- `tests/test_session_handler.py`
- `tests/test_record_save_action.py`
- `tests/test_transcription_import_rpc.py`
- `tests/test_rpc_capabilities.py`

## Constraints

- Preserve existing runtime methods as compatibility paths while the boundary stabilizes.
- Do not rewrite every runtime module in this stage.
- Keep external integration secondary.
- Do not mark completion without automated proof.

## Verification Plan

- Run focused contract tests for each first-batch product action.
- Run existing RPC and record-save tests touched by the boundary.
- Run `git diff --check`.
- Run `python3 scripts/verify_project_normalization.py`.
- Write a proof JSON under `logs/diagnostics/<date>/`.

## Human-In-Loop Exception

None expected unless a contract can only be proven through macOS permission behavior.

## Blocked by

Stage 1 registry should exist or be implemented in the same controlled pass.

## Comments

### 2026-06-29 - Codex

Created as Stage 2 of the Python runtime staged rewrite.

### 2026-06-29 - Codex

Completed Stage 2 action boundary hardening.

- Product action names are now directly dispatchable by the sidecar: `record.save`, `transcript.recover`, `media.transcribe_final`, `runtime.transcript.replace`, and `smart_minutes.generate`.
- Swift RPC calls now prefer product action names for Record Save, final media transcription, runtime transcript replacement, and Smart Minutes, with legacy method fallback only for older sidecars.
- `transcript.recover` can return recovered media-timed segments and, when given a `meeting_id`, write them back into the runtime transcript store.
- Contract tests cover success, invalid input, unavailable/degraded/busy/retryable paths, write failure, unsupported runtime transcript replacement, insufficient transcript, and provider fallback.
- Focused proof: `logs/diagnostics/2026-06-29/runtime-action-boundary-20260629-102739/proof.json`.
- Installed app proof: build `20260629102853` passed packaged URL import smoke at `logs/diagnostics/2026-06-29/packaged-app-url-import-smoke-20260629-102903/proof.json`.
- Human-in-loop validation is not required for this stage because the changed boundary is covered by contract tests and installed-app smoke.
