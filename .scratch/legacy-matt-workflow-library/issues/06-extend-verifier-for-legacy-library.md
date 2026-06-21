# Extend verifier for Legacy library

Status: ready-for-human

## Parent

`.scratch/legacy-matt-workflow-library/PRD.md`

## What to build

Extend the existing project-normalization verifier so the Legacy Matt Workflow Library can be checked automatically. The verifier should catch missing manifest sections, missing moved originals, missing converted assets, broken blocked-by references, and stale source-ledger references.

## Acceptance criteria

- [x] `scripts/verify_project_normalization.py` checks the Legacy Matt Workflow Library manifest.
- [x] The verifier checks moved original asset paths listed in the manifest.
- [x] The verifier checks converted asset paths listed in the manifest.
- [x] The verifier checks local issue status vocabulary and blocked-by references for this new `.scratch` lane.
- [x] Focused Python tests cover the new Legacy library checks.
- [x] The verifier produces a proof JSON with no findings when the library is consistent.

## Blocked by

- `.scratch/legacy-matt-workflow-library/issues/05-update-current-authority-references.md`

## Comments

### 2026-06-21 - Codex

Extended the project-normalization verifier to check the Legacy Matt Workflow Library.

Verification:
- `PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 -m pytest tests/test_verify_project_normalization.py -q` -> `13 passed`
- `/Users/yann.jy/miniconda3/bin/python3.11 scripts/verify_project_normalization.py --output-root logs/diagnostics/2026-06-21/project-normalization-20260621-legacy-library-final` -> `status: passed`, `findings: 0`
- Proof: `logs/diagnostics/2026-06-21/project-normalization-20260621-legacy-library-final/proof.json`
