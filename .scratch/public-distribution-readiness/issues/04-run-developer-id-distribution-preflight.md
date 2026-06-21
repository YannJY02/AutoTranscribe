# Run Developer ID distribution preflight

Status: ready-for-human

## Parent

- `.scratch/public-distribution-readiness/PRD.md`

## What to build

After Developer ID distribution is chosen and signing credentials are available, produce a public direct-distribution build and run the required preflight checks.

Developer ID distribution means Apple signs the app for distribution outside the Mac App Store. Notarization means Apple checks the app package and issues a ticket so macOS Gatekeeper can trust it.

## Acceptance criteria

- [ ] Developer ID distribution remains in scope after issue 01.
- [ ] Developer ID signing identity is available on the build machine.
- [ ] Hardened runtime is enabled for the distribution build.
- [ ] App is signed with the Developer ID identity.
- [ ] App is notarized by Apple.
- [ ] Notarization ticket is stapled to the app or package.
- [ ] Gatekeeper validation passes on the final artifact.
- [ ] Proof path under `logs/diagnostics/` is recorded in this issue comments.

## Blocked by

- `.scratch/public-distribution-readiness/issues/01-confirm-release-channel-and-cloud-provider-boundary.md`

## Source inputs

- `docs/Legacy/matt-workflow-library/original-assets/docs/release/release-privacy-sandbox.md`
- `docs/contexts/release-workflow/CONTEXT.md`
- `scripts/release_preflight.sh`

