# Historical Content Promotion Audit

Status: current
Last reviewed: 2026-06-21

This audit records the content-level conversion of each moved historical source. It is not a replacement for the current context docs, ADRs, or `.scratch` issues. Its job is to prove that each original asset was read and classified before the remaining source was kept in Legacy.

## Promotion Rules Used

- Promote to `docs/contexts/*/CONTEXT.md` when the historical material describes current project language that is still present in code or verifier expectations.
- Promote to `docs/adr/` when the historical material describes a durable architecture decision with current code support.
- Promote to `.scratch/<feature>/` only when the historical material describes unfinished current work that can be executed by an agent.
- Keep in Legacy when the material is stale implementation history, proof history, screenshots, example output, or owner-review material with no current workflow decision.
- Ask the owner only when code, current docs, and proof cannot decide. The initial automated pass did not need owner input; the owner later approved promoting the release/privacy review material into a current public-distribution lane, converting product examples into reference output patterns, keeping historical implementation plans as Legacy-only, keeping historical release proof/status ledgers as Legacy release history, and keeping the historical architecture reference as Legacy architecture reference.

## Standard Assets Updated

- `docs/contexts/product/CONTEXT.md`: added Record Folder, Meeting Envelope, AI Review Notice, Related Links Section, Smart Minutes Module, and Reference Output Pattern.
- `docs/contexts/python-runtime/CONTEXT.md`: added RPC Event, ASR Model Catalog, Runtime Snapshot, Prewarm Watchdog, Record Writer, and Record Save Action.
- `docs/contexts/macos-app/CONTEXT.md`: added Session Shell, Session Phase, Record Index, and Panel Data Source.
- `docs/contexts/release-workflow/CONTEXT.md`: added Local Preflight, Developer ID Preflight, App Store Preflight, Secret Hygiene Gate, UI Hygiene Gate, Privacy Review Input, Sandbox Verification, and Public Distribution Readiness.
- `docs/adr/0001-keep-native-macos-shell-with-python-sidecar.md`: expanded the accepted native app plus Python sidecar decision.
- `docs/adr/0002-use-persistent-unix-socket-rpc-for-app-runtime-communication.md`: expanded the accepted persistent NDJSON JSON-RPC and RPC Event decision.
- `docs/adr/0003-separate-local-readiness-from-public-distribution-readiness.md`: expanded the accepted readiness and owner-controlled blocker decision.
- `docs/adr/0004-use-local-record-folders-with-runtime-record-writer.md`: added the accepted Record Folder plus runtime RecordWriter decision.

## Per-Asset Decisions

| Original asset | Content judgment | Promoted into current standard assets | Legacy remainder |
| --- | --- | --- | --- |
| `original-assets/docs/Legacy/overview.md` | Current product rationale and export structure are still valid; Feishu/Lark naming remains historical only. | Product context terms: Smart Minutes modules, Meeting Envelope, AI Review Notice, Related Links Section. | Original competitor/reference wording and source links remain historical product background. |
| `original-assets/docs/Legacy/image.png` | Visual support for historical Smart Minutes module navigation and topic hierarchy. | Product context terms: Smart Minutes Module and Reference Output Pattern; converted asset: `converted-assets/product/reference-output-patterns.md`. | Image remains preserved as visual provenance only; exact UI layout is not current design authority. |
| `original-assets/docs/Legacy/image-1.png` | Visual support for historical quote/highlight card structure. | Product context terms: Highlight Insight, Smart Minutes Module, and Reference Output Pattern; converted asset: `converted-assets/product/reference-output-patterns.md`. | Image remains preserved as visual provenance only; names and quoted content are not promoted. |
| `original-assets/docs/Legacy/image-2.png` | Visual support for historical decision-card structure. | Product context terms: Decision Ledger, Smart Minutes Module, and Reference Output Pattern; converted asset: `converted-assets/product/reference-output-patterns.md`. | Image remains preserved as visual provenance only; meeting-specific decisions are not promoted. |
| `original-assets/docs/Legacy/智能纪要：示例集重构-新手任务清单 2026年2月3日.pdf` | Example output confirms Meeting Envelope, AI Review Notice, Action Track, Timeline Beats, and Related Links Section. Meeting-specific people and tasks are unrelated to InsightKit. | Product context terms: Meeting Envelope, AI Review Notice, Related Links Section, Smart Minutes Module, Reference Output Pattern; converted asset: `converted-assets/product/reference-output-patterns.md`. | The meeting content, participants, and task list remain example material only and are not used as test fixtures. |
| `original-assets/docs/architecture/insightkit-architecture.md` | Current architecture concepts are still real: native app, sidecar, RPC actions, InsightPackageV1, local store, and compliance safeguard. | Product context and Python Runtime context already carry Insight Package/RPC language; ADRs 0001, 0002, and 0004 now preserve the durable decisions. | Old absolute paths and compact architecture note remain historical. |
| `original-assets/docs/plans/2026-03-06-live-summary-lag-diagnosis.md` | Root-cause analysis remains valuable because current code now has runtime snapshots and prewarm watchdog behavior. | Python Runtime context: Runtime Snapshot and Prewarm Watchdog; macOS context already covers Capture State and Runtime Warmup. | Old run timings, stale stack samples, and March proof paths remain historical evidence. |
| `original-assets/docs/plans/2026-03-14-phase1-sidecar-split.md` | The sidecar module split is implemented and still shapes current runtime language. | ADR 0001 and Python Runtime context preserve the sidecar/action boundary; current code has `SessionHandler`, `ASRDispatcher`, `ProviderProbe`, `JobQueue`, and `InsightCoordinator`. | Task-by-task code snippets and commit instructions remain historical implementation detail. |
| `original-assets/docs/plans/2026-03-14-progressive-refactor-design.md` | The staged strategy produced current architecture decisions, but individual phase checklists are historical. | ADR 0001, ADR 0002, ADR 0004, macOS Session Shell/Session Phase terms, and release vocabulary. | Old phase sequencing, old test counts, and packaging notes remain historical. |
| `original-assets/docs/plans/2026-03-15-phase2-ipc-upgrade-design.md` | Persistent RPC and push events are current architecture. | ADR 0002 and Python Runtime term RPC Event. | Protocol-design draft details stay as background beneath ADR 0002. |
| `original-assets/docs/plans/2026-03-15-phase2-ipc-upgrade.md` | Implementation steps are historical, but PushBroker/RPCTransport/RPCCodec are current code. | ADR 0002 and Python Runtime term RPC Event. | Large task snippets and old expected commands remain historical. |
| `original-assets/docs/plans/2026-03-18-phase4-blueprint.md` | Current app workspaces and record review are real; step-by-step old build plan is historical. | macOS context terms: Session Shell, Session Phase, Panel Data Source, Record Index. | Old implementation order and per-step file chores remain historical. |
| `original-assets/docs/plans/2026-03-18-phase4-frontend-redesign.md` | Three-panel workspaces, notes, record search, and review structure are current; exact visual design spec is not authoritative. | macOS context terms: Session Shell, Session Phase, Panel Data Source, Record Index; Product context Record Folder and export concepts. | Color palette, old UI sketches, and old file list remain historical design notes. |
| `original-assets/docs/plans/2026-03-18-phase5-backend-completion.md` | Record folder persistence and `records.save` are current durable architecture. | ADR 0004; Product context Record Folder; Python Runtime terms Record Writer and Record Save Action. | Old step branches, line-count targets, and now-implemented tasks remain historical. |
| `original-assets/docs/plans/2026-05-21-local-asr-model-upgrade.md` | Model catalog and candidate-gating language are current; specific May machine snapshot is stale. | Python Runtime term ASR Model Catalog; existing ASR Runtime Profile and Strict Local ASR terms. | Old disk/dependency snapshot and deferred download plan remain historical. No current issue created because current code already carries newer Qwen/FluidAudio paths. |
| `original-assets/docs/plans/2026-05-23-insightkit-goal-evidence.md` | Product capability mapping remains a historical proof input; current claims must come from fresh verifiers. | Product terms and release Evidence Ledger vocabulary; source ledger points to the moved proof history. | Old proof paths and status counts remain release history only. |
| `original-assets/docs/plans/2026-05-24-insightkit-release-verification.md` | Release gate vocabulary is still useful; old build numbers are stale. | Release Workflow terms: Local Preflight, Developer ID Preflight, App Store Preflight, Secret Hygiene Gate, UI Hygiene Gate, Packaged-App Smoke, Visual GUI Proof. | Old proof paths, old test totals, and old build metadata remain historical evidence. |
| `original-assets/docs/plans/2026-05-26-insightkit-release-readiness-status.md` | Status vocabulary and owner-controlled blocker separation remain current. | ADR 0003; Release Workflow terms for preflights, evidence, and owner inputs. | Old build IDs, proof counts, and May 26 conclusion remain historical release snapshot. |
| `original-assets/docs/release/release-privacy-sandbox.md` | Privacy/sandbox boundary is still a release concern, but drafts are not published policy. | Release Workflow terms: Privacy Review Input, Sandbox Verification, and Public Distribution Readiness. ADR 0003 and `.scratch/public-distribution-readiness/` keep these as owner-controlled inputs for public distribution. | Original draft text remains preserved as provenance; do not treat it as current published policy or proof. |
| `original-assets/docs/release/release-privacy-policy-draft.md` | Useful owner-review input; not current legal text. | Release Workflow terms: Privacy Review Input and Public Distribution Readiness; `.scratch/public-distribution-readiness/issues/02-prepare-public-privacy-policy-url.md`. | Original draft policy remains preserved in Legacy; do not treat it as published privacy policy. |
| `original-assets/docs/release/release-app-store-privacy-answers.md` | Useful owner checklist for App Store Connect; not a repo-verifiable claim. | Release Workflow terms: App Store Preflight, Privacy Review Input, and Public Distribution Readiness; `.scratch/public-distribution-readiness/issues/03-finalize-app-store-privacy-answers.md`. | Original draft answers remain preserved in Legacy; final answers must come from owner-entered App Store Connect state. |

## Current Issue Decision

Most historical sources did not become new product or engineering issues because the useful content was already implemented in code, captured in current contexts/ADRs, or preserved as proof history. After owner review, the release/privacy sources became a current owner-controlled lane: `.scratch/public-distribution-readiness/`.

Current public-distribution issues created from historical release drafts:

- `.scratch/public-distribution-readiness/issues/01-confirm-release-channel-and-cloud-provider-boundary.md`
- `.scratch/public-distribution-readiness/issues/02-prepare-public-privacy-policy-url.md`
- `.scratch/public-distribution-readiness/issues/03-finalize-app-store-privacy-answers.md`
- `.scratch/public-distribution-readiness/issues/04-run-developer-id-distribution-preflight.md`
- `.scratch/public-distribution-readiness/issues/05-run-app-store-sandbox-distribution-preflight.md`

## Owner-Reviewed Legacy-Only Decisions

Historical implementation plans remain Legacy-only. This covers the March phase plans, the March live-summary diagnosis, and the May local ASR model-upgrade note.

Reason:

- Durable architecture decisions from those plans are already in ADRs.
- Still-valid product, runtime, app, and release vocabulary is already in current context docs.
- Current code has moved beyond old path names, old phase sequencing, old proof paths, and old test counts.
- Creating current issues from those plans would reintroduce stale instructions instead of starting from current code and current proof.

Future agents should create a fresh `.scratch` issue from current code only if one of those historical ideas becomes active work again.

Historical release proof/status ledgers remain Legacy release history. This covers:

- `original-assets/docs/plans/2026-05-23-insightkit-goal-evidence.md`
- `original-assets/docs/plans/2026-05-24-insightkit-release-verification.md`
- `original-assets/docs/plans/2026-05-26-insightkit-release-readiness-status.md`

Reason:

- Current release claims must come from fresh verifier output and fresh `proof.json`.
- The old build IDs, proof paths, test counts, and status conclusions are stale.
- The durable vocabulary from those ledgers is already in `docs/contexts/release-workflow/CONTEXT.md` and ADR 0003.
- Creating current issues from those ledgers would risk treating old evidence as current proof.

The historical architecture reference remains Legacy architecture reference. This covers:

- `original-assets/docs/architecture/insightkit-architecture.md`

Reason:

- Durable architecture decisions from this note are already captured by ADR 0001, ADR 0002, and ADR 0004.
- Current architecture language is already in Product, Python Runtime, and macOS App context docs.
- The old absolute paths and compact architecture summary are useful provenance, but they should not become a new ADR or current issue.
- Future architecture work should start from current code, accepted ADRs, context docs, and `docs/architecture-review-handoff.md`.

## Closure Summary

No unclassified moved originals remain.

Final counts:

- 21 moved original assets are listed in the Legacy manifest.
- 21 moved original assets have per-asset decisions in this audit.
- 8 converted assets are listed in the Legacy manifest and checked by `scripts/verify_project_normalization.py`.
- 6 current public-distribution assets were created under `.scratch/public-distribution-readiness/`.

Final disposition:

- Product structure content was absorbed into `docs/contexts/product/CONTEXT.md`, `historical-product-rationale.md`, and `reference-output-patterns.md`.
- Runtime, app, and release vocabulary was absorbed into current context docs.
- Durable architecture decisions were absorbed into ADR 0001, ADR 0002, ADR 0003, and ADR 0004.
- Release/privacy drafts were promoted into the current `.scratch/public-distribution-readiness/` lane.
- Stale implementation plans remain Legacy-only.
- Historical proof/status ledgers remain Legacy release history.
- The historical architecture note remains Legacy architecture reference.
- Original images, PDF content, old paths, old proof paths, and old task lists remain provenance only.

## Verification Expectations

`scripts/verify_project_normalization.py` should check this audit as a converted Legacy asset, check that the promoted standard terms above remain present in the current context docs and ADRs, and check that the current `.scratch/public-distribution-readiness/` assets still exist.
