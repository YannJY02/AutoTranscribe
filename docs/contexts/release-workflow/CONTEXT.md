# Release Workflow

Language for judging whether InsightKit is ready for local QA, internal use, direct distribution, or App Store submission. This context separates evidence from aspiration.

## Language

**Canonical Installed App**:
The app bundle currently treated as the local truth for installed-app validation.
_Avoid_: Build output, dist app

**Local Release Ready**:
Ready for local or internal QA on the current Mac, without claiming public distribution readiness.
_Avoid_: Released, done

**Distribution Ready**:
Ready for the chosen public distribution channel with signing, notarization or App Store requirements satisfied.
_Avoid_: Local release ready

**Public Distribution Readiness**:
The GitHub Issue lane for owner-controlled release-channel, privacy policy, App Store privacy-answer, Developer ID, and App Store sandbox work. Retained `.scratch` files are migration history.
_Avoid_: Legacy privacy draft, local release closure

**External Blocker**:
A remaining requirement controlled outside the repo, such as Apple account access, certificates, notarization credentials, App Store Connect metadata, or a public privacy URL.
_Avoid_: Failing test, bug

**Owner-Controlled Input**:
Information or credential material that only the project owner can provide.
_Avoid_: Missing config, TODO

**Release Channel**:
The selected distribution route: local-only, Developer ID direct distribution, or Mac App Store.
_Avoid_: Build mode

**Proof JSON**:
A machine-readable evidence artifact produced by a verifier or smoke test.
_Avoid_: Log, report

**Closure Gate**:
A bounded command or evidence set used to decide whether a release claim is supported.
_Avoid_: Checklist item

**Local Preflight**:
The local-channel release gate that checks the installed app bundle and local runtime without claiming Developer ID or App Store readiness.
_Avoid_: Final release check

**Developer ID Preflight**:
The direct-distribution gate for Developer ID signing, hardened runtime, notarization, stapling, and Gatekeeper validation.
_Avoid_: Local codesign

**App Store Preflight**:
The Mac App Store gate for distribution identity, embedded sandbox entitlements, App Store metadata, and privacy URL readiness.
_Avoid_: Sandbox test only

**Packaged-App Smoke**:
A validation pass against the installed app bundle and its app-owned runtime, using a real import path.
_Avoid_: Script test, unit test

**Visual GUI Proof**:
Evidence that the actual app UI completed the intended user flow.
_Avoid_: Screenshot

**Personal Local Degradation**:
A deliberate local-personal substitute for a cloud or team feature from the reference product.
_Avoid_: Regression, incomplete feature

**Evidence Ledger**:
A document or proof set that records which claims are verified, locally ready, externally blocked, or incomplete.
_Avoid_: Status doc

**Secret Hygiene Gate**:
The verifier pass that checks release-relevant text surfaces for high-confidence hardcoded secrets before a release claim is trusted.
_Avoid_: Manual key search

**UI Hygiene Gate**:
The verifier pass that checks app source for release-blocking placeholder controls, empty actions, or permanently disabled controls.
_Avoid_: Visual polish pass

**Privacy Review Input**:
Owner-reviewed release material for privacy policy text, App Store privacy answers, optional provider disclosure, and public privacy URL requirements.
_Avoid_: Published privacy policy

**Sandbox Verification**:
The App Store-channel proof that record roots, security-scoped bookmarks, bundled runtime behavior, file access, and optional network permissions work under App Sandbox.
_Avoid_: Local QA entitlement
