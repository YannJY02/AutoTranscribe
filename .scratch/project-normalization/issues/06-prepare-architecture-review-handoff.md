# Prepare architecture review handoff

Status: ready-for-human

## Parent

`.scratch/project-normalization/PRD.md`

## What to build

Prepare the handoff surface for the next improve-codebase-architecture pass. The handoff should tell a future architecture scan which contexts to read, which ADRs are accepted, which source assets are current, and which friction areas should be explored without reopening settled product or release decisions.

User stories covered: 16, 17, 18, 19, 20, 25.

## Acceptance criteria

- [ ] A concise architecture-review handoff exists for future architecture work.
- [ ] The handoff names the relevant contexts and accepted ADRs to read first.
- [ ] The handoff identifies likely friction areas using domain vocabulary rather than file-level implementation trivia.
- [ ] The handoff explicitly preserves the accepted native macOS shell plus Python sidecar decision.
- [ ] The handoff explicitly preserves the accepted persistent Unix socket RPC decision.
- [ ] The handoff distinguishes architecture candidates from release-channel blockers.
- [ ] The project-normalization verifier includes the handoff in its checked asset set or the handoff has its own focused structural check.

## Blocked by

- `.scratch/project-normalization/issues/03-align-product-naming-across-current-docs.md`
- `.scratch/project-normalization/issues/04-normalize-release-evidence-vocabulary.md`
- `.scratch/project-normalization/issues/05-normalize-integration-contract-language.md`

## Comments

### 2026-06-20 - Codex

Prepared the architecture review handoff surface.

Changed:
- Added `docs/architecture-review-handoff.md` with read-first sources, accepted ADRs, current source assets, preserved decisions, friction areas, release-blocker separation, and verification guidance.
- Updated `docs/project-normalization-source-ledger.md` to list the handoff as the current architecture-review surface.
- Extended `scripts/verify_project_normalization.py` to check handoff existence and required sections/markers.
- Extended `tests/test_verify_project_normalization.py` with a missing-handoff failure case.

Evidence:
- `python3 -m compileall scripts/verify_project_normalization.py`
- `PYTHONPATH=. pytest tests/test_verify_project_normalization.py` -> `7 passed`
- `python3 scripts/verify_project_normalization.py` -> `status: passed`
- Proof written to `logs/diagnostics/2026-06-20/project-normalization-20260620-001916/proof.json`
- Checked `architecture_handoffs: 1`, `findings: 0`
