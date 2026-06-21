# Update current authority references

Status: ready-for-human

## Parent

`.scratch/legacy-matt-workflow-library/PRD.md`

## What to build

Update current project entry points so future agents can still find the moved Legacy assets without treating them as active authority. Current source ledgers and context documents should point to the new Legacy paths and clarify which current docs override historical material.

## Acceptance criteria

- [x] `docs/project-normalization-source-ledger.md` points to moved Legacy library paths instead of stale historical paths.
- [x] Release workflow context points to the moved release evidence library where needed.
- [x] Architecture handoff points to moved historical architecture references where needed.
- [x] Current context and ADR authority remains unchanged.
- [x] No current release or architecture claim is weakened by a broken link.
- [x] The manifest and current source ledger agree about which assets are historical and which are current.

## Blocked by

- `.scratch/legacy-matt-workflow-library/issues/03-convert-historical-plans-into-matt-workflow-assets.md`
- `.scratch/legacy-matt-workflow-library/issues/04-convert-release-evidence-into-proof-index-assets.md`

## Comments

### 2026-06-21 - Codex

Updated current references in README, source ledger, architecture handoff, and release scripts to use the moved Legacy library paths.

Verification:
- `PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 -m pytest tests/test_verify_project_normalization.py -q` -> `13 passed`
- `PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 -m pytest tests/test_verify_goal_evidence_script.py tests/test_verify_release_readiness_script.py tests/test_verify_release_closure_script.py -q` -> `18 passed`
- Proof: `logs/diagnostics/2026-06-21/project-normalization-20260621-legacy-library-final/proof.json`
