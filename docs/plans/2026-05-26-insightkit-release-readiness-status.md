# InsightKit Release Readiness Status - 2026-05-26

This is the current evidence ledger for the goal of making InsightKit a personal-user Feishu/Lark Minutes alternative. It separates product readiness from Apple/account-owned distribution gates so the project can keep moving without repeatedly conflating local development with notarized or App Store release.

Repeatable proof command for this status snapshot: `python3 scripts/verify_release_readiness.py`.

Latest machine-readable proof: `logs/diagnostics/2026-05-26/release-readiness-status-20260526-120328/proof.json`.

## Status Vocabulary

| Status | Meaning |
| --- | --- |
| `implemented/verified` | Current code and artifacts prove the requirement with real media, tests, app runtime evidence, or release checks. |
| `local-release-ready` | Ready for local/internal QA on this Mac, but not a public distribution claim. |
| `personal-local-degradation` | A deliberate local-personal substitute for a cloud/team feature in `docs/Legacy/overview.md`. |
| `externally-blocked` | Requires Apple account, certificates, credentials, App Store Connect, public URLs, or other owner-controlled input. |
| `needs-channel-decision` | Requires deciding whether the target channel is local-only, Developer ID direct distribution, or Mac App Store. |
| `not-complete` | Still missing implementation or strong enough evidence. |

## Official Apple Requirements Checked

Checked on 2026-05-26:

- Developer ID direct distribution requires Developer ID signing and notarization. Apple also notes Developer ID certificates require Apple Developer Program / Enterprise Program access: <https://developer.apple.com/developer-id/> and <https://developer.apple.com/support/developer-id/>.
- Mac App Store apps need App Sandbox capability for submission: <https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox/>.
- Sandboxed macOS file access requires user-selected access and security-scoped bookmarks for persistent access: <https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox>.
- App Store privacy details and a public privacy policy URL are required in App Store Connect: <https://developer.apple.com/app-store/app-privacy-details/> and <https://developer.apple.com/help/app-store-connect/reference/app-information/app-privacy>.

## Current Canonical Artifact

| Item | Current evidence | Status |
| --- | --- | --- |
| Canonical installed app | `/Users/yann.jy/Applications/InsightKit.app` | `local-release-ready` |
| Bundle ID | `com.yannjy.insightkit` in installed `Info.plist` | `implemented/verified` |
| Version/build | `CFBundleShortVersionString=0.1.0`, `CFBundleVersion=20260526113744` | `implemented/verified` |
| URL import scheme | `CFBundleURLTypes` includes `insightkit` | `implemented/verified` |
| Icon and usage descriptions | `InsightKit.icns`; microphone/camera/screen-capture usage strings in installed `Info.plist` | `implemented/verified` |
| Local signing | Apple Development signed; strict codesign passes before and after runtime smoke | `local-release-ready` |
| Runtime bundle immutability | App-owned Python children set `PYTHONDONTWRITEBYTECODE=1`; no `__pycache__` generated under the signed runtime after import smoke | `implemented/verified` |

## Product Capability Ledger

| Requirement from `docs/Legacy/overview.md` | Current state | Evidence | Status |
| --- | --- | --- | --- |
| AI summary view: summary, quote, speaker summary, decisions, actions, chapters | Visible in record review and persisted in insight/minutes files | `logs/diagnostics/2026-05-26/current-build-visual-gui-proof-20260526-113744.json`; `logs/diagnostics/2026-05-26/packaged-app-url-import-smoke-20260526-113806/proof.json` | `implemented/verified` |
| Minutes/export view: meeting envelope, AI disclaimer, structured summary, actions, chapters, related links, Markdown/PDF | Markdown/PDF produced from real record; required sections and PDF header verified | URL smoke proof plus exports under `logs/diagnostics/2026-05-26/packaged-app-url-import-smoke-20260526-113806/exports/` | `implemented/verified` |
| Audio/video import | App-owned URL import smoke imports real `.m4a`; GUI proof restores the imported record | `python3 scripts/run_packaged_app_url_import_smoke.py` proof and current visual GUI proof | `implemented/verified` |
| Realtime recording path | Local live recording fallback persists combined WAV chunks and generated live minutes | `logs/diagnostics/2026-05-24/live-recording-media-proof.json`; `logs/diagnostics/2026-05-25/live-final-minutes-persistence-proof.json` | `personal-local-degradation` |
| Timestamped transcript | 11 timestamped rows for the current real sample | URL smoke proof; record folder `transcript.json` | `implemented/verified` |
| Speaker labels | Current real sample has `spk0`/`spk1`; fallback labels exist when diarization is unavailable | URL smoke proof; `docs/plans/2026-05-23-insightkit-goal-evidence.md` | `implemented/verified` with conservative degradation |
| Media jump from chapter/transcript/note | Current visual GUI proof clicked all three and saw visible seek statuses | `current-build-visual-gui-proof-20260526-113744.json` | `implemented/verified` |
| Search/filter/records management | Records search changed visible count from `34` to `3`; filters and list visible | Current visual GUI proof | `implemented/verified` |
| Time-bound notes | Persisted note `00:05 E2E verification note bound to playback time`; note click seeks media | Current visual GUI proof; URL smoke proof | `implemented/verified` |
| Restart recovery | Latest record appears in Home/Records and restores media/minutes/transcript/note/export controls | Current visual GUI proof paired with URL smoke proof | `implemented/verified` |
| Team/cloud collaboration parts of Feishu Minutes | Not implemented as cloud/team collaboration; local personal record folders and exports are the substitute | Privacy/sandbox notes and architecture boundary | `personal-local-degradation` |

## Engineering Verification Ledger

| Gate | Latest result | Status |
| --- | --- | --- |
| Swift tests | `swift test --package-path macos/InsightKitApp`: `115 tests, 0 failures` | `implemented/verified` |
| Python tests | `./scripts/run_python_tests.sh`: `172 passed, 1 warning` | `implemented/verified` |
| Installed-app real import smoke | `python3 scripts/run_packaged_app_url_import_smoke.py`: passed on build `20260526113744` | `implemented/verified` |
| Visual GUI proof | Computer Use proof and PNG screenshot saved for build `20260526113744` | `implemented/verified` |
| SQLite/FTS | URL smoke validates app DB FTS query `left` with result count `1` | `implemented/verified` |
| Insight schema | URL smoke validates `insight_schema_ok=true` | `implemented/verified` |
| Markdown/PDF export | URL smoke validates required Markdown sections and `%PDF-` PDF header | `implemented/verified` |
| Process cleanup | `scripts/dev_quit_insightkit_processes.sh` and `scripts/dev_check_insightkit_processes.sh` show no app, sidecar, or socket residue | `implemented/verified` |
| Local release preflight | `scripts/release_preflight.sh /Users/yann.jy/Applications/InsightKit.app`: exits `0` | `local-release-ready` |
| Developer ID preflight | `scripts/release_preflight.sh --developer-id /Users/yann.jy/Applications/InsightKit.app`: exits `1` for missing Developer ID identity/signature, hardened runtime, and clean Gatekeeper proof | `externally-blocked` |
| App Store preflight | `scripts/release_preflight.sh --app-store /Users/yann.jy/Applications/InsightKit.app`: exits `1` for distribution identity, embedded sandbox entitlements, and privacy policy URL | `externally-blocked` / `needs-channel-decision` |
| Release readiness verifier | `python3 scripts/verify_release_readiness.py`: exits `0`, writes `status=passed_with_external_blockers` | `local-release-ready` with external blockers |
| Secret hygiene verifier | `python3 scripts/verify_secret_hygiene.py`: exits `0`, scans `267` files and writes `0` findings | `implemented/verified` |
| UI hygiene verifier | `python3 scripts/verify_ui_hygiene.py`: exits `0`, scans `75` Swift source files and writes `0` findings | `implemented/verified` |
| Goal evidence verifier | `python3 scripts/verify_goal_evidence.py`: exits `0`, writes `status=local_personal_loop_verified_with_external_distribution_blockers` with `25` verified requirements | `implemented/verified` with external blockers |

## Release Channel Ledger

| Channel | Current state | Blocking evidence | Next unlock |
| --- | --- | --- | --- |
| Local/internal QA | Works on this Mac with Apple Development signing and strict codesign | Local preflight exits `0`; URL smoke and GUI proof pass | Continue feature/UI hardening; no Apple account action required |
| Direct distribution outside App Store | Not publicly distributable yet | `security find-identity -v -p codesigning` shows only Apple Development identities; Developer ID preflight exits `1` | Owner joins/uses paid Apple Developer Program, creates Developer ID Application certificate, builds with hardened runtime, configures notarytool credentials, runs notarization/stapling script |
| Mac App Store | Not ready | App Store preflight exits `1`; current installed app lacks Mac App Store distribution signature and embedded sandbox entitlements; privacy URL not configured | Owner chooses App Store channel, provides distribution identity/profiles, publishes privacy policy URL, verifies sandboxed app with file bookmarks and sidecar strategy |

## Current Local Config And Entitlements

| Surface | Current state | Status |
| --- | --- | --- |
| Local entitlements | `macos/InsightKitApp/InsightKitApp.entitlements` has sandbox `false`, audio input `true`, camera `true` | `local-release-ready` |
| App Store entitlements draft | `macos/InsightKitApp/InsightKitApp.AppStore.entitlements` has sandbox `true`, audio input, camera, user-selected read/write, app-scoped bookmarks, network client | `needs-channel-decision` |
| Installed app embedded entitlements | Current SwiftPM local app does not expose valid embedded App Store sandbox entitlements | `externally-blocked` for App Store |
| Privacy/sandbox note | `docs/release-privacy-sandbox.md` exists | `implemented/verified` |
| Privacy policy draft | `docs/release-privacy-policy-draft.md` exists, but is not a public URL | `owner-deferred` |
| App Store privacy answers draft | `docs/release-app-store-privacy-answers.md` exists | `owner-deferred` |

## Explicit Personal-Version Degradations

| Feishu/Lark Minutes style capability | Personal local substitute | Status |
| --- | --- | --- |
| Team workspace and cloud sharing | Local record folder, searchable local index, Markdown/PDF export for manual sharing | `personal-local-degradation` |
| Cloud-hosted canonical meeting asset | Local `~/Documents/InsightKit/Records/<record>` folder plus app DB/FTS | `personal-local-degradation` |
| Enterprise speaker identity/roster | Timestamp speaker labels (`spk0`, `spk1`) and conservative fallback labels | `personal-local-degradation` |
| Cloud collaboration permissions | Not implemented; privacy boundary is local-first personal use | `personal-local-degradation` |

## Owner-Controlled Inputs Still Required

- Paid/active Apple Developer Program access if public Developer ID distribution or App Store submission is desired.
- Developer ID Application certificate for direct distribution.
- Hardened runtime Developer ID build and notarization/stapling credentials, such as a `notarytool` keychain profile.
- Mac App Store distribution identity/provisioning and final sandboxed package if App Store is selected.
- Public privacy policy URL and final App Store Connect privacy answers.
- Final channel decision: local-only, optional BYOK cloud-provider build, direct Developer ID distribution, or Mac App Store.

## Current Conclusion

InsightKit is now in a strong local/internal QA state for the personal-user meeting asset loop, with real import, transcript, smart minutes, search, media linkage, notes, export, recovery, tests, and local packaging evidence. It is not yet App Store-ready or public-distribution-ready because Apple account/certificate/notarization/sandbox/privacy-URL gates remain unresolved and require owner-controlled inputs.
