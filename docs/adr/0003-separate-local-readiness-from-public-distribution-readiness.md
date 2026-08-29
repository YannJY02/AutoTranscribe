# Separate local readiness from public distribution readiness

Status: accepted

## Context

Historical release ledgers mixed real local product evidence with public distribution blockers. InsightKit can be locally useful and locally verifiable before the owner has supplied Apple account access, Developer ID certificates, notarization credentials, App Store Connect metadata, sandbox proof, or a public privacy URL.

## Decision

Release claims distinguish local/internal QA readiness from Developer ID or App Store distribution readiness. Local Release Ready is a repo-verifiable claim about the installed app and its app-owned runtime on the current Mac. Distribution Ready is a channel-specific public release claim that depends on Developer ID or App Store requirements.

ADR 0008 supersedes the former `.scratch/public-distribution-readiness/` tracking location: current public-distribution work is tracked in Linear with synchronized GitHub execution issues. Retained `.scratch` files and the moved privacy and App Store drafts under `docs/Legacy/matt-workflow-library/original-assets/docs/release/` remain provenance and review inputs, not the active work queue.

## Consequences

- A passing Local Preflight, Packaged-App Smoke, Visual GUI Proof, Secret Hygiene Gate, or UI Hygiene Gate can support Local Release Ready without implying public distribution readiness.
- Developer ID Preflight and App Store Preflight failures are External Blockers when they require owner-controlled Apple credentials, certificates, notarization setup, App Store metadata, sandbox distribution identity, or privacy URL work.
- Privacy drafts and App Store privacy answers are Privacy Review Inputs until reviewed and published by the owner.
- Public-distribution tasks should reference their current Linear issues and synchronized GitHub execution records rather than treating retained `.scratch` files or Legacy drafts as live instructions.
- Architecture work may improve evidence quality or packaging reliability, but it should not relabel Apple-owned release requirements as code bugs.
