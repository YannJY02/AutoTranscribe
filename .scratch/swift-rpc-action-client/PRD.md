# Swift RPC Action Client PRD

Status: ready-for-agent

## Problem Statement

The Swift app still tends to depend on a broad runtime client surface. When a feature needs one user action, it can still see many unrelated runtime actions, method names, low-level error shapes, and capability checks. That keeps modules shallow: UI and workflow modules must know too much about JSON-RPC details to do one product job.

This lane defines action-specific Swift RPC entrypoints for new and refactored paths. Each action exposes a small product-named interface, owns the rules needed for that action, returns product-level outcomes, and hides lower-level RPC mechanics behind a shared adapter.

## Goal

New architecture slices should depend on small action-specific runtime entrypoints instead of a broad RPC client. The first slice supports Live Session Finalization, Transcript Recovery, Record Save, Final Media Transcription, Runtime Transcript Replacement, and Smart Minutes Generation without rewriting the entire RPC layer.

## User Stories

1. As a user, I want runtime failures to produce clear app states and next actions, not technical RPC messages.
2. As a user, I want recovery, saving, and Smart Minutes generation to behave consistently across Live Workspace and Record Review.
3. As a future agent, I want each module to depend only on the runtime action it needs, so changes stay local.
4. As a future agent, I want capability checks close to the action, so UI code does not duplicate method-support logic.
5. As a future agent, I want action outcomes to be testable without constructing the whole app or exposing every RPC method.

## Accepted Product Decisions

1. New functions should prefer small action-specific RPC entrypoints over one broad RPC client.
2. The first slice constrains only new or refactored paths; it does not migrate all existing RPC calls.
3. Action entrypoints should be named after product actions, not low-level RPC method names.
4. Action entrypoints should return product-level outcomes instead of exposing raw RPC errors to UI modules.
5. Action entrypoints should own capability checks for their action.
6. Action entrypoints must contain real rules and test value; they should not be thin pass-through wrappers.
7. The first batch contains five action seams: Record Save Action, Transcript Recovery Action, Final Media Transcription Action, Runtime Transcript Replacement Action, and Smart Minutes Generation Action.
8. Multiple action seams may share the same low-level RPC client adapter internally.
9. Business modules should receive action seams as dependencies; UI should not call the low-level RPC client directly for these paths.
10. This lane is recorded in `.scratch/swift-rpc-action-client/` before implementation.

## First Action Seams

- `Record Save Action`: persists the official Record through the runtime Record Save Action.
- `Transcript Recovery Action`: regenerates a missing or stale official transcript from saved media.
- `Final Media Transcription Action`: creates a media-timed transcript from final review media after capture stops.
- `Runtime Transcript Replacement Action`: updates the runtime transcript store with official media-timed segments.
- `Smart Minutes Generation Action`: generates or regenerates the official Insight Package for a saved Record or session.

## Implementation Decisions

- Keep the existing broad RPC client and protocol available for legacy paths.
- Create small Swift module seams for the first action batch.
- Each action seam should validate inputs, check capability, map parameters, call the shared low-level adapter, translate errors into product outcomes, and expose useful diagnostics hooks.
- Action seams should be injected into Live Session Finalization, Transcript Recovery, and future meeting-asset modules rather than called directly from UI views.
- Product outcomes should distinguish success, retryable failure, unavailable capability, incomplete Record, missing media, and technical failure where relevant.
- Do not duplicate socket or JSON-RPC transport code across action seams.

## Out of Scope

- Replacing the entire `InsightRPCClientProtocol`.
- Migrating every existing Swift RPC call.
- Replacing the Python Sidecar or Unix socket JSON-RPC.
- Changing runtime method names in this slice unless required for a chosen action.
- Reworking public distribution, signing, notarization, App Store, or privacy behavior.

## Testing Decisions

- Add focused Swift tests for action outcome mapping, capability checks, input validation, and low-level error translation.
- Add tests proving business modules can use fake action seams without constructing the full RPC client.
- Keep legacy RPC tests intact.
- Run broader Swift tests only when touched surface expands beyond the first action seams.
- Run project normalization after publishing or updating this lane.

## Published Issues

- `.scratch/swift-rpc-action-client/issues/01-create-action-specific-rpc-seams.md`

## Comments

### 2026-06-29 - Codex

Published after owner accepted the Swift RPC Action Client architecture decisions.

### 2026-06-29 - Codex

Issue 01 completed the first internal action-seam slice and moved to `ready-for-human`. No owner retest is required until later issues wire the seams into new user-visible recovery, save, or Smart Minutes flows.
