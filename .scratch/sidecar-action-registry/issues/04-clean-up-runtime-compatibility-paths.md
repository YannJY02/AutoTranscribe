# Clean Up Runtime Compatibility Paths

Status: ready-for-human

## Parent

`.scratch/sidecar-action-registry/PRD.md`

## Stage

4 - Compatibility Cleanup

## What to build

After the registry, action boundary, and first runtime-core replacements are proven, remove or quarantine obsolete compatibility paths that now create confusion or duplicate state.

This stage should be conservative: cleanup follows proof, not the other way around.

## Product Behavior

- App-facing actions continue to work through the stable boundary.
- Obsolete handler names, duplicate capability checks, stale status paths, and old integration-only routes are removed only when covered by tests or explicitly quarantined.
- Runtime behavior becomes easier to understand without breaking current app flows.

## Acceptance Criteria

- [x] A compatibility inventory lists old handlers, method aliases, duplicate status paths, and integration-only routes.
- [x] Each cleanup item has proof that no current app flow depends on it, or a compatibility shim remains.
- [x] Cleanup does not remove the app-facing action boundary.
- [x] Deprecated paths have clear warnings or migration notes before removal where needed.
- [x] Automated tests prove Live Workspace, Import, Record Review, Record Save, transcript recovery, and Smart Minutes paths remain compatible where touched.
- [x] Packaged-app or installed-app plus sidecar proof is produced for any cleanup that touches app-used runtime methods.
- [x] Human-in-loop is only requested if a specific app behavior cannot be automated.

## Suggested Files

- `insightkit/ipc/server.py`
- `insightkit/ipc/session_handler.py`
- `insightkit/ipc/insight_coord.py`
- `insightkit/ipc/job_queue.py`
- `insightkit/ipc/record_handler.py`
- `scripts/smoke_test_rpc.py`
- `tests/test_rpc_capabilities.py`
- `tests/test_session_handler.py`

## Constraints

- Do not remove compatibility paths before replacement paths are proven.
- Do not break older short-call behavior without an accepted decision.
- Do not let cleanup expand into unrelated runtime rewrites.
- Do not mark completion without automated proof.

## Verification Plan

- Run compatibility inventory checks.
- Run focused tests for each removed or quarantined path.
- Run RPC smoke tests.
- Run packaged-app or installed-app plus sidecar proof if app-used methods are affected.
- Run `git diff --check`.
- Run `python3 scripts/verify_project_normalization.py`.
- Write a proof JSON under `logs/diagnostics/<date>/`.

## Human-In-Loop Exception

None expected unless a compatibility path is only observable through macOS permission or visual UI behavior.

## Blocked by

At least one proven Stage 3 runtime-core replacement.

## Comments

### 2026-06-29 - Codex

Created as Stage 4 of the Python runtime staged rewrite.

### 2026-06-29 - Codex

Completed the conservative Stage 4 compatibility cleanup pass.

- Added `.scratch/sidecar-action-registry/compatibility-inventory.md`.
- Added machine-readable `sidecar.compatibility_routes` and embedded the same shim inventory in `sidecar.version.compatibility_routes`.
- Quarantined legacy methods as explicit `compatibility_shim` routes: `records.save`, `asr.transcribe_media`, `transcript.replace`, and `insight.build_final`.
- Kept legacy handlers in place instead of removing them, because older app builds, local automation, and optional integration routes may still call them.
- Product action boundary remains authoritative through `sidecar.action_registry`.
- Focused proof: `logs/diagnostics/2026-06-29/runtime-compatibility-cleanup-20260629-103411/proof.json`.
- RPC socket smoke passed: `python3 scripts/smoke_test_rpc.py`.
- Installed app proof: build `20260629103615` passed packaged URL import smoke at `logs/diagnostics/2026-06-29/packaged-app-url-import-smoke-20260629-103624/proof.json`.
- Human-in-loop validation is not required for this stage because compatibility behavior is covered by focused tests, socket smoke, and installed-app smoke.
