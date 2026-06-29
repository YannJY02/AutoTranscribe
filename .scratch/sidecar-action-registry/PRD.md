# Sidecar Action Registry and Python Runtime Staged Rewrite PRD

Status: ready-for-agent

## Problem Statement

The Python sidecar originally carried integration-facing ambitions, but InsightKit now needs it most as the app's local AI runtime. Runtime work should no longer be justified primarily by a stalled external host. It should serve InsightKit's own Live Workspace, Import, Record Review, Transcript Recovery, Smart Minutes, model readiness, long-running job, and Record-writing flows.

The current runtime can be improved in stages. The first stage should establish an app-facing Sidecar Action Registry and stable action boundary. Later stages can rewrite internal runtime modules behind that boundary while preserving installed-app behavior.

## Goal

Rewrite the Python runtime in controlled stages, from the app-facing action boundary inward. Each stage must have an automated stopping point and proof. Human-in-loop validation is an exception used only when automation cannot reasonably prove the behavior.

## User Stories

1. As a user, I want InsightKit's local AI work to stay reliable while runtime internals are improved.
2. As a user, I want the app to know when save, transcript recovery, final media transcription, runtime transcript replacement, and Smart Minutes actions are available or degraded.
3. As a user, I want runtime failures to produce recoverable app states instead of unclear sidecar errors.
4. As a future agent, I want a stable action boundary before rewriting runtime internals, so Swift app behavior does not churn with every Python change.
5. As a future agent, I want each runtime rewrite stage to leave automated proof, so progress does not depend on repeated owner retesting.
6. As a future agent, I want external integrations to be optional thin layers over InsightKit's own runtime actions, not the reason the runtime exists.

## Accepted Product Decisions

1. A full Python runtime rewrite is allowed, but it must be staged.
2. The Sidecar Action Registry is the first stage of the staged rewrite, not the final architecture.
3. Stage 1 stabilizes the external action boundary before rewriting internal implementations.
4. The rewrite proceeds from outside to inside: action boundary first, internals later.
5. The Sidecar Action Registry is the authoritative source for Swift action-client capability checks.
6. The registry names product actions, not Python internal function names.
7. The registry reports current action state, not just whether an action name exists.
8. The sidecar's primary purpose is InsightKit's local AI runtime, not an external software interface.
9. The rewrite prioritizes InsightKit core product flows; external integration is optional and secondary.
10. ADR-0001 is updated to make the local AI runtime rationale explicit.
11. The rewrite has five stages: Action Registry, Action Boundary, Runtime Core Modules, Compatibility Cleanup, Optional Integration Layer.
12. Each stage has a stopping point and proof.
13. Proof is automated by default. Human-in-loop is allowed only as a justified exception.
14. Key stages include automated packaged-app or installed-app plus sidecar end-to-end proof.
15. This lane is recorded in `.scratch/sidecar-action-registry/` as a staged rewrite PRD with phase issues.
16. ASR Runtime Profile is accepted as a priority Stage 3 runtime-core module, not as a separate `.scratch` lane.

## Rewrite Stages

1. **Action Registry**: publish a runtime-owned catalog of product actions and current availability state.
2. **Action Boundary**: stabilize the app-facing action input, output, capability, and error/degradation contracts.
3. **Runtime Core Modules**: incrementally rewrite ASR Runtime Profile, transcript, Record Writer, Smart Minutes, job queue, provider, and status modules behind the stable boundary.
4. **Compatibility Cleanup**: remove or quarantine obsolete handlers, duplicate state, legacy method aliases, and stale integration paths after the new boundary is proven.
5. **Optional Integration Layer**: expose external-host actions only as thin wrappers over proven InsightKit runtime actions.

## First Product Actions

- `record.save`
- `transcript.recover`
- `media.transcribe_final`
- `runtime.transcript.replace`
- `smart_minutes.generate`
- runtime capability/status reporting for those actions

## Priority Runtime-Core Module

`ASR Runtime Profile` is the first preferred Stage 3 core-module candidate. It should become the Python-runtime-owned source for ASR engine selection, configured engine, active engine, live ASR readiness, final-media ASR readiness, warm state, degradation/fallback reason, diarization state, technical status, and user-facing recovery hint. Settings, diagnostics, and automated proof should consume the same profile snapshot.

Apple Speech should be represented as a peer ASR Engine in the profile, with the same capability and limitation reporting as Qwen MLX, FluidAudio/LS-EEND, or other engines. It should not remain a separate experimental switch that bypasses the shared runtime profile.

## Action State Model

- `available`: the action can run now.
- `unavailable`: the action exists but cannot run in the current state.
- `degraded`: the action can run with known limits.
- `unsupported`: this runtime version does not support the action.
- `busy`: the runtime is temporarily occupied and the app should retry later.

## Automation-First Proof Policy

- Each issue must define automated verification before implementation starts.
- Stage completion requires tests or scripts that emit durable proof files.
- Key runtime stages must include packaged-app or installed-app plus sidecar end-to-end proof where feasible.
- Human-in-loop validation is reserved for behavior that automation cannot reasonably prove, such as real microphone permission, system-audio permission, visual quality judgment, or account/certificate actions.
- If a stage lacks automated proof, it should not be marked complete.

## Implementation Decisions

- Keep the existing sidecar running while the new registry and boundary are introduced.
- Do not break current JSON-RPC compatibility during Stage 1.
- Prefer product action names and product outcome states over internal handler names.
- Let Swift action-specific clients consume registry state instead of guessing method support.
- Treat external integration as a late optional layer, not a core runtime dependency.
- Keep each runtime rewrite slice small enough to verify automatically and stop cleanly.

## Out of Scope

- One-shot full runtime replacement without intermediate proof.
- Letting external integration requirements drive the core runtime design.
- Replacing the native Swift app.
- Replacing Unix socket JSON-RPC before the action boundary is stable.
- Public distribution, signing, notarization, App Store, or privacy work.

## Testing Decisions

- Stage 1 should add registry unit tests and protocol-shape tests.
- Stage 2 should add contract tests for action inputs, outputs, capability states, and error/degradation mapping.
- Runtime-core stages should add focused module tests plus integration tests for the touched product flow.
- Key stages should run packaged-app or installed-app smoke proof against the sidecar.
- Every stage should run `git diff --check` and `python3 scripts/verify_project_normalization.py`.

## Published Issues

- `.scratch/sidecar-action-registry/issues/01-create-sidecar-action-registry.md`
- `.scratch/sidecar-action-registry/issues/02-stabilize-runtime-action-boundary.md`
- `.scratch/sidecar-action-registry/issues/03-plan-and-start-runtime-core-modules-rewrite.md`
- `.scratch/sidecar-action-registry/issues/04-clean-up-runtime-compatibility-paths.md`
- `.scratch/sidecar-action-registry/issues/05-optional-integration-layer.md`

## Comments

### 2026-06-29 - Codex

Published after owner reframed the Sidecar Action Registry candidate as a staged Python runtime rewrite, with automation-first proof and human-in-loop only as a justified exception.

### 2026-06-29 - Codex

Completed Stage 1 issue `01-create-sidecar-action-registry`.

- The sidecar now publishes `sidecar.action_registry` and embeds the same registry in `sidecar.version`.
- Existing JSON-RPC methods and legacy capability reporting are preserved.
- Swift action seams now prefer registry product actions for capability checks, with legacy aliases as fallback.
- Durable proof: `logs/diagnostics/2026-06-29/sidecar-action-registry-20260629-022639/proof.json`.
- No owner retest is required because this stage does not change visible app behavior.

The staged rewrite remains ready for later issues, but the accepted implementation order moves next to the Canonical Meeting Asset Source lane.

### 2026-06-29 - Codex

Completed Stage 3's first runtime-core slice in issue `03-plan-and-start-runtime-core-modules-rewrite`.

- Added the runtime-core dependency map and stopped after the ASR Runtime Profile slice.
- The shared ASR profile now backs `asr.runtime.status`, diagnostics, Swift Settings presentation, and automated proof.
- Apple Speech is represented as a peer ASR Engine with explicit limits, while Python-side selectable engines remain unchanged.
- Installed app build `20260629095655` passed packaged URL import smoke with sidecar proof at `logs/diagnostics/2026-06-29/packaged-app-url-import-smoke-20260629-095710/proof.json`.
- Full Swift test suite now passes after fixing a deinit-only LiveSession lifecycle cleanup path.

The staged rewrite should continue with issue `02-stabilize-runtime-action-boundary` before Stage 4 compatibility cleanup. The ASR profile slice preserved app-facing contracts, but issue 02's product action input/output/error contracts are still not fully hardened.

### 2026-06-29 - Codex

Completed Stage 2 issue `02-stabilize-runtime-action-boundary`.

- The first product action batch is now directly dispatchable through stable action names: `record.save`, `transcript.recover`, `media.transcribe_final`, `runtime.transcript.replace`, and `smart_minutes.generate`.
- Legacy JSON-RPC methods remain as compatibility paths, but Swift app calls now prefer product action names where wired.
- `transcript.recover` now has a sidecar-level contract for returning recovered segments and optionally replacing the runtime transcript by `meeting_id`.
- Contract proof: `logs/diagnostics/2026-06-29/runtime-action-boundary-20260629-102739/proof.json`.
- Installed app proof: build `20260629102853` passed packaged URL import smoke at `logs/diagnostics/2026-06-29/packaged-app-url-import-smoke-20260629-102903/proof.json`.

The staged rewrite can now proceed to issue `04-clean-up-runtime-compatibility-paths` conservatively: inventory first, quarantine or remove only paths proven unused by current app flows.

### 2026-06-29 - Codex

Completed Stage 4 issue `04-clean-up-runtime-compatibility-paths`.

- Added the compatibility inventory at `.scratch/sidecar-action-registry/compatibility-inventory.md`.
- Published `sidecar.compatibility_routes` and embedded compatibility metadata in `sidecar.version`.
- Quarantined `records.save`, `asr.transcribe_media`, `transcript.replace`, and `insight.build_final` as explicit compatibility shims with product-action replacements.
- No legacy handler was removed in this pass; the cleanup outcome is an auditable quarantine rather than a breaking removal.
- Compatibility proof: `logs/diagnostics/2026-06-29/runtime-compatibility-cleanup-20260629-103411/proof.json`.
- Installed app proof: build `20260629103615` passed packaged URL import smoke at `logs/diagnostics/2026-06-29/packaged-app-url-import-smoke-20260629-103624/proof.json`.

The remaining staged rewrite issue is `05-optional-integration-layer`, which should keep external-host integration as a thin layer over the proven InsightKit product actions.

### 2026-06-29 - Codex

Completed Stage 5 issue `05-optional-integration-layer`.

- Reassessed external integration demand and did not add a new integration-first runtime layer.
- Kept the AttentionOS Module generator as optional code outside core runtime modules.
- Updated generated Host Calls to default to `smart_minutes.generate`.
- Added compatibility aliases from older Bridge Actions to product actions.
- Optional integration proof: `logs/diagnostics/2026-06-29/optional-integration-layer-20260629-104104/proof.json`.

All published Sidecar Action Registry staged rewrite issues are now completed and awaiting human review. Future runtime-core rewrites can be opened as new focused Stage 3 slices behind the stabilized product action boundary.
