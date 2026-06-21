# Historical Implementation PRD

Status: historical-reference

## Problem Statement

Older implementation plans captured how InsightKit moved from a broad transcription tool toward the current local meeting-asset system. They were useful at the time, but their original locations made them look like active plans. Future agents need the history without confusing it for current work.

## Solution

Read the moved historical plans as a completed implementation story. Use current context docs, accepted ADRs, and `.scratch/` issues for new work.

Original planning assets now live under:

- `docs/Legacy/matt-workflow-library/original-assets/docs/plans/2026-03-06-live-summary-lag-diagnosis.md`
- `docs/Legacy/matt-workflow-library/original-assets/docs/plans/2026-03-14-phase1-sidecar-split.md`
- `docs/Legacy/matt-workflow-library/original-assets/docs/plans/2026-03-14-progressive-refactor-design.md`
- `docs/Legacy/matt-workflow-library/original-assets/docs/plans/2026-03-15-phase2-ipc-upgrade-design.md`
- `docs/Legacy/matt-workflow-library/original-assets/docs/plans/2026-03-15-phase2-ipc-upgrade.md`
- `docs/Legacy/matt-workflow-library/original-assets/docs/plans/2026-03-18-phase4-blueprint.md`
- `docs/Legacy/matt-workflow-library/original-assets/docs/plans/2026-03-18-phase4-frontend-redesign.md`
- `docs/Legacy/matt-workflow-library/original-assets/docs/plans/2026-03-18-phase5-backend-completion.md`
- `docs/Legacy/matt-workflow-library/original-assets/docs/plans/2026-05-21-local-asr-model-upgrade.md`

## User Stories

1. As a future agent, I want the old phase plans grouped together, so that I can understand project history without mistaking it for current work.
2. As a future agent, I want old architecture plans mapped to current ADRs, so that I know which decisions survived.
3. As a future agent, I want old UI plans mapped to current workspace vocabulary, so that I can talk about Live Workspace, Import Workspace, Records Workspace, and Record Review consistently.
4. As a future agent, I want local ASR history preserved, so that runtime work starts from the current ASR Runtime Profile instead of rediscovering old model decisions.
5. As the project owner, I want old plans moved into Legacy, so that the top-level docs stay focused on current authority.

## Implementation Decisions From History

- The Python Sidecar became the durable boundary for local runtime work.
- The macOS app remained the native user-facing shell.
- Unix socket JSON-RPC became the app-runtime communication path.
- Live and import workflows were separated into user-facing workspaces.
- Records became the durable local meeting-asset format.
- Local ASR capability became part of runtime readiness rather than a separate product.

## Current Authority

- Native app plus Python Sidecar: `docs/adr/0001-keep-native-macos-shell-with-python-sidecar.md`
- Persistent Unix socket RPC: `docs/adr/0002-use-persistent-unix-socket-rpc-for-app-runtime-communication.md`
- Product vocabulary: `docs/contexts/product/CONTEXT.md`
- Runtime vocabulary: `docs/contexts/python-runtime/CONTEXT.md`
- macOS workspace vocabulary: `docs/contexts/macos-app/CONTEXT.md`

## Testing Decisions

Historical plans are not proof. If a future task reactivates one of these ideas, use a fresh Matt loop:

1. Write a current PRD under `.scratch/<feature>/PRD.md`.
2. Split work into issue files under `.scratch/<feature>/issues/`.
3. Verify with current Swift, Python, release, or project-normalization gates.
4. Record proof paths in the current issue comments.

## Out of Scope

- Reopening old phase plans as active work.
- Treating old plan checklists as current acceptance criteria.
- Replacing accepted ADRs with historical plan text.
- Making release-readiness claims from historical planning notes.
