# Run Developer ID distribution preflight

Status: ready-for-human

## Parent

- `.scratch/public-distribution-readiness/PRD.md`

## What to build

After Developer ID distribution is chosen and signing credentials are available, produce a public direct-distribution build and run the required preflight checks.

Developer ID distribution means Apple signs the app for distribution outside the Mac App Store. Notarization means Apple checks the app package and issues a ticket so macOS Gatekeeper can trust it.

## Acceptance criteria

- [x] Developer ID distribution remains in scope after issue 01.
- [ ] Developer ID signing identity is available on the build machine.
- [ ] Hardened runtime is enabled for the distribution build.
- [ ] App is signed with the Developer ID identity.
- [ ] App is notarized by Apple.
- [ ] Notarization ticket is stapled to the app or package.
- [ ] Gatekeeper validation passes on the final artifact.
- [ ] Proof path under `logs/diagnostics/` is recorded in this issue comments.

## Blocked by

Developer ID signing identity, notarization credentials, and owner confirmation after Apple Developer account-permission clarification are required.

## Source inputs

- `docs/Legacy/matt-workflow-library/original-assets/docs/release/release-privacy-sandbox.md`
- `docs/contexts/release-workflow/CONTEXT.md`
- `scripts/release_preflight.sh`

## Comments

### 2026-06-23 - Decision input

The owner chose Developer ID direct distribution as the first public channel. This issue can proceed once the build machine has the required Developer ID signing identity and notarization credentials.

The submitted public build may include optional BYOK cloud providers, so direct-distribution privacy and release notes must not claim the app is fully offline.

### 2026-06-23 - Account permission pause

The owner is waiting for Apple official clarification about account membership and permission boundaries before purchasing or using Developer ID distribution credentials.

Do not start signing, notarization, or certificate-generation work until that clarification is available and the owner confirms the account/team identity to use.
