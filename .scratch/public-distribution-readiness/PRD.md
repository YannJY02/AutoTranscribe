# Public Distribution Readiness PRD

Status: ready-for-human

## Problem Statement

InsightKit has local release evidence and historical privacy/sandbox drafts, but those drafts are not yet a current public-distribution workflow. Future release work can confuse local readiness with public release readiness unless the owner-controlled privacy, sandbox, signing, notarization, and App Store Connect decisions are tracked as current `.scratch` work.

The historical release materials under `docs/Legacy/matt-workflow-library/original-assets/docs/release/` contain useful inputs, but they are not published policy and are not proof that a public release is ready.

## Solution

Create a current Public Distribution Readiness lane that turns the historical privacy and App Store materials into actionable owner-review tasks. Keep the original drafts in Legacy for provenance, but use this PRD and its issues for future work.

This lane covers two possible public channels:

- Developer ID direct distribution: a signed, notarized macOS app distributed outside the Mac App Store.
- Mac App Store distribution: a sandboxed app submitted through App Store Connect.

## User Stories

1. As the project owner, I want release-channel decisions tracked separately from local release proof, so that a passing local build is not mistaken for public distribution readiness.
2. As the project owner, I want the privacy policy draft turned into a current review task, so that it can be approved, replaced, and published before any store submission.
3. As the project owner, I want App Store privacy answers tracked as a current checklist, so that App Store Connect data disclosure is not copied blindly from historical notes.
4. As a release maintainer, I want Developer ID and Mac App Store gates separated, so that signing/notarization work does not blur into sandbox verification.
5. As a future agent, I want historical privacy drafts linked from current issues, so that provenance is clear without treating drafts as final legal text.

## Implementation Decisions

- Keep `Local Release Ready` and `Distribution Ready` separate.
- Treat the historical release drafts as `Privacy Review Input`, not as published policy.
- Use `ready-for-human` for this lane because privacy policy approval, App Store Connect entry, certificates, signing identities, and account access require owner action.
- Do not claim Developer ID readiness until signing, notarization, stapling, and Gatekeeper validation are completed against a real distribution build.
- Do not claim Mac App Store readiness until a sandboxed app signed with the correct distribution identity has passed file-access and sidecar verification under App Sandbox.
- Do not state that InsightKit is fully offline if optional cloud insight providers remain available in the submitted build.

## Testing Decisions

- Run current project-normalization verification after publishing this lane.
- Use `scripts/verify_release_closure.py` for local release closure only; it does not replace Developer ID or App Store owner gates.
- Run `scripts/release_preflight.sh` with the appropriate public-distribution mode only after certificates, account access, and final channel decisions are available.
- Record all public-distribution proof under `logs/diagnostics/` when those gates are run.

## Out of Scope For This Conversion Pass

- Publishing a privacy policy URL during this documentation conversion.
- Entering App Store Connect privacy answers during this documentation conversion.
- Acquiring or configuring Apple certificates during this documentation conversion.
- Signing, notarizing, stapling, uploading, or submitting a build during this documentation conversion.
- Changing runtime behavior, storage behavior, cloud-provider behavior, or app sandbox entitlements.
- Providing legal advice.

## Source Inputs

- `docs/Legacy/matt-workflow-library/original-assets/docs/release/release-privacy-sandbox.md`
- `docs/Legacy/matt-workflow-library/original-assets/docs/release/release-privacy-policy-draft.md`
- `docs/Legacy/matt-workflow-library/original-assets/docs/release/release-app-store-privacy-answers.md`
- `docs/contexts/release-workflow/CONTEXT.md`
- `docs/adr/0003-separate-local-readiness-from-public-distribution-readiness.md`

## Published Local Issues

- `.scratch/public-distribution-readiness/issues/01-confirm-release-channel-and-cloud-provider-boundary.md`
- `.scratch/public-distribution-readiness/issues/02-prepare-public-privacy-policy-url.md`
- `.scratch/public-distribution-readiness/issues/03-finalize-app-store-privacy-answers.md`
- `.scratch/public-distribution-readiness/issues/04-run-developer-id-distribution-preflight.md`
- `.scratch/public-distribution-readiness/issues/05-run-app-store-sandbox-distribution-preflight.md`

## Comments

### 2026-06-21 - Codex

Created this current owner-controlled public-distribution lane from the historical release/privacy drafts after owner approval.

Verification:
- `PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 -m pytest tests/test_verify_project_normalization.py -q` -> `15 passed`
- `/Users/yann.jy/miniconda3/bin/python3.11 scripts/verify_project_normalization.py --output-root logs/diagnostics/2026-06-21/project-normalization-20260621-public-distribution-readiness` -> `status: passed`, `findings: 0`
- Proof: `logs/diagnostics/2026-06-21/project-normalization-20260621-public-distribution-readiness/proof.json`
- `git diff --check` -> passed
