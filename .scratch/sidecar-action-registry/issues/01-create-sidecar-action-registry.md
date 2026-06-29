# Create Sidecar Action Registry

Status: ready-for-human

## Parent

`.scratch/sidecar-action-registry/PRD.md`

## Stage

1 - Action Registry

## What to build

Create the first Sidecar Action Registry for InsightKit's app-facing runtime actions. The registry should publish product action names and current action state without requiring Swift callers to know Python handler names or infer method support.

This stage must preserve existing JSON-RPC behavior while adding the registry surface.

## Product Behavior

- Swift action clients can ask the sidecar which product actions are available, degraded, busy, unavailable, or unsupported.
- The registry describes product actions such as save Record, recover transcript, transcribe final media, replace runtime transcript, and generate Smart Minutes.
- Registry state can include short degradation reasons that help the app show clear user-facing states.
- Existing sidecar actions continue to work.

## Acceptance Criteria

- [x] A runtime-owned registry lists product action names, not Python internal function names.
- [x] Registry entries include action state: `available`, `unavailable`, `degraded`, `unsupported`, or `busy`.
- [x] Registry entries can include a concise reason or requirement when an action is not fully available.
- [x] First registry entries cover `record.save`, `transcript.recover`, `media.transcribe_final`, `runtime.transcript.replace`, and `smart_minutes.generate`.
- [x] Registry state is exposed through a stable app-facing runtime action or status field.
- [x] Existing JSON-RPC methods continue to work during this stage.
- [x] Swift callers can use registry output for capability checks without hardcoding Python handler names.
- [x] Unit or integration tests cover registry entry shape, state reporting, and missing-action behavior.
- [x] Automated proof is written to a durable diagnostics path.
- [x] Human-in-loop validation is not required for this stage unless a specific gap is documented.

## Suggested Files

- `insightkit/ipc/server.py`
- `insightkit/ipc/session_handler.py`
- `insightkit/ipc/insight_coord.py`
- `insightkit/ipc/job_queue.py`
- `insightkit/ipc/record_handler.py`
- `scripts/insight_sidecar.py`
- `tests/test_session_handler.py`
- `tests/test_rpc_capabilities.py`

## Constraints

- Preserve ADR-0001: sidecar is InsightKit's local AI runtime.
- Preserve ADR-0002: Unix socket JSON-RPC remains the app/runtime communication path.
- Do not remove existing JSON-RPC method names in this stage.
- Do not build external integration behavior here.
- Do not mark completion without automated proof.

## Verification Plan

- Run focused Python tests for registry output and action state.
- Run existing RPC capability tests.
- Run a sidecar smoke test that queries registry/capability state.
- Run `git diff --check`.
- Run `python3 scripts/verify_project_normalization.py`.
- Write a proof JSON under `logs/diagnostics/<date>/`.

## Human-In-Loop Exception

None expected.

## Blocked by

None - owner accepted the staged rewrite direction on 2026-06-29.

## Comments

### 2026-06-29 - Codex

Created as Stage 1 of the Python runtime staged rewrite.

### 2026-06-29 - Codex

Implemented Stage 1.

- Added the app-facing `sidecar.action_registry` JSON-RPC method.
- Embedded `action_registry` in `sidecar.version` while preserving the legacy `capabilities` list.
- Added registry entries for `record.save`, `transcript.recover`, `media.transcribe_final`, `runtime.transcript.replace`, and `smart_minutes.generate`.
- Added action states and concise requirements/reasons; `transcript.recover` is marked `degraded` until the dedicated recovery boundary is stabilized.
- Updated the Swift action capability provider to prefer the product action registry when present, while keeping legacy capability aliases as fallback.
- Added the registry method to the sidecar smoke test method list.

Verification:

- `python3 -m pytest tests/test_sidecar_action_registry.py tests/test_sidecar_single_instance.py -q` - passed, 5 tests.
- `python3 scripts/verify_sidecar_action_registry.py` - passed; proof written to `logs/diagnostics/2026-06-29/sidecar-action-registry-20260629-022639/proof.json`.
- `python3 -m pytest tests/test_record_e2e.py::TestRecordE2E::test_records_save_rpc_registered -q` - passed, 1 test.
- `python3 scripts/smoke_test_rpc.py --socket-path /tmp/insightkit-action-registry-smoke.sock --startup-timeout-sec 10` - passed, 13 RPC methods.
- `swift test --filter RuntimeActionClientsTests` - passed, 7 tests.
- `swift test` - passed, 223 tests.
- `git diff --check` - passed.
- `python3 scripts/verify_project_normalization.py` - passed; proof written to `logs/diagnostics/2026-06-29/project-normalization-20260629-022958/proof.json`.

Owner retest:

No human-in-loop validation is required for this stage. This adds runtime capability reporting and Swift capability consumption without changing user-visible UI behavior.
