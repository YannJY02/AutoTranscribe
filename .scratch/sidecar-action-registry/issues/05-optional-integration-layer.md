# Optional Integration Layer

Status: ready-for-human

## Parent

`.scratch/sidecar-action-registry/PRD.md`

## Stage

5 - Optional Integration Layer

## What to build

Revisit external integration only after InsightKit's own runtime action boundary is proven. External-host actions should be thin wrappers over stable InsightKit product actions, not separate runtime logic.

This stage may also decide that no integration layer is currently worth building.

## Product Behavior

- External integrations do not define or distort InsightKit's core runtime architecture.
- If an external host is revived, it calls proven product actions.
- If no external host exists, the runtime remains complete for InsightKit's own app flows.

## Acceptance Criteria

- [x] Current external integration demand is reassessed before implementation.
- [x] Any integration surface maps to existing product actions instead of introducing parallel behavior.
- [x] Integration failures cannot compromise InsightKit's own Live Workspace, Import, Record Review, transcript recovery, Smart Minutes, or Record save flows.
- [x] Optional integration code is separated from core runtime modules.
- [x] If integration is deferred, the issue records that decision and does not block runtime completion.
- [x] Automated tests cover any integration wrapper that is built.
- [x] Human-in-loop is avoided unless external account or host setup is genuinely required.

## Suggested Files

- `docs/contexts/integrations/CONTEXT.md`
- `insightkit/ipc/server.py`
- `insightkit/ipc/record_handler.py`
- `tests/test_rpc_capabilities.py`

## Constraints

- Do not build integration-first runtime behavior.
- Do not add a second source of truth for product actions.
- Do not block core runtime rewrite on a stalled external host.
- Do not mark completion without either automated proof or an explicit deferral decision.

## Verification Plan

- If implemented, run focused wrapper tests and registry/action-boundary tests.
- If deferred, record the deferral and run project normalization.
- Run `git diff --check`.
- Run `python3 scripts/verify_project_normalization.py`.

## Human-In-Loop Exception

Allowed only for external account, host installation, or credentials that cannot be automated safely.

## Blocked by

Stages 1-4 should be complete or intentionally deferred before this stage starts.

## Comments

### 2026-06-29 - Codex

Created as Stage 5 of the Python runtime staged rewrite.

### 2026-06-29 - Codex

Completed Stage 5 as a thin optional integration wrapper, not a new runtime layer.

- Reassessed external integration demand: no active external host requirement justifies new integration-first runtime behavior.
- Kept the AttentionOS Module generator as optional code outside core runtime modules.
- Updated the generated module default action to `smart_minutes.generate`.
- Added compatibility Bridge Action aliases: `records.save` -> `record.save`, `asr.transcribe_media` -> `media.transcribe_final`, `transcript.replace` -> `runtime.transcript.replace`, and `insight.build_final` -> `smart_minutes.generate`.
- Fixed the generated wrapper's Unix socket request framing so it sends newline-delimited JSON-RPC to the sidecar.
- Updated `docs/contexts/integrations/CONTEXT.md` to state that external hosts are optional and must call product actions.
- Focused proof: `logs/diagnostics/2026-06-29/optional-integration-layer-20260629-104104/proof.json`.
- Regression proof: `python3 -m pytest tests/test_attentionos_bridge.py tests/test_runtime_action_boundary.py tests/test_runtime_compatibility_cleanup.py tests/test_sidecar_action_registry.py -q`.
- Human-in-loop validation is not required because no external account, host installation, or credential setup was needed.
