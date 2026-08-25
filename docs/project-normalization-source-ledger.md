# Project Normalization Source Ledger

Status: current
Last reviewed: 2026-06-21

This ledger tells future agents which existing assets to trust for project-normalization work. It classifies sources by role so current InsightKit work does not drift into legacy AutoTranscribe language, stale plans, or release-channel overclaims.

## Current Product Name

- **InsightKit** is the current meeting-assistant product name.
- **AutoTranscribe** is legacy repository/app lineage and older local transcription capability. Treat it as historical unless a file explicitly discusses compatibility or migration history.

## Role Taxonomy

- **Current domain language**: glossary or context files that should shape new issues, docs, and architecture work.
- **Historical reference**: useful background that should not override current domain language or accepted ADRs.
- **Architecture decision**: accepted ADRs or current architecture references.
- **Release evidence**: proof ledgers and verifier scripts that support local readiness claims.
- **Integration contract**: AttentionOS or host-facing module contracts.
- **Future-work queue**: GitHub Issues and their dependency/triage metadata define next slices; `.scratch/` is migration history.

## Context Coverage

| Context | Current source entries | Notes |
|---|---|---|
| Product | `docs/contexts/product/CONTEXT.md`, `docs/Legacy/matt-workflow-library/converted-assets/product/historical-product-rationale.md`, `docs/Legacy/matt-workflow-library/converted-assets/product/reference-output-patterns.md`, `docs/Legacy/matt-workflow-library/converted-assets/planning/content-promotion-audit.md` | Use the context file for current language; use the Legacy converted assets only as historical rationale, output-structure patterns, and promotion audit trails. |
| Python Runtime | `docs/contexts/python-runtime/CONTEXT.md`, `scripts/asr_runtime_profile.py`, `scripts/asr_model_catalog.py`, `insightkit/ipc/server.py` | Runtime terms cover Sidecar, RPC Action, RPC Event, ASR Runtime Profile, ASR Model Catalog, Runtime Snapshot, Prewarm Watchdog, Record Writer, and Record Save Action. |
| macOS App | `docs/contexts/macos-app/CONTEXT.md`, `macos/InsightKitApp/Sources/InsightKitApp/` | Use workspace terms such as Session Shell, Session Phase, Panel Data Source, and Record Index rather than generic page/screen language. |
| Release Workflow | `docs/contexts/release-workflow/CONTEXT.md`, `docs/Legacy/matt-workflow-library/converted-assets/release/release-proof-index.md`, GitHub Issues, `scripts/verify_release_closure.py` | Local Release Ready and Distribution Ready remain separate claims; use Proof JSON, Closure Gate, preflight, hygiene-gate, Privacy Review Input, Public Distribution Readiness, and Sandbox Verification terms. |
| Integrations | `docs/contexts/integrations/CONTEXT.md`, `docs/attentionos-integration.md`, `insightkit/integration/attentionos_bridge.py` | `docs/attentionos-integration.md` and the generated module README are current External Host Contract surfaces; keep host terms out of core product language unless the integration context is active. |

## High-Signal Assets By Role

### Current Domain Language

- `CONTEXT-MAP.md`: entry point for the multi-context domain-doc layout.
- `docs/contexts/product/CONTEXT.md`: current product, meeting asset, record folder, meeting envelope, Smart Minutes, Smart Minutes Module, Reference Output Pattern, AI review notice, and related-link language.
- `docs/contexts/python-runtime/CONTEXT.md`: Sidecar, RPC Action, RPC Event, ASR Runtime Profile, ASR Model Catalog, Runtime Snapshot, Prewarm Watchdog, Provider, Transcription Job, Record Writer, and Record Save Action language.
- `docs/contexts/macos-app/CONTEXT.md`: Home Workspace, Live Workspace, Import Workspace, Records Workspace, Record Review, Session Shell, Session Phase, Panel Data Source, and Record Index language.
- `docs/contexts/release-workflow/CONTEXT.md`: Local Release Ready, Distribution Ready, Public Distribution Readiness, External Blocker, Owner-Controlled Input, Proof JSON, Closure Gate, preflight gates, Packaged-App Smoke, Visual GUI Proof, hygiene gates, Privacy Review Input, and Sandbox Verification language.
- `docs/contexts/integrations/CONTEXT.md`: AttentionOS Module, Module Bridge, Host Call, Bridge Action, and Capability Manifest language.

### Historical Reference

- `docs/Legacy/matt-workflow-library/manifest.md`: index for moved historical originals and converted Matt workflow assets.
- `docs/Legacy/matt-workflow-library/converted-assets/product/historical-product-rationale.md`: high-signal historical rationale for the Feishu Minutes / InsightKit direction; not a current implementation spec.
- `docs/Legacy/matt-workflow-library/converted-assets/product/reference-output-patterns.md`: privacy-safe structure patterns extracted from historical images and the example PDF; not a fixture set or current design spec.
- `docs/Legacy/matt-workflow-library/original-assets/docs/Legacy/`: historical product support images, PDF, and original overview; preserve rather than rewrite.
- `docs/Legacy/matt-workflow-library/converted-assets/planning/historical-implementation-prd.md`: older staged implementation plans translated into a historical PRD-style view.
- `docs/Legacy/matt-workflow-library/converted-assets/planning/historical-implementation-issues.md`: older staged implementation plans translated into historical issue-style slices.
- `docs/Legacy/matt-workflow-library/converted-assets/planning/content-promotion-audit.md`: per-original audit showing which historical content was absorbed into current contexts, ADRs, or issue decisions.

### Architecture Decision

- `docs/adr/0001-keep-native-macos-shell-with-python-sidecar.md`: accepted native macOS shell plus Python sidecar decision.
- `docs/adr/0002-use-persistent-unix-socket-rpc-for-app-runtime-communication.md`: accepted persistent Unix socket RPC decision.
- `docs/adr/0003-separate-local-readiness-from-public-distribution-readiness.md`: accepted readiness vocabulary decision.
- `docs/adr/0004-use-local-record-folders-with-runtime-record-writer.md`: accepted local Record Folder plus runtime RecordWriter decision.
- `docs/Legacy/matt-workflow-library/converted-assets/architecture/architecture-decision-map.md`: historical architecture reference map; defer to ADRs when it conflicts with accepted decisions.
- `docs/architecture-review-handoff.md`: current handoff surface for future deep module scans; not an ADR.
- `docs/agents/loop-engineering.md`: current Matt workflow loop standard; use it to run sequential safe loops from review through implementation and verification.

### Release Evidence

- `scripts/verify_release_closure.py`: top-level non-GUI release closure verifier.
- `scripts/verify_release_readiness.py`: release-readiness proof generator.
- `scripts/verify_goal_evidence.py`: goal evidence aggregator against current product requirements.
- `scripts/release_preflight.sh`: local, Developer ID, and App Store preflight gate.
- `docs/Legacy/matt-workflow-library/converted-assets/release/release-proof-index.md`: historical release proof index.
- `docs/Legacy/matt-workflow-library/converted-assets/release/owner-input-checklist.md`: owner-controlled release and privacy inputs.
- `.scratch/public-distribution-readiness/PRD.md`: retained migration source for owner-controlled public-distribution work; active state belongs in GitHub Issues.
- `docs/Legacy/matt-workflow-library/original-assets/docs/plans/2026-05-23-insightkit-goal-evidence.md`: moved product-goal evidence ledger.
- `docs/Legacy/matt-workflow-library/original-assets/docs/plans/2026-05-24-insightkit-release-verification.md`: moved release verification notes.
- `docs/Legacy/matt-workflow-library/original-assets/docs/plans/2026-05-26-insightkit-release-readiness-status.md`: moved release-readiness status and blocker language.
- `logs/diagnostics/`: generated proof outputs. Use specific proof paths as evidence; do not treat the folder itself as a stable spec.

### Integration Contract

- `docs/attentionos-integration.md`: current AttentionOS External Host Contract.
- `insightkit/integration/attentionos_bridge.py`: generated module wrapper implementation.
- `scripts/export_attention_module.py`: module export entry point.
- `scripts/install_attention_module.sh`: local install helper.
- `tests/test_attentionos_bridge.py`: focused contract check for the bridge module.

### Future-Work Queue

- GitHub Issues: active PRDs, implementation slices, dependencies, triage state, and human handoff.
- `.scratch/`: historical local PRD/issue migration source only; re-check before selectively creating a GitHub Issue.
- `docs/agents/issue-tracker.md`: GitHub Issue contract and operations.
- `docs/agents/triage-labels.md`: allowed status vocabulary.
- `docs/agents/domain.md`: domain-doc maintenance convention.
- `docs/agents/loop-engineering.md`: Matt workflow loop packet, routes, verification ladder, feedback packet, stop rules, and record-keeping rules.
- `docs/agents/harness.md`: Codex, Symphony, deterministic CI, resource lock, evidence, and Agentic Workflow contract.

## Use Rules

- Prefer current context docs over historical plans for naming.
- Prefer accepted ADRs over architecture notes for hard-to-reverse decisions.
- Prefer verifier output and proof JSON over prose when making release-readiness claims.
- Mark historical plans as historical unless a current context file, ADR, fresh verifier output, or current GitHub Issue reactivates them.
- Use the content-promotion audit before reprocessing moved Legacy originals; do not create duplicate current terms or issues when the audit already shows the content was absorbed.
- Keep this ledger concise; add only high-signal assets that change where future work should start.
