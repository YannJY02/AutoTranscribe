# Canonical Meeting Asset Source PRD

Status: ready-for-agent

## Problem Statement

Saved InsightKit Records are stored as local Record Folders, but several user-visible paths can still interpret those folders independently. Record Review, exports, Smart Minutes generation, speaker rename, notes, recovery, search indexing, and diagnostics can drift if each path decides for itself which file is official.

This lane defines the Canonical Meeting Asset Source for saved Records: the Record Folder is the single official source, each user-visible content type has one official file, and all new read/write paths report asset health instead of silently substituting stale or temporary data.

## Goal

Record Review, export, transcript recovery, Smart Minutes generation, notes, speaker rename, and search indexing should agree on the same saved meeting asset state. Missing or damaged files should degrade clearly and recoverably without making alternate copies look official.

## User Stories

1. As a user, I want a reopened Record to show the same transcript, Smart Minutes, notes, and media that will be exported, so the app does not contradict itself.
2. As a user, I want edits such as speaker rename and Time-Bound Notes to update the saved Record, so future review and export use my corrections.
3. As a user, I want a Record with missing transcript or Smart Minutes to still open, so I can recover or regenerate what is missing.
4. As a user, I want old Records to keep opening even if they only have legacy `minutes.json`.
5. As a future agent, I want one meeting-asset read module, so Record Review, exports, and recovery do not duplicate file interpretation rules.
6. As a future agent, I want one meeting-asset write module, so user-visible edits are written atomically to the official Record Folder files.
7. As a future agent, I want asset health reported with the loaded content, so UI prompts and recovery actions do not have to guess which files are missing, fallback, or damaged.

## Accepted Product Decisions

1. The Canonical Meeting Asset Source direction is accepted.
2. A saved Record's Record Folder is the only official meeting-asset source.
3. Each user-visible content type inside a Record Folder should have one official file; other files are fallback or diagnostics only.
4. Smart Minutes should use `insight_package.json` as the official source. `minutes.json` is a legacy or degradation fallback.
5. Markdown/PDF export must read the same official meeting asset used by Record Review, not maintain an independent read path.
6. User edits in Record Review must write back to official Record Folder files.
7. Missing or damaged official files should keep the Record open when possible, show clear degraded state, and provide recovery actions where possible.
8. Record Review, export, recovery, and related flows should use one official meeting-asset read entrypoint.
9. The read entrypoint should return both content and Meeting Asset Health.
10. User-visible Record Folder modifications should use one official meeting-asset write entrypoint.
11. Official writes should be as all-or-nothing as practical: failures preserve the previous official version.
12. The first slice should not add an `asset_manifest.json`; use existing Record Folder files and health checks.
13. Record Index and search caches are rebuildable indexes, not official meeting-asset sources.
14. The first slice should unify new read/write paths and health state without migrating every historical Record or creating a new schema.
15. This lane is recorded in `.scratch/canonical-meeting-asset-source/` before implementation.

## Official File Rules

- Official metadata: `metadata.json`
- Official media: first valid `recording.*` media file selected by the canonical media rule.
- Official transcript: `transcript.json`
- Official Smart Minutes: `insight_package.json`
- Legacy Smart Minutes fallback: `minutes.json`
- Official notes: `notes.md`
- Diagnostics-only data: `capture_timeline.json` and similar proof or troubleshooting files.
- Rebuildable index/cache data: Record Index and search cache data.

## Implementation Decisions

- Deepen `MeetingAssetSnapshot` or replace it with a deeper meeting-asset read module that loads official content and health from a Record Folder.
- Add a matching write module or write-side interface for speaker rename, notes, transcript recovery, and Smart Minutes generation.
- Keep Record Review as an app-facing adapter that applies loaded content and health to user-visible state.
- Make `RecordDocumentExporter` consume the same loaded meeting asset instead of separately loading transcript or summary data.
- Keep `minutes.json` fallback readable for legacy Records, but do not use it as the new official Smart Minutes source.
- Keep writes local to the Record Folder and preserve ADR-0004.
- Do not make diagnostics sidecars part of the official user-visible asset model.

## Out of Scope

- Migrating all historical Record Folders.
- Creating `asset_manifest.json` or a new Record Folder schema version.
- Replacing the Python Record Writer.
- Replacing the native app or sidecar architecture.
- Replacing Unix socket JSON-RPC.
- Public distribution, signing, notarization, App Store, or privacy work.
- Making Record Index or search cache authoritative.

## Testing Decisions

- Add focused Swift tests for loading complete, missing, damaged, and legacy-fallback Record Folders.
- Add focused Swift tests for all-or-nothing write behavior where practical.
- Add export tests proving Markdown/PDF rendering uses the same meeting asset as Record Review.
- Add Record Review tests for degraded states and recovery affordances when official files are missing.
- Add focused tests for speaker rename and notes writeback through the write module.
- Run project normalization after publishing or updating this lane.

## Published Issues

- `.scratch/canonical-meeting-asset-source/issues/01-deepen-canonical-meeting-asset-source.md`

## Comments

### 2026-06-29 - Codex

Published after owner accepted the Canonical Meeting Asset Source architecture decisions.

### 2026-06-29 - Codex

Completed issue `01-deepen-canonical-meeting-asset-source`.

- `MeetingAssetSnapshot` is now the shared Record Folder read entrypoint with Meeting Asset Health.
- Record Review and export now consume the same meeting asset interpretation.
- Speaker rename and Time-Bound Notes save through canonical write helpers.
- `insight_package.json` is official for Smart Minutes; `minutes.json` remains a legacy fallback with health reporting.
- No new Record Folder schema or `asset_manifest.json` was introduced.

This lane is ready for human review. The accepted architecture implementation order moves next to Live Session Finalization.
