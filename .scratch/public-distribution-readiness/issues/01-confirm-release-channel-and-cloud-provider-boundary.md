# Confirm release channel and cloud provider boundary

Status: ready-for-human

## Parent

- `.scratch/public-distribution-readiness/PRD.md`

## What to decide

Choose the first public distribution channel and decide whether the submitted build includes optional cloud insight providers.

The key decision is not whether the local app works. The key decision is what the public build is allowed to do:

- Developer ID direct distribution outside the Mac App Store.
- Mac App Store distribution through App Store Connect.
- Local-only insight generation in the submitted build.
- Optional BYOK cloud insight providers in the submitted build.

BYOK means "bring your own key": the user enters their own provider API key, and the app uses that provider only when the user enables it.

## Acceptance criteria

- [x] First public channel is chosen: Developer ID, Mac App Store, or both with an order.
- [x] Submitted-build cloud behavior is chosen: local-only or optional BYOK cloud providers.
- [x] Any privacy-policy language that depends on this choice is identified.
- [x] Any App Store privacy answers that depend on this choice are identified.
- [x] The decision is recorded in this issue comments or a follow-up ADR if it becomes a durable product decision.

## Blocked by

None - owner decision recorded on 2026-06-23.

## Source inputs

- `docs/Legacy/matt-workflow-library/original-assets/docs/release/release-privacy-sandbox.md`
- `docs/Legacy/matt-workflow-library/original-assets/docs/release/release-app-store-privacy-answers.md`
- `docs/adr/0003-separate-local-readiness-from-public-distribution-readiness.md`

## Comments

### 2026-06-23 - Owner decision

The first public distribution channel is Developer ID direct distribution.

Mac App Store distribution is not the first channel. Keep App Store privacy-answer and sandbox work as future-channel work unless the owner later chooses to pursue Mac App Store distribution.

The submitted public build may include optional BYOK cloud providers. BYOK means the user supplies their own provider API key and enables the provider themselves.

Privacy-policy language must therefore disclose:
- local record storage, transcripts, notes, exports, runtime settings, and provider keys;
- optional cloud processing when a user enables a BYOK provider;
- that transcripts, prompts, summaries, or related meeting content may be sent to the selected provider only when the user enables that provider;
- that the app should not be described as fully offline if the submitted build includes optional BYOK cloud providers.

If Mac App Store distribution is pursued later, App Store privacy answers must disclose optional third-party processing accurately instead of treating the app as local-only.
