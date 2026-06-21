# Add project normalization verifier

Status: ready-for-human

## Parent

`.scratch/project-normalization/PRD.md`

## What to build

Add a bounded project-normalization verifier that checks whether the normalized asset system is still structurally usable. The verifier should validate the Context Map, context glossaries, ADRs, source ledger, PRD, and local issues from the outside, then report a clear pass/fail result.

User stories covered: 2, 10, 11, 12, 13, 20, 22.

## Acceptance criteria

- [ ] A single command can verify the project-normalization asset structure.
- [ ] The verifier fails when the Context Map points to a missing context glossary.
- [ ] The verifier fails when a local issue is missing a `Status:` line.
- [ ] The verifier fails when a project-normalization issue has a blocked-by reference that does not point to an existing local issue.
- [ ] The verifier reports the checked asset counts and the output is readable by a future agent.
- [ ] The verifier does not assert on exact prose except for required structural markers and status labels.

## Blocked by

- `.scratch/project-normalization/issues/01-create-normalization-source-ledger.md`

## Comments

### 2026-06-20 - Codex

Implemented `scripts/verify_project_normalization.py` and `tests/test_verify_project_normalization.py`.

Evidence:
- `python3 -m compileall scripts/verify_project_normalization.py`
- `PYTHONPATH=. pytest tests/test_verify_project_normalization.py` -> `4 passed`
- `python3 scripts/verify_project_normalization.py` -> `status: passed`
- Proof written to `logs/diagnostics/2026-06-20/project-normalization-20260620-001418/proof.json`
- Checked counts: `context_links: 5`, `context_docs: 5`, `adrs: 3`, `issues: 6`, `blocked_by_refs: 10`, `source_ledgers: 1`, `findings: 0`

### 2026-06-20 - Codex

Extended the verifier to treat the Matt workflow loop standard as a checked project-normalization asset.

Changed:
- Added `docs/agents/loop-engineering.md` checks for required sections and route/gate terms.
- Added an `AGENTS.md` backlink check for `docs/agents/loop-engineering.md`.
- Added regression cases for a missing loop standard and missing `AGENTS.md` link.

Evidence:
- `PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 -m pytest tests/test_verify_project_normalization.py -q` -> `9 passed`
- `/Users/yann.jy/miniconda3/bin/python3.11 scripts/verify_project_normalization.py` -> `status: passed`
- Proof written to `logs/diagnostics/2026-06-20/project-normalization-20260620-084822/proof.json`
- Checked counts now include `loop_engineering_docs: 1`, `loop_engineering_terms: 16`, `findings: 0`

### 2026-06-20 - Codex

Extended the verifier again after the first new Matt workflow feature queue was created.

Changed:
- The verifier now checks every `.scratch/<feature>/PRD.md` for a valid `Status:` line.
- The verifier now checks every `.scratch/<feature>/issues/*.md` for a valid `Status:` line.
- Blocked-by references now support any `.scratch/<feature>/issues/*.md` path.
- Added tests for a second local markdown feature and a broken cross-feature blocker.

Evidence:
- `PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 -m pytest tests/test_verify_project_normalization.py -q` -> `11 passed`
- `/Users/yann.jy/miniconda3/bin/python3.11 scripts/verify_project_normalization.py` -> `status: passed`
- Proof written to `logs/diagnostics/2026-06-20/project-normalization-20260620-094509/proof.json`
- Checked counts now include `local_prds: 2`, `issues: 10`, `blocked_by_refs: 13`, `findings: 0`
