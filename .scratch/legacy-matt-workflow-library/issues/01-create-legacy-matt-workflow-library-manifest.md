# Create Legacy Matt Workflow Library manifest

Status: ready-for-human

## Parent

`.scratch/legacy-matt-workflow-library/PRD.md`

## What to build

Create the top-level Legacy Matt Workflow Library structure and manifest. The manifest is the main index for this migration: it should explain what historical assets were moved, where the originals now live, which converted Matt workflow assets were created, and which current project documents supersede the older material.

## Acceptance criteria

- [x] `docs/Legacy/matt-workflow-library/manifest.md` exists.
- [x] The manifest explains the difference between original historical assets and converted Matt workflow assets.
- [x] The manifest names the source asset groups that will be moved or converted.
- [x] The library has clear folders for original assets and converted assets.
- [x] The manifest states that current `.scratch/`, `docs/agents/`, `docs/contexts/`, `docs/adr/`, and `CONTEXT-MAP.md` assets remain current, not Legacy.

## Blocked by

None - can start immediately.

## Comments

### 2026-06-21 - Codex

Created the Legacy Matt Workflow Library manifest and directory structure.

Verification:
- `PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 -m pytest tests/test_verify_project_normalization.py -q` -> `13 passed`
- `/Users/yann.jy/miniconda3/bin/python3.11 scripts/verify_project_normalization.py --output-root logs/diagnostics/2026-06-21/project-normalization-20260621-legacy-library-final` -> `status: passed`
- Proof: `logs/diagnostics/2026-06-21/project-normalization-20260621-legacy-library-final/proof.json`
