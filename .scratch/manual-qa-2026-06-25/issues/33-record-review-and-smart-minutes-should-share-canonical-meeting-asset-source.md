# Record Review and Smart Minutes should share a canonical meeting asset source

Status: ready-for-human

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

The owner observed that Record Review and Smart Minutes review appear to show different or separately prepared content for the same recording.

The owner is not yet certain whether this is a confirmed bug, but the current experience creates the impression that the app may be using two different resources instead of one shared meeting asset.

## What I expected

For one Record, Record Review and Smart Minutes review should feel like two views over the same meeting asset.

The media, transcript, timestamps, notes, speaker labels, and Smart Minutes evidence should remain consistent across both surfaces unless the app clearly explains why one surface is showing a different state.

## Steps to reproduce

1. Launch the installed InsightKit app.
2. Create a Live Workspace recording with media, transcript rows, and generated Smart Minutes.
3. Open the Smart Minutes review surface and inspect the media, transcript, timestamps, speaker labels, and summary content.
4. Open the same saved Record from the Records Workspace.
5. Compare whether the visible media, transcript, timestamps, speaker labels, and Smart Minutes content appear to come from the same meeting asset.

## Blocked by

None - the product decision is recorded in `.scratch/manual-qa-2026-06-25/canonical-meeting-asset-decision-map.md`.

## Additional context

The owner wants to discuss whether Record Review and Smart Minutes should be unified around one canonical source.

This issue is related to issue 27 because duplicated or transformed media resources may be contributing to playback audio quality differences. It is also related to issues 20-24 because those issues covered Smart Minutes review-source playback consistency.

## Comments

### 2026-06-26 - Manual QA

The owner raised this as a product/architecture concern rather than a fully confirmed bug.

Initial classification: `needs-info`.

### 2026-06-26 - Decision mapped

Decision:

- Record Review and Smart Minutes should be two views over one canonical Meeting Asset source.
- The canonical source should include the review media, Media-Timed Transcript, speaker-name mapping, notes, and Insight Package.
- When a clean original recording already exists, playback surfaces should use it directly instead of silently replacing it with a separately transformed review resource.
- If audio/video composition is unavoidable, the composed output should become the one canonical review media source used by both Record Review and Smart Minutes, and it must be verified against the original audio for quality and sync.

Decision map:

- `.scratch/manual-qa-2026-06-25/canonical-meeting-asset-decision-map.md`

Current classification: `ready-for-agent`.

### 2026-06-26 - Code fix installed for owner retest

Status changed to `ready-for-human`.

Implemented:

- Added a shared `MeetingAssetSnapshot` reader for Record Folder assets.
- Record Review now prefers the full `insight_package.json` as the canonical Smart Minutes source when it exists, then falls back to `minutes.json`.
- Markdown/PDF export now uses the same Meeting Asset snapshot for notes, media selection, and Smart Minutes content.
- Import recovery and Record thumbnail generation now use the same canonical `recording.*` selection rule.
- When Record Review generates Smart Minutes, it now writes both `minutes.json` and the full `insight_package.json`.

Proof:

- RED: `swift test --package-path macos/InsightKitApp --filter RecordsIndexServiceTests/testRecordReviewPrefersInsightPackageAsCanonicalSmartMinutesSource` failed because Record Review used `minutes.json` instead of `insight_package.json`.
- GREEN: the same focused test passed after implementation.
- RED: `swift test --package-path macos/InsightKitApp --filter RecordDocumentExporterTests/testMarkdownExportPrefersInsightPackageAsCanonicalSmartMinutesSource` failed because export still used flattened fallback minutes.
- GREEN: the same focused test passed after implementation.
- Related gate: `swift test --package-path macos/InsightKitApp --filter RecordsIndexServiceTests --filter RecordDocumentExporterTests --filter MediaSeekRequestTests`, 35 tests, 0 failures.
- Full Swift gate: `swift test --package-path macos/InsightKitApp`, 182 tests, 0 failures.
- Standard sync: `bash scripts/sync_insightkit_app.sh` passed Swift and Python gates, including 139 Python tests, and installed build `20260626221051` to `/Users/yann.jy/Applications/InsightKit.app`.
- `codesign --verify --deep --strict --verbose=2 /Users/yann.jy/Applications/InsightKit.app` passed.

Human retest:

1. Launch `/Users/yann.jy/Applications/InsightKit.app`, build `20260626221051`.
2. Open a saved Record that has generated Smart Minutes.
3. Compare Record Review against the Smart Minutes result from the live flow.
4. Confirm media, transcript timestamps, speaker labels, notes, Smart Minutes modules, and export content feel like they come from the same Record.

### 2026-06-27 - Owner retest passed

The owner confirmed issue 33 is resolved after the canonical Meeting Asset fix. Record Review and Smart Minutes now behave as views over the same saved Record assets for the checked workflow.
