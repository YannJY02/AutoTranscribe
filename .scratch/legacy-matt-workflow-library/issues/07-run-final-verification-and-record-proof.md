# Run final verification and record proof

Status: ready-for-human

## Parent

`.scratch/legacy-matt-workflow-library/PRD.md`

## What to build

Run the final verification loop for the Legacy Matt Workflow Library and record the result back into the PRD and issue files. This issue is the closing audit trail: it should prove the library exists, moved assets are findable, converted assets are linked, and current authority references are still usable.

## Acceptance criteria

- [x] Focused verifier tests pass.
- [x] `scripts/verify_project_normalization.py` passes and writes a proof JSON.
- [x] `git diff --check` passes.
- [x] Each Legacy library issue records status, changed scope, verification commands, and proof path.
- [x] The parent PRD records the final status and proof path.
- [x] Release Closure Gate is not claimed unless release readiness changed.

## Blocked by

- `.scratch/legacy-matt-workflow-library/issues/06-extend-verifier-for-legacy-library.md`

## Comments

### 2026-06-21 - Codex

Ran final verification and recorded proof for the Legacy Matt Workflow Library migration.

Verification:
- `PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 -m pytest tests/test_verify_project_normalization.py -q` -> `13 passed`
- `PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 -m pytest tests/test_verify_goal_evidence_script.py tests/test_verify_release_readiness_script.py tests/test_verify_release_closure_script.py -q` -> `18 passed`
- `bash -n scripts/release_preflight.sh` -> passed
- `/Users/yann.jy/miniconda3/bin/python3.11 scripts/verify_project_normalization.py --output-root logs/diagnostics/2026-06-21/project-normalization-20260621-legacy-library-final` -> `status: passed`, `findings: 0`
- Proof: `logs/diagnostics/2026-06-21/project-normalization-20260621-legacy-library-final/proof.json`
- `git diff --check` -> passed

Release boundary:
- Release Closure Gate was not rerun because this migration did not change release readiness claims.
