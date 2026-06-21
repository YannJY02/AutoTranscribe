# Convert historical plans into Matt workflow assets

Status: ready-for-human

## Parent

`.scratch/legacy-matt-workflow-library/PRD.md`

## What to build

Convert the moved historical phase plans, local ASR upgrade notes, architecture notes, and historical product overview into reader-facing Matt workflow assets. The converted assets should make old work understandable as goals, decisions, issue-style slices, proof needs, and current superseding sources.

## Acceptance criteria

- [x] Converted planning assets exist under the Legacy Matt Workflow Library.
- [x] Older phase plans are represented as PRD-like or issue-like historical records.
- [x] The historical product overview is represented as product rationale, not a current implementation spec.
- [x] Architecture history points to accepted ADRs when current decisions supersede older plans.
- [x] Converted assets use current InsightKit vocabulary where they explain present meaning, while preserving old terms as historical source language.
- [x] The manifest links each converted planning asset back to its moved original.

## Blocked by

- `.scratch/legacy-matt-workflow-library/issues/02-move-historical-originals-into-legacy-library.md`

## Comments

### 2026-06-21 - Codex

Converted historical product, planning, and architecture materials into Matt workflow-readable assets.

Verification:
- `/Users/yann.jy/miniconda3/bin/python3.11 scripts/verify_project_normalization.py --output-root logs/diagnostics/2026-06-21/project-normalization-20260621-legacy-library-final` -> `legacy_converted_assets: 6`, `findings: 0`
- Proof: `logs/diagnostics/2026-06-21/project-normalization-20260621-legacy-library-final/proof.json`
