# Create normalization source ledger

Status: ready-for-human

## Parent

`.scratch/project-normalization/PRD.md`

## What to build

Create a durable source ledger for the current InsightKit project assets. The ledger should tell future agents which assets are current domain language, historical reference, architecture decisions, release evidence, integration contracts, or future-work queues. It should cover the whole project-normalization scope instead of only one context.

User stories covered: 1, 2, 9, 10, 13, 21, 23, 24.

## Acceptance criteria

- [x] A source ledger exists for the project-normalization work.
- [x] The ledger classifies high-signal assets by role: current domain language, historical reference, architecture decision, release evidence, integration contract, and future-work queue.
- [x] The ledger identifies the current product name and the legacy transcription lineage without treating them as interchangeable.
- [x] Each context in the Context Map has at least one source entry or an explicit note explaining why it does not.
- [x] Historical plans are marked as historical unless they are still an accepted decision or current evidence source.
- [x] The ledger is concise enough for an AFK agent to read before starting a task.

## Blocked by

None - can start immediately.

## Comments

### 2026-06-20 - Codex

Created `docs/project-normalization-source-ledger.md`.

Evidence:
- Classifies high-signal assets by role: current domain language, historical reference, architecture decision, release evidence, integration contract, and future-work queue.
- States InsightKit as the current product name and AutoTranscribe as legacy repository/app lineage.
- Provides context coverage for Product, Python Runtime, macOS App, Release Workflow, and Integrations.
- Keeps historical plans available but explicitly lower-authority than current context docs and accepted ADRs.
