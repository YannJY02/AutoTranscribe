# Align product naming across current docs

Status: ready-for-human

## Parent

`.scratch/project-normalization/PRD.md`

## What to build

Normalize current-facing documentation so InsightKit is treated as the current product and AutoTranscribe is treated as legacy transcription lineage. The slice should update only documents that future agents are likely to read as current guidance, while preserving historical references as historical.

User stories covered: 1, 3, 9, 13, 21, 23.

## Acceptance criteria

- [ ] Current-facing docs use InsightKit for the meeting-assistant product.
- [ ] AutoTranscribe references are either clearly legacy, repository lineage, or older local transcription capability.
- [ ] Historical reference material remains available and is not rewritten as if it were current product truth.
- [ ] The source ledger records which naming-related docs are current versus historical.
- [ ] The project-normalization verifier or a focused check can catch an obvious current-doc product-name drift.

## Blocked by

- `.scratch/project-normalization/issues/01-create-normalization-source-ledger.md`
- `.scratch/project-normalization/issues/02-add-project-normalization-verifier.md`

## Comments

### 2026-06-20 - Codex

Aligned current-facing naming while preserving historical material.

Changed:
- `README.md` now names InsightKit as the current product and frames AutoTranscribe as legacy local transcription lineage.
- `AGENTS.md` now uses `InsightKit Agent Instructions`.
- `scripts/verify_project_normalization.py` now checks current-facing naming docs for InsightKit top-heading drift and AutoTranscribe references without legacy/lineage context.
- `tests/test_verify_project_normalization.py` covers a README heading drift failure.

Evidence:
- `python3 -m compileall scripts/verify_project_normalization.py`
- `PYTHONPATH=. pytest tests/test_verify_project_normalization.py` -> `5 passed`
- `python3 scripts/verify_project_normalization.py` -> `status: passed`
- Proof written to `logs/diagnostics/2026-06-20/project-normalization-20260620-001542/proof.json`
