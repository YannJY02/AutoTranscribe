# Move historical originals into Legacy library

Status: ready-for-human

## Parent

`.scratch/legacy-matt-workflow-library/PRD.md`

## What to build

Move historical planning, release-note, privacy, architecture-reference, and product-reference originals into the Legacy Matt Workflow Library while preserving provenance. This should be a real move of historical originals, not only a copied summary, but it must avoid moving current Matt control surfaces.

## Acceptance criteria

- [x] Historical originals move under `docs/Legacy/matt-workflow-library/original-assets/`.
- [x] The original asset layout preserves enough path context to tell where each file came from.
- [x] Current `.scratch/project-normalization` and `.scratch/live-workspace-session` files remain in place.
- [x] Current `docs/agents/`, `docs/contexts/`, `docs/adr/`, and `CONTEXT-MAP.md` files remain in place.
- [x] The manifest is updated with moved source paths and new Legacy paths.
- [x] No historical assets are deleted.

## Blocked by

- `.scratch/legacy-matt-workflow-library/issues/01-create-legacy-matt-workflow-library-manifest.md`

## Comments

### 2026-06-21 - Codex

Moved 21 historical originals into the Legacy library while leaving current Matt control surfaces in place.

Verification:
- `/Users/yann.jy/miniconda3/bin/python3.11 scripts/verify_project_normalization.py --output-root logs/diagnostics/2026-06-21/project-normalization-20260621-legacy-library-final` -> `legacy_original_assets: 21`, `findings: 0`
- Proof: `logs/diagnostics/2026-06-21/project-normalization-20260621-legacy-library-final/proof.json`
