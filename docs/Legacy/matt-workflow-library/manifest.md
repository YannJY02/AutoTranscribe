# Legacy Matt Workflow Library Manifest

Status: current
Last reviewed: 2026-06-21

This manifest is the top-level index for historical InsightKit assets that have been moved into Legacy and converted into Matt workflow assets.

## How To Read This Library

- **Original asset** means the preserved historical source file. It may contain old names, old paths, old plans, or old release claims.
- **Converted asset** means a newer guide that translates those historical sources into Matt workflow language: goals, decisions, issue-style slices, proof needs, blockers, and current authority.
- **Current authority** means the file a future agent should trust first for current work. Historical sources are useful background, but they do not override current context docs, accepted ADRs, GitHub Issues, or fresh proof.

## Current Assets Not Archived

These current surfaces remain outside this Legacy library:

- `AGENTS.md`
- `CONTEXT-MAP.md`
- `docs/agents/`
- `docs/contexts/`
- `docs/adr/`
- `scripts/verify_project_normalization.py`

GitHub Issues is the active work queue. `.scratch/` remains outside this library only as a historical migration archive verified for internal consistency.

## Original Assets

| Source group | Original path before migration | Preserved path in this library | Converted asset |
| --- | --- | --- | --- |
| Product rationale | `docs/Legacy/overview.md` | `docs/Legacy/matt-workflow-library/original-assets/docs/Legacy/overview.md` | `docs/Legacy/matt-workflow-library/converted-assets/product/historical-product-rationale.md` |
| Product support images | `docs/Legacy/image.png`, `docs/Legacy/image-1.png`, `docs/Legacy/image-2.png` | `docs/Legacy/matt-workflow-library/original-assets/docs/Legacy/` | `docs/Legacy/matt-workflow-library/converted-assets/product/historical-product-rationale.md`, `docs/Legacy/matt-workflow-library/converted-assets/product/reference-output-patterns.md` |
| Product support PDF | `docs/Legacy/智能纪要：示例集重构-新手任务清单 2026年2月3日.pdf` | `docs/Legacy/matt-workflow-library/original-assets/docs/Legacy/` | `docs/Legacy/matt-workflow-library/converted-assets/product/historical-product-rationale.md`, `docs/Legacy/matt-workflow-library/converted-assets/product/reference-output-patterns.md` |
| Historical implementation plans | `docs/plans/2026-03-*.md` | `docs/Legacy/matt-workflow-library/original-assets/docs/plans/` | `docs/Legacy/matt-workflow-library/converted-assets/planning/historical-implementation-prd.md`, `docs/Legacy/matt-workflow-library/converted-assets/planning/historical-implementation-issues.md`, `docs/Legacy/matt-workflow-library/converted-assets/planning/content-promotion-audit.md` |
| Local ASR history | `docs/plans/2026-05-21-local-asr-model-upgrade.md` | `docs/Legacy/matt-workflow-library/original-assets/docs/plans/2026-05-21-local-asr-model-upgrade.md` | `docs/Legacy/matt-workflow-library/converted-assets/planning/historical-implementation-prd.md` |
| Release evidence ledgers | `docs/plans/2026-05-23-insightkit-goal-evidence.md`, `docs/plans/2026-05-24-insightkit-release-verification.md`, `docs/plans/2026-05-26-insightkit-release-readiness-status.md` | `docs/Legacy/matt-workflow-library/original-assets/docs/plans/` | `docs/Legacy/matt-workflow-library/converted-assets/release/release-proof-index.md` |
| Privacy and sandbox drafts | `docs/release-privacy-sandbox.md`, `docs/release-privacy-policy-draft.md`, `docs/release-app-store-privacy-answers.md` | `docs/Legacy/matt-workflow-library/original-assets/docs/release/` | `docs/Legacy/matt-workflow-library/converted-assets/release/owner-input-checklist.md` |
| Architecture reference | `docs/insightkit-architecture.md` | `docs/Legacy/matt-workflow-library/original-assets/docs/architecture/insightkit-architecture.md` | `docs/Legacy/matt-workflow-library/converted-assets/architecture/architecture-decision-map.md` |

### Original Asset File List

- `original-assets/docs/Legacy/overview.md`
- `original-assets/docs/Legacy/image.png`
- `original-assets/docs/Legacy/image-1.png`
- `original-assets/docs/Legacy/image-2.png`
- `original-assets/docs/Legacy/智能纪要：示例集重构-新手任务清单 2026年2月3日.pdf`
- `original-assets/docs/plans/2026-03-06-live-summary-lag-diagnosis.md`
- `original-assets/docs/plans/2026-03-14-phase1-sidecar-split.md`
- `original-assets/docs/plans/2026-03-14-progressive-refactor-design.md`
- `original-assets/docs/plans/2026-03-15-phase2-ipc-upgrade-design.md`
- `original-assets/docs/plans/2026-03-15-phase2-ipc-upgrade.md`
- `original-assets/docs/plans/2026-03-18-phase4-blueprint.md`
- `original-assets/docs/plans/2026-03-18-phase4-frontend-redesign.md`
- `original-assets/docs/plans/2026-03-18-phase5-backend-completion.md`
- `original-assets/docs/plans/2026-05-21-local-asr-model-upgrade.md`
- `original-assets/docs/plans/2026-05-23-insightkit-goal-evidence.md`
- `original-assets/docs/plans/2026-05-24-insightkit-release-verification.md`
- `original-assets/docs/plans/2026-05-26-insightkit-release-readiness-status.md`
- `original-assets/docs/release/release-privacy-sandbox.md`
- `original-assets/docs/release/release-privacy-policy-draft.md`
- `original-assets/docs/release/release-app-store-privacy-answers.md`
- `original-assets/docs/architecture/insightkit-architecture.md`

## Converted Assets

| Converted asset | Purpose | Current authority to prefer |
| --- | --- | --- |
| `converted-assets/product/historical-product-rationale.md` | Preserves the Feishu Minutes / smart-meeting rationale as product history. | `docs/contexts/product/CONTEXT.md` |
| `converted-assets/product/reference-output-patterns.md` | Converts historical images and the example PDF into privacy-safe Smart Minutes output structure patterns. | `docs/contexts/product/CONTEXT.md` |
| `converted-assets/planning/historical-implementation-prd.md` | Reframes older phase plans as a historical PRD-style story. | GitHub Issues and current context docs |
| `converted-assets/planning/historical-implementation-issues.md` | Reframes older phase plans as historical issue-style slices. | GitHub Issues |
| `converted-assets/planning/content-promotion-audit.md` | Records per-original content decisions and which current standard assets absorbed still-valid material. | `docs/contexts/`, `docs/adr/`, GitHub Issues, and current verifier output |
| `converted-assets/architecture/architecture-decision-map.md` | Maps older architecture notes to accepted ADRs. | `docs/adr/` |
| `converted-assets/release/release-proof-index.md` | Preserves release proof paths and local readiness claims. | `docs/contexts/release-workflow/CONTEXT.md` and fresh verifier output |
| `converted-assets/release/owner-input-checklist.md` | Preserves owner-controlled release inputs and privacy review items. | Current GitHub Issues, release scripts, and owner decisions |

## Current Authority Rules

- Prefer current context docs over historical product language.
- Prefer accepted ADRs over historical architecture plans.
- Prefer the content-promotion audit when deciding whether a moved original already had its usable content absorbed into current standard assets.
- Prefer fresh proof JSON over historical release prose.
- Treat Legacy release evidence as an audit trail, not a new release claim.
- Treat moved privacy drafts as owner-review material, not published legal text; use current GitHub Issues for public-distribution work.
- Keep Local Release Ready and Distribution Ready separate.

## Verification

This library should be checked by `scripts/verify_project_normalization.py`. The verifier should fail if the manifest references a missing original asset, a missing converted asset, a stale moved path, or a broken local issue dependency.
