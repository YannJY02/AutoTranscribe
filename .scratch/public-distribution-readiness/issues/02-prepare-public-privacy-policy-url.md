# Prepare public privacy policy URL

Status: ready-for-human

## Parent

- `.scratch/public-distribution-readiness/PRD.md`

## What to build

Review the historical privacy policy draft, replace or approve the text, and publish a public privacy policy URL suitable for the chosen release channel.

The historical draft is a review input. It is not legal advice and is not current published policy.

## Acceptance criteria

- [ ] Privacy policy text is owner-approved or replaced by a legally reviewed version.
- [ ] The policy accurately describes local record storage, transcripts, notes, exports, runtime settings, and provider keys.
- [ ] The policy matches the release-channel decision from issue 01.
- [ ] The policy does not claim that all processing is offline when optional cloud insight providers are included.
- [ ] Public privacy policy URL is available for release metadata or App Store Connect.
- [ ] The final URL is recorded in this issue comments or the release workflow context if it becomes a standing release input.

## Blocked by

Owner-approved privacy policy text and a public URL are required.

## Source inputs

- `docs/Legacy/matt-workflow-library/original-assets/docs/release/release-privacy-policy-draft.md`
- `docs/Legacy/matt-workflow-library/original-assets/docs/release/release-privacy-sandbox.md`

## Comments

### 2026-06-23 - Decision input

Issue 01 is no longer blocking channel selection. The owner chose Developer ID direct distribution first and allowed optional BYOK cloud providers in the submitted public build.

The privacy policy must not claim that InsightKit is fully offline while optional BYOK cloud providers are included. The policy should describe local storage and explain that cloud processing happens only when the user supplies and enables their own provider key.
