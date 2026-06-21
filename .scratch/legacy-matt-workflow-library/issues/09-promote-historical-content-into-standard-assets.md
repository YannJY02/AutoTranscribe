# Promote historical content into standard assets

Status: ready-for-human

## Parent

- `.scratch/legacy-matt-workflow-library/PRD.md`

## What to build

Read each moved historical original and decide whether its content should be absorbed into current standard Matt workflow assets. Promote still-valid terms and durable decisions into `docs/contexts/`, `docs/adr/`, or current `.scratch/` work only when code and current proof support them. Leave only stale detail, visual evidence, proof history, or owner-review material in Legacy.

## Acceptance criteria

- [x] Each moved original asset has a content-level decision recorded.
- [x] Still-valid product, runtime, app, and release vocabulary is promoted into current context docs.
- [x] Durable architecture decisions from historical plans are promoted into accepted ADRs.
- [x] No new product/engineering issue is created unless the historical material describes unfinished current work or owner-approved release work.
- [x] The Legacy manifest and source ledger point to the content-promotion audit.
- [x] `scripts/verify_project_normalization.py` checks the promoted standard assets.
- [x] Final verification proof is recorded.

## Blocked by

None - can start immediately.

## Comments

### 2026-06-21 - Codex

Created this issue after the project owner clarified that historical materials should be judged one by one and absorbed into current standard assets when possible, not merely indexed from Legacy.

Promoted content from each moved original into the current standard assets where code and proof supported it.

Changed scope:
- Added `docs/Legacy/matt-workflow-library/converted-assets/planning/content-promotion-audit.md`.
- Added product, runtime, macOS app, and release workflow terms to current context docs.
- Expanded ADRs 0001-0003 and added ADR 0004 for local Record Folders plus runtime `RecordWriter`.
- Updated the Legacy manifest, source ledger, architecture handoff, verifier, and verifier tests.

Verification:
- `PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 -m pytest tests/test_verify_project_normalization.py -q` -> `15 passed`
- `/Users/yann.jy/miniconda3/bin/python3.11 scripts/verify_project_normalization.py --output-root logs/diagnostics/2026-06-21/project-normalization-20260621-legacy-content-promotion-final` -> `status: passed`, `findings: 0`
- `git diff --check` -> passed
- Proof: `logs/diagnostics/2026-06-21/project-normalization-20260621-legacy-content-promotion-final/proof.json`

No new product or engineering issue was created from the historical originals during the initial automated pass because current code and docs showed the agent-actionable material was already implemented, absorbed into contexts/ADRs, or owner-controlled release material. The owner-approved release/privacy promotion below supersedes that initial issue decision for the three release draft files.

### 2026-06-21 - Codex

Owner approved promoting the remaining release/privacy review material into current `.scratch` work.

Added:
- `.scratch/public-distribution-readiness/PRD.md`
- `.scratch/public-distribution-readiness/issues/01-confirm-release-channel-and-cloud-provider-boundary.md`
- `.scratch/public-distribution-readiness/issues/02-prepare-public-privacy-policy-url.md`
- `.scratch/public-distribution-readiness/issues/03-finalize-app-store-privacy-answers.md`
- `.scratch/public-distribution-readiness/issues/04-run-developer-id-distribution-preflight.md`
- `.scratch/public-distribution-readiness/issues/05-run-app-store-sandbox-distribution-preflight.md`

The original release/privacy files remain preserved under `docs/Legacy/matt-workflow-library/original-assets/docs/release/`.

Verification:
- `PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 -m pytest tests/test_verify_project_normalization.py -q` -> `15 passed`
- `/Users/yann.jy/miniconda3/bin/python3.11 scripts/verify_project_normalization.py --output-root logs/diagnostics/2026-06-21/project-normalization-20260621-public-distribution-readiness` -> `status: passed`, `findings: 0`
- Proof: `logs/diagnostics/2026-06-21/project-normalization-20260621-public-distribution-readiness/proof.json`
- `git diff --check` -> passed

### 2026-06-21 - Codex

Owner approved converting the historical product images and example PDF into a privacy-safe output structure reference.

Added:
- `docs/Legacy/matt-workflow-library/converted-assets/product/reference-output-patterns.md`

Updated:
- `docs/contexts/product/CONTEXT.md` with `Smart Minutes Module` and `Reference Output Pattern`.
- `docs/Legacy/matt-workflow-library/manifest.md` so product support images and PDF point to the new converted asset.
- `docs/project-normalization-source-ledger.md` so future agents can find the reference output patterns.
- `docs/Legacy/matt-workflow-library/converted-assets/planning/content-promotion-audit.md` so image/PDF decisions reflect the conversion.
- `scripts/verify_project_normalization.py` and its tests so the new asset is machine-checkable.

Verification:
- `PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 -m pytest tests/test_verify_project_normalization.py -q` -> `15 passed`
- `/Users/yann.jy/miniconda3/bin/python3.11 scripts/verify_project_normalization.py --output-root logs/diagnostics/2026-06-21/project-normalization-20260621-reference-output-patterns` -> `status: passed`, `legacy_converted_assets: 8`, `findings: 0`
- Proof: `logs/diagnostics/2026-06-21/project-normalization-20260621-reference-output-patterns/proof.json`
- `git diff --check` -> passed

### 2026-06-21 - Codex

Owner approved keeping historical implementation plans as Legacy-only.

Decision:
- Do not create current `.scratch` issues from the old March phase plans, March live-summary diagnosis, or May local ASR model-upgrade note.
- Keep their durable concepts in current context docs and ADRs.
- Keep their old step lists, path names, proof paths, and test counts as historical implementation detail only.

Updated:
- `docs/Legacy/matt-workflow-library/converted-assets/planning/content-promotion-audit.md`

Verification:
- `PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 -m pytest tests/test_verify_project_normalization.py -q` -> `15 passed`
- `/Users/yann.jy/miniconda3/bin/python3.11 scripts/verify_project_normalization.py --output-root logs/diagnostics/2026-06-21/project-normalization-20260621-implementation-plans-legacy-only` -> `status: passed`, `findings: 0`
- Proof: `logs/diagnostics/2026-06-21/project-normalization-20260621-implementation-plans-legacy-only/proof.json`
- `git diff --check` -> passed

### 2026-06-21 - Codex

Owner approved keeping historical release proof/status ledgers as Legacy release history.

Decision:
- Do not create current `.scratch` issues from `2026-05-23-insightkit-goal-evidence.md`, `2026-05-24-insightkit-release-verification.md`, or `2026-05-26-insightkit-release-readiness-status.md`.
- Do not treat old build IDs, proof paths, test counts, or status conclusions as current release proof.
- Keep current release claims tied to fresh verifier output and fresh `proof.json`.

Updated:
- `docs/Legacy/matt-workflow-library/converted-assets/planning/content-promotion-audit.md`
- `scripts/verify_project_normalization.py`

Verification:
- `PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 -m pytest tests/test_verify_project_normalization.py -q` -> `15 passed`
- `/Users/yann.jy/miniconda3/bin/python3.11 scripts/verify_project_normalization.py --output-root logs/diagnostics/2026-06-21/project-normalization-20260621-architecture-reference-legacy` -> `status: passed`, `findings: 0`
- Proof: `logs/diagnostics/2026-06-21/project-normalization-20260621-architecture-reference-legacy/proof.json`
- `git diff --check` -> passed

### 2026-06-21 - Codex

Completed the Legacy conversion closure review.

Closure checks:
- 21 moved original assets are listed in `docs/Legacy/matt-workflow-library/manifest.md`.
- 21 moved original assets have per-asset decisions in `docs/Legacy/matt-workflow-library/converted-assets/planning/content-promotion-audit.md`.
- 8 converted assets are listed in the Legacy manifest and checked by `scripts/verify_project_normalization.py`.
- 6 current public-distribution assets exist under `.scratch/public-distribution-readiness/`.
- No unclassified moved originals remain.

Verification:
- `PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 -m pytest tests/test_verify_project_normalization.py -q` -> `15 passed`
- `/Users/yann.jy/miniconda3/bin/python3.11 scripts/verify_project_normalization.py --output-root logs/diagnostics/2026-06-21/project-normalization-20260621-legacy-conversion-closure` -> `status: passed`, `legacy_original_assets: 21`, `legacy_converted_assets: 8`, `public_distribution_readiness_assets: 6`, `findings: 0`
- Proof: `logs/diagnostics/2026-06-21/project-normalization-20260621-legacy-conversion-closure/proof.json`
- `git diff --check` -> passed

Verification:
- `PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 -m pytest tests/test_verify_project_normalization.py -q` -> `15 passed`
- `/Users/yann.jy/miniconda3/bin/python3.11 scripts/verify_project_normalization.py --output-root logs/diagnostics/2026-06-21/project-normalization-20260621-release-ledgers-legacy-history` -> `status: passed`, `findings: 0`
- Proof: `logs/diagnostics/2026-06-21/project-normalization-20260621-release-ledgers-legacy-history/proof.json`
- `git diff --check` -> passed

### 2026-06-21 - Codex

Owner approved keeping the historical architecture reference as Legacy architecture reference.

Decision:
- Do not create a new ADR or current `.scratch` issue from `original-assets/docs/architecture/insightkit-architecture.md`.
- Keep its durable decisions routed to ADR 0001, ADR 0002, ADR 0004, and current context docs.
- Treat old absolute paths and compact architecture summary as provenance only.

Updated:
- `docs/Legacy/matt-workflow-library/converted-assets/planning/content-promotion-audit.md`
- `scripts/verify_project_normalization.py`
