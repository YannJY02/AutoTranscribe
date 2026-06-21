# Project Normalization PRD

Status: ready-for-human

## Problem Statement

InsightKit is runnable and has meaningful local release evidence, but the current project knowledge is split across legacy AutoTranscribe material, InsightKit architecture notes, historical plans, release proof ledgers, code, tests, and generated artifacts. This makes the project feel stuck in the middle: a future agent can see that many things exist, but it cannot reliably tell which assets are current, which are historical, which terms are canonical, which evidence proves a claim, and which next task is safe to pick up.

The user needs the existing project assets normalized into a durable working system so future work can start from the right product language, source roles, release evidence, and issue queue instead of rediscovering the same context every time.

## Solution

Create a project-normalization layer around the existing InsightKit assets. The layer should preserve the current multi-context domain model, use local markdown issues, and add a small amount of verification so normalized assets do not drift silently.

The user-facing result is not a new app feature. The result is that future development starts from a clear Context Map, context glossaries, source roles, release evidence vocabulary, integration contracts, and AFK-ready work items.

## User Stories

1. As the project owner, I want current InsightKit assets separated from historical AutoTranscribe assets, so that future work does not mix product names or eras.
2. As the project owner, I want a Context Map that points to the right domain glossaries, so that agents can load only the relevant context before working.
3. As the project owner, I want product language to distinguish InsightKit, AutoTranscribe, Meeting Asset, Record, Session, and Smart Minutes, so that docs and issues stop drifting between synonyms.
4. As the project owner, I want runtime language to distinguish Sidecar, ASR Engine, Provider, Transcription Job, and Final Insight Generation, so that runtime work is easier to specify.
5. As the project owner, I want app language to distinguish Home Workspace, Live Workspace, Import Workspace, Records Workspace, and Record Review, so that UI work is not described as vague pages or screens.
6. As the project owner, I want release language to separate Local Release Ready from Distribution Ready, so that local evidence is not overstated as public release readiness.
7. As the project owner, I want External Blockers and Owner-Controlled Inputs called out explicitly, so that agent work does not try to solve account or certificate gates it cannot control.
8. As the project owner, I want AttentionOS integration language isolated from the product model, so that host-specific terms do not leak into core InsightKit language.
9. As a future agent, I want to know which existing documents are source material, evidence ledgers, ADRs, plans, or historical references, so that I can use each asset correctly.
10. As a future agent, I want a source ledger for high-signal assets, so that I can find the best starting point without broad searching.
11. As a future agent, I want a project normalization verifier, so that I can check that Context Map links, context docs, ADRs, and local issues are still structurally valid.
12. As a future agent, I want project-normalization issues to be local markdown files with clear status labels, so that I can pick up work without GitHub Issues.
13. As a future agent, I want each normalization task to be a vertical slice, so that completing one issue produces a usable improvement rather than a partial document pile.
14. As a future agent, I want release evidence terms aligned with existing proof commands, so that I can tell which proof supports which readiness claim.
15. As a future agent, I want generated integration docs to preserve InsightKit vocabulary, so that external host work stays consistent with core product language.
16. As a future agent, I want ADRs to capture hard-to-reverse architecture decisions, so that architecture reviews do not re-argue settled choices.
17. As a future agent, I want the existing native macOS app and Python sidecar decision treated as accepted, so that architecture work focuses on improving the current shape.
18. As a future agent, I want the persistent Unix socket RPC decision treated as accepted, so that runtime work does not reintroduce remote service assumptions.
19. As a future agent, I want architecture review to run only after the normalized context and evidence language are readable, so that refactor candidates use project vocabulary.
20. As a future agent, I want a handoff brief for improve-codebase-architecture, so that the architecture scan can start from known contexts, ADRs, and friction areas.
21. As a future agent, I want the PRD and issues to avoid stale file-level implementation details, so that the tasks remain useful after code moves.
22. As a future agent, I want tests to check external behavior of the normalization layer, so that implementation details can change without breaking useful verification.
23. As the project owner, I want normalized docs to stay concise, so that they guide work instead of becoming another overloaded plan archive.
24. As the project owner, I want existing release proof artifacts respected, so that successful local validation is not thrown away or duplicated.
25. As the project owner, I want the next architecture pass to be grounded in normalized assets, so that mid-project momentum comes from clearer seams and not another broad rewrite.

## Implementation Decisions

- Use the local markdown issue tracker for this work. The parent PRD lives under the project-normalization feature folder, and implementation issues live under that feature's local issues folder.
- Mark the PRD and all published normalization issues as `ready-for-agent` because the user approved direct execution and the issue tracker vocabulary is already configured.
- Treat the existing multi-context domain model as the current baseline. Future work should refine it, not replace it with a single root glossary.
- Keep `CONTEXT.md` files as glossaries only. They should not become specs, checklists, implementation plans, or release status documents.
- Keep ADRs short and sparse. Only hard-to-reverse, non-obvious decisions with real alternatives should become ADRs.
- Normalize assets by source role: current domain language, historical reference, architecture decision, release evidence, integration contract, and future work queue.
- Add a high-level project-normalization verifier as the preferred test seam. It should check the normalized asset structure from the outside rather than asserting on implementation details.
- Use existing release proof vocabulary and verifiers as prior art. Do not replace the release workflow with a new status system.
- Preserve the accepted native macOS shell plus Python sidecar architecture and the persistent Unix socket RPC architecture while normalizing docs.
- Do not rename the repository, change product behavior, or rewrite large docs unless a normalization issue explicitly requires a narrow change.

## Testing Decisions

- The highest preferred seam is one bounded project-normalization verifier command. It should validate the structure and linkability of the Context Map, context glossaries, ADRs, PRD, local issues, and source ledger.
- The verifier should test external behavior of the documentation system: paths resolve, required sections exist, status labels are present, blocked-by references point to published issues, and canonical terms do not obviously drift.
- The verifier should avoid checking wording too tightly. It should catch missing assets and broken references, not freeze prose.
- Existing release verification commands remain the evidence seam for release claims. The normalization work may reference them but should not duplicate their full checks.
- Existing Python and Swift tests are out of scope unless a normalization issue changes executable behavior.
- Similar prior art in this repo includes release closure proof aggregation, release readiness verification, UI hygiene verification, secret hygiene verification, and goal evidence verification.

## Out of Scope

- Refactoring runtime, sidecar, SwiftUI, provider, ASR, packaging, or integration code.
- Redesigning the macOS app UI.
- Changing the Insight Package schema.
- Choosing or completing a public release channel.
- Solving Apple account, certificate, notarization, App Store Connect, or public privacy URL blockers.
- Replacing existing release proof ledgers.
- Rewriting all historical plans.
- Migrating local markdown issues to GitHub Issues.

## Further Notes

The immediate goal is to create a reliable handoff surface for future agent work. Once the source ledger, verifier, naming normalization, release vocabulary alignment, integration contract alignment, and architecture-review handoff are complete, the next natural skill is improve-codebase-architecture.

## Comments

### 2026-06-20 - Codex

Project-normalization baseline completed to `ready-for-human` review.

Completed issue slices:
- `01-create-normalization-source-ledger.md`
- `02-add-project-normalization-verifier.md`
- `03-align-product-naming-across-current-docs.md`
- `04-normalize-release-evidence-vocabulary.md`
- `05-normalize-integration-contract-language.md`
- `06-prepare-architecture-review-handoff.md`

Latest structural proof:
- `python3 scripts/verify_project_normalization.py` -> `status: passed`
- Proof: `logs/diagnostics/2026-06-20/project-normalization-20260620-001916/proof.json`

### 2026-06-20 - Codex

Added the repo-local Matt workflow loop engineering standard and made it part of the project-normalization verifier.

Changed:
- Added `docs/agents/loop-engineering.md` with the sequential safe loop packet, Matt workflow routes, verification ladder, feedback packet, stop rules, and record-keeping rules.
- Linked the standard from `AGENTS.md` and `docs/agents/domain.md`.
- Extended `scripts/verify_project_normalization.py` and `tests/test_verify_project_normalization.py` so future checks fail if the loop standard or its `AGENTS.md` link is missing.
- Registered the loop standard in `docs/project-normalization-source-ledger.md`.

Latest structural proof:
- `PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 -m pytest tests/test_verify_project_normalization.py -q` -> `9 passed`
- `/Users/yann.jy/miniconda3/bin/python3.11 scripts/verify_project_normalization.py` -> `status: passed`
- Proof: `logs/diagnostics/2026-06-20/project-normalization-20260620-084822/proof.json`
- Checked counts include `loop_engineering_docs: 1`, `loop_engineering_terms: 16`, `findings: 0`

Runtime/release verification:
- `PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 -m pytest -q --tb=short` -> `201 passed, 1 warning`
- `/Users/yann.jy/miniconda3/bin/python3.11 scripts/verify_release_closure.py` -> `status: passed_local_with_external_blockers`
- Release closure proof: `logs/diagnostics/2026-06-20/release-closure-20260620-084845/proof.json`
- External distribution blockers remain owner-controlled rather than local code failures.

### 2026-06-20 - Codex

Ran the next Project Health Route checkpoint and architecture review for Live Workspace Session.

Changed:
- Generated a temporary architecture review report for Live Workspace Session: `/var/folders/qj/rpkv85p52_j3qx851dzbcvsr0000gn/T/architecture-review-20260620-094106-live-workspace.html`.
- Added `.scratch/live-workspace-session/PRD.md`.
- Added four local issues for the Live Transcript Pipeline deepening sequence.
- Extended `scripts/verify_project_normalization.py` so all `.scratch/<feature>/PRD.md` and `.scratch/<feature>/issues/*.md` files are structurally checked, not only project-normalization issues.
- Extended `tests/test_verify_project_normalization.py` with generic local-feature and cross-feature blocker coverage.

Latest structural proof:
- `PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 -m pytest tests/test_verify_project_normalization.py -q` -> `11 passed`
- `/Users/yann.jy/miniconda3/bin/python3.11 scripts/verify_project_normalization.py` -> `status: passed`
- Proof: `logs/diagnostics/2026-06-20/project-normalization-20260620-094551/proof.json`
- Checked counts include `local_prds: 2`, `issues: 10`, `blocked_by_refs: 13`, `findings: 0`

Final gates:
- `PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 -m pytest -q --tb=short` -> `203 passed, 1 warning`
- `/Users/yann.jy/miniconda3/bin/python3.11 scripts/verify_release_closure.py` -> `status: passed_local_with_external_blockers`
- Release closure proof: `logs/diagnostics/2026-06-20/release-closure-20260620-094614/proof.json`
