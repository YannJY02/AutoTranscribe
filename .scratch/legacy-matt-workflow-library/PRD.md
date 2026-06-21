# Legacy Matt Workflow Library PRD

Status: ready-for-human

## Problem Statement

InsightKit now has current Matt workflow assets under `.scratch/`, `docs/agents/`, `CONTEXT-MAP.md`, `docs/contexts/`, and `docs/adr/`, but older planning, release, architecture, and product-reference files still sit in mixed locations. Future agents can confuse those historical assets with current source-of-truth docs, especially when stale plans under `docs/plans/` look authoritative or when release evidence is referenced from a historical location.

The project owner wants a more complete Matt-style file framework library: historical assets should be converted into workflow-aware assets, original historical files should move into Legacy, and current repo entry points should still route future agents to the right authority without breaking release or architecture references.

## Solution

Create a `docs/Legacy/matt-workflow-library/` library that preserves original historical assets, adds converted Matt workflow views over them, and exposes a manifest as the top-level verification seam.

The library should move historical originals into `original-assets/`, convert them into PRD-like, issue-like, source-ledger, proof-index, and decision-reference assets, and keep current authority surfaces pointing to the new Legacy locations. The current `.scratch/project-normalization` and `.scratch/live-workspace-session` lanes remain active current Matt workflow assets and are not moved into Legacy.

The implementation should extend the existing project-normalization verifier so the migration is mechanically checkable: moved paths, manifest entries, converted assets, issue status vocabulary, blocked-by references, and current source-ledger references must all stay consistent.

## User Stories

1. As the project owner, I want historical planning files moved into Legacy, so that current docs do not look like stale active work.
2. As the project owner, I want historical files preserved rather than rewritten in place, so that past evidence and rationale remain auditable.
3. As a future agent, I want a single Legacy Matt Workflow Library manifest, so that I can understand what was moved, what was converted, and which current source supersedes each asset.
4. As a future agent, I want older phase plans converted into PRD-like and issue-like records, so that I can read them using the same Matt workflow framework as current work.
5. As a future agent, I want release evidence moved without losing proof references, so that Local Release Ready and Distribution Ready claims stay separated.
6. As a future agent, I want architecture history moved without weakening accepted ADRs, so that hard-to-reverse decisions still defer to `docs/adr/`.
7. As a future agent, I want Legacy product rationale to remain historical, so that `InsightKit` current language is not overwritten by Feishu Minutes or AutoTranscribe-era language.
8. As a release maintainer, I want current release workflow context to point to the moved release ledgers, so that release checks do not silently depend on stale paths.
9. As a release maintainer, I want release evidence converted into a proof index, so that proof paths and external blockers remain explicit.
10. As an implementation agent, I want the migration verified by a script, so that file moves and reference rewrites are not trusted by visual inspection.
11. As an implementation agent, I want the migration split into narrow issues, so that each slice can be verified and recorded independently.
12. As a reviewer, I want the final state recorded in `.scratch/legacy-matt-workflow-library/`, so that the conversion itself has a Matt workflow audit trail.
13. As a future agent, I want current `.scratch/` PRDs and issues to remain active, so that completed current work is not incorrectly archived as Legacy.
14. As a future agent, I want original assets and converted assets separated, so that provenance is clear.
15. As the project owner, I want a library that approximates Matt's workflow file framework, so that historical project knowledge can be reused by agents without rereading every old plan.

## Implementation Decisions

- Use `docs/Legacy/matt-workflow-library/manifest.md` as the highest-level verification seam.
- Move original historical assets into `docs/Legacy/matt-workflow-library/original-assets/`, preserving enough path information to maintain provenance.
- Keep current Matt workflow assets in place: `.scratch/project-normalization/`, `.scratch/live-workspace-session/`, `docs/agents/`, `docs/contexts/`, `docs/adr/`, and `CONTEXT-MAP.md`.
- Treat older phase plans as historical workflow assets, not active issues.
- After owner review, keep historical implementation plans as Legacy-only unless a future agent creates a fresh `.scratch` issue from current code and proof.
- Treat release-readiness ledgers as moved historical/current-evidence references: they may live under Legacy, but current release context and source ledger must point to the new locations.
- After owner review, keep historical release proof/status ledgers as Legacy release history; current release claims must come from fresh verifier output and fresh `proof.json`.
- Convert historical materials into reader-facing Matt workflow assets rather than opaque archive bundles.
- Prefer one manifest plus one verifier extension over many unverified local conventions.
- Preserve accepted ADR authority; converted architecture notes must link to ADRs rather than replace them.
- After owner review, keep the historical architecture reference as Legacy architecture reference; future architecture work must start from current code, accepted ADRs, context docs, and the architecture handoff.
- Do not claim release readiness or distribution readiness as part of this conversion.
- Do not delete logs, proof JSON, screenshots, images, PDFs, or historical source material.

## Testing Decisions

- The primary gate is `scripts/verify_project_normalization.py`, extended to validate the Legacy Matt Workflow Library.
- The verifier should check the manifest, original-assets path references, converted asset presence, status vocabulary, blocked-by references, and updated source-ledger links.
- Focused verifier tests should be added before or with the verifier extension.
- `git diff --check` should pass after file moves and markdown edits.
- Release Closure Gate is out of scope unless release-readiness claims are changed.

## Out of Scope

- Moving or archiving current `.scratch/project-normalization` or `.scratch/live-workspace-session` work.
- Rewriting accepted ADRs.
- Changing product behavior, Python runtime behavior, macOS app behavior, release readiness behavior, signing, notarization, App Store Connect, privacy URL, or credentials.
- Deleting historical assets.
- Reclassifying Local Release Ready as Distribution Ready.
- Running packaged-app smoke or Visual GUI Proof for a documentation/library conversion.

## Further Notes

Confirmed seam with the project owner:
- Highest seam: Legacy Matt Workflow Library manifest.
- Current control PRD and issues remain under `.scratch/legacy-matt-workflow-library/`.
- Converted library output lives under `docs/Legacy/matt-workflow-library/`.
- Original historical files should actually move into Legacy, but current authority references must be rewritten so future agents are not misled by broken paths or stale release evidence.
- Historical release/privacy drafts can still create current `.scratch` work after owner review; the first promoted lane is `.scratch/public-distribution-readiness/`.

## Comments

### 2026-06-21 - Codex

Completed the Legacy Matt Workflow Library migration to `ready-for-human`.

Changed:
- Created `docs/Legacy/matt-workflow-library/manifest.md` as the top-level library index.
- Moved historical originals into `docs/Legacy/matt-workflow-library/original-assets/`.
- Added converted Matt workflow assets under `docs/Legacy/matt-workflow-library/converted-assets/`.
- Updated current references in README, source ledger, architecture handoff, and release scripts.
- Extended `scripts/verify_project_normalization.py` to verify the Legacy library structure.

Verification:
- `PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 -m pytest tests/test_verify_project_normalization.py -q` -> `13 passed`
- `PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 -m pytest tests/test_verify_goal_evidence_script.py tests/test_verify_release_readiness_script.py tests/test_verify_release_closure_script.py -q` -> `18 passed`
- `bash -n scripts/release_preflight.sh` -> passed
- `/Users/yann.jy/miniconda3/bin/python3.11 scripts/verify_project_normalization.py --output-root logs/diagnostics/2026-06-21/project-normalization-20260621-legacy-library-final` -> `status: passed`
- Proof: `logs/diagnostics/2026-06-21/project-normalization-20260621-legacy-library-final/proof.json`
- `git diff --check` -> passed

Release boundary:
- No Local Release Ready or Distribution Ready claim was changed.
- Release Closure Gate was not rerun because this was a documentation/library migration, not a release-readiness change.

### 2026-06-21 - Codex

Integrated the Legacy Matt Workflow Library into the standard Matt setup surfaces.

Changed:
- Added the Legacy workflow library entry to `AGENTS.md`.
- Updated `docs/agents/issue-tracker.md` so historical issue-style files are not mistaken for active `.scratch` issues.
- Updated `docs/agents/triage-labels.md` so triage labels apply only to current issue files.
- Updated `docs/agents/domain.md` with rules for promoting historical material into context terms, ADRs, current PRDs/issues, proof indexes, owner-input checklists, or Legacy reference.
- Updated `docs/agents/loop-engineering.md` with a Legacy Asset Promotion Route.

Verification:
- `PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 -m pytest tests/test_verify_project_normalization.py -q` -> `14 passed`
- `/Users/yann.jy/miniconda3/bin/python3.11 scripts/verify_project_normalization.py --output-root logs/diagnostics/2026-06-21/project-normalization-20260621-legacy-standard-integration` -> `status: passed`, `legacy_standard_setup_docs: 5`, `findings: 0`
- Proof: `logs/diagnostics/2026-06-21/project-normalization-20260621-legacy-standard-integration/proof.json`

### 2026-06-21 - Codex

Completed the content-level promotion pass requested by the project owner.

Changed:
- Read and classified each moved historical original.
- Promoted still-valid concepts into current context docs.
- Expanded ADRs for native app plus sidecar, persistent RPC, release readiness boundaries, and local Record Folders.
- Added `docs/Legacy/matt-workflow-library/converted-assets/planning/content-promotion-audit.md` as the per-original decision record.
- Updated the manifest, source ledger, architecture handoff, verifier, and verifier tests so this promotion remains machine-checkable.

Current issue:
- `.scratch/legacy-matt-workflow-library/issues/09-promote-historical-content-into-standard-assets.md` -> `ready-for-human`

Verification:
- `PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 -m pytest tests/test_verify_project_normalization.py -q` -> `15 passed`
- `/Users/yann.jy/miniconda3/bin/python3.11 scripts/verify_project_normalization.py --output-root logs/diagnostics/2026-06-21/project-normalization-20260621-legacy-content-promotion-final` -> `status: passed`, `findings: 0`
- `git diff --check` -> passed
- Proof: `logs/diagnostics/2026-06-21/project-normalization-20260621-legacy-content-promotion-final/proof.json`

### 2026-06-21 - Codex

After owner review during the remaining-Legacy grilling pass, promoted the privacy/sandbox and App Store privacy-answer drafts into a current owner-controlled lane.

Added:
- `.scratch/public-distribution-readiness/PRD.md`
- `.scratch/public-distribution-readiness/issues/01-confirm-release-channel-and-cloud-provider-boundary.md`
- `.scratch/public-distribution-readiness/issues/02-prepare-public-privacy-policy-url.md`
- `.scratch/public-distribution-readiness/issues/03-finalize-app-store-privacy-answers.md`
- `.scratch/public-distribution-readiness/issues/04-run-developer-id-distribution-preflight.md`
- `.scratch/public-distribution-readiness/issues/05-run-app-store-sandbox-distribution-preflight.md`

### 2026-06-21 - Codex

After owner approval, converted the historical product images and example PDF into a privacy-safe output structure reference instead of using the originals as fixtures.

Added:
- `docs/Legacy/matt-workflow-library/converted-assets/product/reference-output-patterns.md`

Verification:
- `PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 -m pytest tests/test_verify_project_normalization.py -q` -> `15 passed`
- `/Users/yann.jy/miniconda3/bin/python3.11 scripts/verify_project_normalization.py --output-root logs/diagnostics/2026-06-21/project-normalization-20260621-reference-output-patterns` -> `status: passed`, `legacy_converted_assets: 8`, `findings: 0`
- Proof: `logs/diagnostics/2026-06-21/project-normalization-20260621-reference-output-patterns/proof.json`
- `git diff --check` -> passed

### 2026-06-21 - Codex

After owner approval, confirmed historical implementation plans remain Legacy-only. No current issue was created from the old March phase plans, March live-summary diagnosis, or May local ASR model-upgrade note.

Verification:
- `PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 -m pytest tests/test_verify_project_normalization.py -q` -> `15 passed`
- `/Users/yann.jy/miniconda3/bin/python3.11 scripts/verify_project_normalization.py --output-root logs/diagnostics/2026-06-21/project-normalization-20260621-implementation-plans-legacy-only` -> `status: passed`, `findings: 0`
- Proof: `logs/diagnostics/2026-06-21/project-normalization-20260621-implementation-plans-legacy-only/proof.json`
- `git diff --check` -> passed

### 2026-06-21 - Codex

After owner approval, confirmed historical release proof/status ledgers remain Legacy release history. No current issue was created from the old May goal-evidence, release-verification, or release-readiness status ledgers.

Verification:
- `PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 -m pytest tests/test_verify_project_normalization.py -q` -> `15 passed`
- `/Users/yann.jy/miniconda3/bin/python3.11 scripts/verify_project_normalization.py --output-root logs/diagnostics/2026-06-21/project-normalization-20260621-release-ledgers-legacy-history` -> `status: passed`, `findings: 0`
- Proof: `logs/diagnostics/2026-06-21/project-normalization-20260621-release-ledgers-legacy-history/proof.json`
- `git diff --check` -> passed

### 2026-06-21 - Codex

After owner approval, confirmed the historical architecture reference remains Legacy architecture reference. No new ADR or current issue was created from `original-assets/docs/architecture/insightkit-architecture.md`.

Verification:
- `PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 -m pytest tests/test_verify_project_normalization.py -q` -> `15 passed`
- `/Users/yann.jy/miniconda3/bin/python3.11 scripts/verify_project_normalization.py --output-root logs/diagnostics/2026-06-21/project-normalization-20260621-architecture-reference-legacy` -> `status: passed`, `findings: 0`
- Proof: `logs/diagnostics/2026-06-21/project-normalization-20260621-architecture-reference-legacy/proof.json`
- `git diff --check` -> passed

### 2026-06-21 - Codex

Completed the Legacy conversion closure review.

Result:
- No unclassified moved originals remain.
- `manifest.md` and `content-promotion-audit.md` both cover 21 moved original assets.
- The verifier checks 8 converted Legacy assets and 6 current public-distribution assets.

Verification:
- `PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 -m pytest tests/test_verify_project_normalization.py -q` -> `15 passed`
- `/Users/yann.jy/miniconda3/bin/python3.11 scripts/verify_project_normalization.py --output-root logs/diagnostics/2026-06-21/project-normalization-20260621-legacy-conversion-closure` -> `status: passed`, `legacy_original_assets: 21`, `legacy_converted_assets: 8`, `public_distribution_readiness_assets: 6`, `findings: 0`
- Proof: `logs/diagnostics/2026-06-21/project-normalization-20260621-legacy-conversion-closure/proof.json`
- `git diff --check` -> passed
