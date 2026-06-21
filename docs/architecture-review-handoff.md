# Architecture Review Handoff

Status: current
Last reviewed: 2026-06-21

Use this before running `improve-codebase-architecture` or proposing deep module work. It is a routing surface, not a new architecture decision.

## Read First

- `CONTEXT-MAP.md`
- `docs/project-normalization-source-ledger.md`
- `docs/contexts/product/CONTEXT.md`
- `docs/contexts/python-runtime/CONTEXT.md`
- `docs/contexts/macos-app/CONTEXT.md`
- `docs/contexts/release-workflow/CONTEXT.md`
- `docs/contexts/integrations/CONTEXT.md`

## Accepted ADRs

- `docs/adr/0001-keep-native-macos-shell-with-python-sidecar.md`: preserve the native macOS shell plus Python sidecar architecture.
- `docs/adr/0002-use-persistent-unix-socket-rpc-for-app-runtime-communication.md`: preserve local Unix socket JSON-RPC with persistent NDJSON framing for live workflows.
- `docs/adr/0003-separate-local-readiness-from-public-distribution-readiness.md`: keep Local Release Ready and Distribution Ready as separate claims.
- `docs/adr/0004-use-local-record-folders-with-runtime-record-writer.md`: preserve local Record Folders written through the Python runtime RecordWriter.

## Current Source Assets

- Current product and domain language: context docs under `docs/contexts/`.
- Current architecture reference: `docs/Legacy/matt-workflow-library/converted-assets/architecture/architecture-decision-map.md`, subordinate to accepted ADRs.
- Legacy content promotion audit: `docs/Legacy/matt-workflow-library/converted-assets/planning/content-promotion-audit.md`.
- Current release evidence ledger: `docs/Legacy/matt-workflow-library/converted-assets/release/release-proof-index.md`.
- Current release closure command: `python3 scripts/verify_release_closure.py`.
- Current normalization verifier: `python3 scripts/verify_project_normalization.py`.
- Current AttentionOS External Host Contract: `docs/attentionos-integration.md` plus generated module README from `insightkit/integration/attentionos_bridge.py`.

## Preserve These Decisions

- Do not replace the native SwiftUI app with a web shell as part of architecture cleanup.
- Do not replace the Python Sidecar with a remote service assumption.
- Do not replace the persistent Unix socket RPC seam with HTTP unless a future ADR explicitly reopens ADR-0002.
- Do not split record persistence into competing Swift and Python JSON writers unless a future ADR explicitly reopens ADR-0004.
- Do not treat Apple account, certificate, notarization, sandbox, App Store Connect, or privacy URL requirements as local code bugs.
- Do not rewrite historical AutoTranscribe materials as current InsightKit truth; mark lineage explicitly.

## Friction Areas To Explore

- **ASR Runtime Profile**: continue deepening engine selection, model readiness, Runtime Warmup, backend status, and Diarization reporting behind one Python runtime interface.
- **Live Workspace Session**: `LiveSessionViewModel` and extensions still combine capture, Runtime Warmup, provider policy, Live Transcript Delta, Final Insight Generation, Record save, and panel data.
- **Swift RPC Action Client**: `InsightRPCClient` still carries transport, retry, breaker, dictionary encoding, and result decoding rules despite existing `RPCCodec` and `RPCTransport` modules.
- **Sidecar Action Registry**: JSON-RPC dispatch, Module Bridge, capabilities, and AttentionOS export still duplicate Bridge Action knowledge.
- **Record Folder**: Python write logic, Swift index loading, Record Review loading, search text, and Markdown/PDF export all know the persisted record folder schema protected by ADR-0004.

## Release Blockers Are Not Architecture Candidates

External Blockers and Owner-Controlled Inputs belong to the Release Workflow context. Architecture work may improve local verification, packaging reliability, or release evidence clarity, but it should not claim Distribution Ready without the required Apple-controlled inputs.

## Verification Before Calling A Candidate Done

- For Python runtime or sidecar work, run focused Python tests and the relevant direct script invocation.
- For Swift/macOS work, run targeted Swift tests first; use packaged-app smoke or visual GUI proof only when the user-visible workflow or installed app behavior changed.
- For documentation normalization work, run `python3 scripts/verify_project_normalization.py`.
- For release claims, use `python3 scripts/verify_release_closure.py` or the narrower release verifier that supports the claim.
