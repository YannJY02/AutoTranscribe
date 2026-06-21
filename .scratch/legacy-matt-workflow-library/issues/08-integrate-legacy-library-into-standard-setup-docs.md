# Integrate Legacy library into standard setup docs

Status: ready-for-human

## Parent

`.scratch/legacy-matt-workflow-library/PRD.md`

## What to build

Make the Legacy Matt Workflow Library visible from the standard Matt setup surfaces, not only from its own manifest. Future agents should know that `.scratch/` is the active issue tracker, `docs/agents/` defines consumption rules, `docs/contexts/` and `docs/adr/` are current authority, and Legacy converted assets must be promoted into current forms only when code and proof justify it.

## Acceptance criteria

- [x] `AGENTS.md` points agents to the Legacy workflow library manifest.
- [x] `docs/agents/issue-tracker.md` states that Legacy issue-style files are not active issues.
- [x] `docs/agents/triage-labels.md` states that triage labels apply only to current `.scratch` issues.
- [x] `docs/agents/domain.md` explains how to classify historical material into context terms, ADRs, PRDs/issues, proof, owner input, or Legacy reference.
- [x] `docs/agents/loop-engineering.md` includes a Legacy Asset Promotion Route.
- [x] `scripts/verify_project_normalization.py` checks these standard setup references.

## Blocked by

- `.scratch/legacy-matt-workflow-library/issues/07-run-final-verification-and-record-proof.md`

## Comments

### 2026-06-21 - Codex

Integrated the Legacy Matt Workflow Library into the standard Matt setup docs instead of leaving converted assets only inside Legacy.

Changed:
- Added a Legacy workflow library pointer in `AGENTS.md`.
- Clarified that `.scratch/` remains the active issue tracker and Legacy issue-style files are reference material.
- Clarified that triage labels apply only to current `.scratch` issue files.
- Added Legacy promotion rules to domain docs.
- Added a Legacy Asset Promotion Route to loop engineering.
- Extended the project-normalization verifier so these standard setup references are checked automatically.

Verification:
- `PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 -m pytest tests/test_verify_project_normalization.py -q` -> `14 passed`
- `/Users/yann.jy/miniconda3/bin/python3.11 scripts/verify_project_normalization.py --output-root logs/diagnostics/2026-06-21/project-normalization-20260621-legacy-standard-integration` -> `status: passed`, `legacy_standard_setup_docs: 5`, `findings: 0`
- Proof: `logs/diagnostics/2026-06-21/project-normalization-20260621-legacy-standard-integration/proof.json`
