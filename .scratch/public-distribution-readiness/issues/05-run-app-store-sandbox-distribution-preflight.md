# Run App Store sandbox distribution preflight

Status: ready-for-human

## Parent

- `.scratch/public-distribution-readiness/PRD.md`

## What to build

After Mac App Store distribution is chosen and App Store signing access is available, produce a sandboxed build and verify that records, imports, exports, optional cloud providers, and the Python sidecar still work under App Sandbox.

App Sandbox means macOS restricts what the app can access by default. The app must use declared entitlements and user-approved file access instead of freely reading and writing anywhere.

## Acceptance criteria

- [ ] Mac App Store distribution remains in scope after issue 01.
- [ ] App Store distribution signing identity and provisioning are available.
- [ ] App embeds the intended App Store sandbox entitlements.
- [ ] Default record storage works inside the app container.
- [ ] User-selected import/export file access works under App Sandbox.
- [ ] Persisted custom record roots use security-scoped bookmarks when needed.
- [ ] Python sidecar and bundled runtime behavior are verified under sandbox constraints, or a product decision excludes them from the App Store channel.
- [ ] Optional cloud providers use the correct network-client entitlement if included.
- [ ] Proof path under `logs/diagnostics/` is recorded in this issue comments.

## Blocked by

- `.scratch/public-distribution-readiness/issues/01-confirm-release-channel-and-cloud-provider-boundary.md`
- `.scratch/public-distribution-readiness/issues/02-prepare-public-privacy-policy-url.md`
- `.scratch/public-distribution-readiness/issues/03-finalize-app-store-privacy-answers.md`

## Source inputs

- `docs/Legacy/matt-workflow-library/original-assets/docs/release/release-privacy-sandbox.md`
- `docs/Legacy/matt-workflow-library/original-assets/docs/release/release-app-store-privacy-answers.md`
- `macos/InsightKitApp/InsightKitApp.AppStore.entitlements`
- `scripts/release_preflight.sh`

