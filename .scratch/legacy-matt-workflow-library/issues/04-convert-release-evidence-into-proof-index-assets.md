# Convert release evidence into proof-index assets

Status: ready-for-human

## Parent

`.scratch/legacy-matt-workflow-library/PRD.md`

## What to build

Convert moved release and privacy materials into a proof index, external blocker ledger, and owner-input checklist. The goal is to preserve release evidence while making it clear which claims are local evidence, which are historical proof paths, and which depend on Apple/account owner actions.

## Acceptance criteria

- [x] Converted release proof index exists under the Legacy Matt Workflow Library.
- [x] The proof index preserves important proof JSON, screenshot, app path, and command references from the moved release ledgers.
- [x] Local Release Ready and Distribution Ready remain separate concepts.
- [x] External blockers and owner-controlled inputs remain explicit.
- [x] Privacy and sandbox drafts are represented as owner-review material, not published legal or App Store final text.
- [x] The manifest links each converted release asset back to its moved original.

## Blocked by

- `.scratch/legacy-matt-workflow-library/issues/02-move-historical-originals-into-legacy-library.md`

## Comments

### 2026-06-21 - Codex

Converted moved release evidence into a release proof index and owner input checklist.

Verification:
- `PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 -m pytest tests/test_verify_goal_evidence_script.py tests/test_verify_release_readiness_script.py tests/test_verify_release_closure_script.py -q` -> `18 passed`
- `bash -n scripts/release_preflight.sh` -> passed
- Proof: `logs/diagnostics/2026-06-21/project-normalization-20260621-legacy-library-final/proof.json`
