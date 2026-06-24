# Finalize App Store privacy answers

Status: ready-for-human

## Parent

- `.scratch/public-distribution-readiness/PRD.md`

## What to build

Use the historical App Store privacy-answer draft as a checklist, then enter final answers in App Store Connect after the release channel and cloud-provider boundary are decided.

App Store Connect is Apple's web system for app metadata, privacy disclosures, builds, review, and release management.

## Acceptance criteria

- [ ] App Store Connect app record exists if Mac App Store distribution is in scope.
- [ ] Privacy policy URL from issue 02 is available.
- [ ] Final answers cover audio data, transcripts, summaries, notes, exports, search history, product interaction, crash data, diagnostics, identifiers, and optional third-party processing.
- [ ] Optional BYOK cloud-provider behavior is either disabled in the submitted build or disclosed accurately.
- [ ] Any analytics, crash uploader, telemetry SDK, account system, or sync service added later is reflected in the answers.
- [ ] Final App Store privacy answers are recorded as completed in this issue comments.

## Blocked by

- `.scratch/public-distribution-readiness/issues/01-confirm-release-channel-and-cloud-provider-boundary.md`
- `.scratch/public-distribution-readiness/issues/02-prepare-public-privacy-policy-url.md`

## Source inputs

- `docs/Legacy/matt-workflow-library/original-assets/docs/release/release-app-store-privacy-answers.md`
- `docs/Legacy/matt-workflow-library/original-assets/docs/release/release-privacy-policy-draft.md`

## Comments

### 2026-06-23 - Channel status

The owner chose Developer ID direct distribution as the first public channel. Do not start App Store Connect privacy-answer entry unless the owner later brings Mac App Store distribution back into scope.

If Mac App Store distribution is pursued later, optional BYOK cloud providers must be disclosed accurately as optional third-party processing instead of describing the submitted build as local-only.
