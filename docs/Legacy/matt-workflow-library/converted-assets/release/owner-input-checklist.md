# Owner Input Checklist

Status: owner-review-reference

## Purpose

This file translates moved privacy and distribution materials into an owner checklist. Owner inputs are things an agent should not invent: account access, certificates, public URLs, legal text, and final App Store answers.

Original owner-review sources:

- `docs/Legacy/matt-workflow-library/original-assets/docs/release/release-privacy-sandbox.md`
- `docs/Legacy/matt-workflow-library/original-assets/docs/release/release-privacy-policy-draft.md`
- `docs/Legacy/matt-workflow-library/original-assets/docs/release/release-app-store-privacy-answers.md`

## Owner Inputs

- Final release channel: local-only, Developer ID direct distribution, Mac App Store, or another path.
- Paid or active Apple Developer Program access if public distribution is wanted.
- Developer ID Application certificate for direct distribution.
- Notarization credentials for `notarytool`.
- App Store distribution identity and provisioning if App Store is chosen.
- Public privacy policy URL.
- Final App Store Connect privacy answers.
- Legal review of privacy policy wording.

## Current Agent Rule

Agents may update local references and run local checks, but should stop before:

- creating or using Apple credentials;
- claiming notarized distribution;
- claiming App Store readiness;
- publishing privacy policy text;
- entering App Store Connect answers;
- deciding the final public release channel on behalf of the owner.

## Current Verification Rule

If a task changes release wording, run the appropriate release gate. If it only moves historical documents into this library, use project-normalization verification and do not claim release readiness.
