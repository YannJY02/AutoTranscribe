# Normalize release evidence vocabulary

Status: ready-for-human

## Parent

`.scratch/project-normalization/PRD.md`

## What to build

Align release-facing docs and evidence language with the Release Workflow glossary. The slice should keep Local Release Ready, Distribution Ready, External Blocker, Owner-Controlled Input, Proof JSON, Closure Gate, Packaged-App Smoke, and Visual GUI Proof distinct in the places future agents use to judge readiness.

User stories covered: 6, 7, 11, 14, 22, 24.

## Acceptance criteria

- [x] Release-facing docs distinguish local/internal QA readiness from public distribution readiness.
- [x] Apple account, certificate, notarization, sandbox, App Store Connect, and privacy URL requirements are described as External Blockers or Owner-Controlled Inputs where appropriate.
- [x] Packaged-App Smoke and Visual GUI Proof are not collapsed into generic script success.
- [x] Existing release proof commands remain the source of release evidence.
- [x] Any new wording preserves the accepted ADR that local readiness and public distribution readiness are separate claims.
- [x] The project-normalization verifier or a focused check can confirm required release vocabulary surfaces still exist.

## Blocked by

- `.scratch/project-normalization/issues/01-create-normalization-source-ledger.md`
- `.scratch/project-normalization/issues/02-add-project-normalization-verifier.md`

## Comments

### 2026-06-20 - Codex

Aligned release evidence vocabulary with the Release Workflow glossary.

Changed:
- `docs/plans/2026-05-26-insightkit-release-readiness-status.md` now labels the repeatable verifier as a Closure Gate, the proof artifact as Proof JSON, and the installed-app/GUI evidence as Packaged-App Smoke and Visual GUI Proof.
- `docs/project-normalization-source-ledger.md` now names Proof JSON, Closure Gate, Packaged-App Smoke, and Visual GUI Proof in the Release Workflow entries.
- `scripts/verify_project_normalization.py` now verifies required Release Workflow vocabulary terms.
- `tests/test_verify_project_normalization.py` covers missing release vocabulary failure.

Evidence:
- `python3 -m compileall scripts/verify_project_normalization.py`
- `PYTHONPATH=. pytest tests/test_verify_project_normalization.py` -> `6 passed`
- `python3 scripts/verify_project_normalization.py` -> `status: passed`
- Proof written to `logs/diagnostics/2026-06-20/project-normalization-20260620-001656/proof.json`
- Checked `release_vocab_terms: 8`, `findings: 0`
