# InsightKit Privacy, Data, And Sandbox Release Notes

This note records the current privacy and sandbox boundary for the personal-user macOS release path. It is a release gate input, not marketing copy.

## Current Distribution Boundary

- Current local QA and Developer ID direct-distribution builds run outside App Sandbox.
- `macos/InsightKitApp/InsightKitApp.AppStore.entitlements` now records the intended Mac App Store sandbox capabilities, but the canonical local QA app is still not a sandboxed App Store build.
- Mac App Store submission is not ready until a sandboxed package embeds those entitlements, is signed with a Mac App Store distribution identity, and the file-access/sidecar model is verified under App Sandbox.
- Direct Developer ID distribution still requires Developer ID signing, hardened runtime, notarization, stapling, and clean Gatekeeper validation.
- Privacy policy draft: `docs/release-privacy-policy-draft.md`.
- App Store privacy answer draft: `docs/release-app-store-privacy-answers.md`.

## Apple Requirements Checked

- App Sandbox is required for Mac App Store distribution: <https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox>
- Sandboxed macOS apps receive temporary user-selected file access from open/save panels and need security-scoped bookmarks for persisted access: <https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox>
- App privacy details must accurately describe data collection, third-party partners, and data use in App Store Connect: <https://developer.apple.com/app-store/app-privacy-details/>
- App Store Connect requires a privacy policy URL for iOS and macOS apps: <https://developer.apple.com/help/app-store-connect/reference/app-information/app-information>

## Data Inventory

| Data | Current location | Purpose | Leaves device by default |
| --- | --- | --- | --- |
| Imported audio/video copies | `~/Documents/InsightKit/Records/<record>/recording.*` | Media replay and record recovery | No |
| Transcript segments | `~/Documents/InsightKit/Records/<record>/transcript.json`; SQLite/FTS sidecar storage | Search, review, export, media linking | No |
| Smart minutes / insight package | `minutes.json`, `insight_package.json`, Markdown/PDF exports | Review and archival export | No |
| Time-bound notes | `notes.md` inside each record folder | User notes linked to playback time | No |
| Runtime config | `~/Library/Application Support/InsightKit/runtime_config_v1.json` | ASR/provider settings without secret values | No |
| ASR models | `~/Library/Application Support/InsightKit/models` | Local transcription runtime | No |
| Provider API keys | macOS Keychain service `com.yannjy.insightkit.keys` | Optional BYOK cloud insight providers | No |
| Logs and diagnostics | repo `logs/`, `~/Library/Logs/InsightKit`, crash reports | Debugging and verification | No automatic upload |

## Optional Network/Data Disclosure Boundary

- Local ASR/transcription is the defensible no-key default.
- Cloud insight providers are optional and user-configured through BYOK settings.
- If a user enables a cloud provider, transcript/meeting content needed for insight generation may be sent to that provider's API endpoint.
- The app must not claim "all processing is offline" unless cloud providers are disabled and the flow is local-only.
- App Store privacy answers must disclose optional transmission of audio-derived transcript text and meeting/user content when cloud analysis providers are enabled.

## Permissions

- `NSMicrophoneUsageDescription`: required for meeting recording and realtime transcription.
- `NSCameraUsageDescription`: required for video capture paths.
- `NSScreenCaptureUsageDescription`: required for screen/system audio capture paths.
- File access currently relies on user selection and a non-sandboxed writable record root.

## Sandbox Gap

Current local project files set `com.apple.security.app-sandbox=false` for local QA. The App Store entitlements draft enables:

- `com.apple.security.app-sandbox=true`.
- User-selected file read/write entitlement for media import and export.
- App-scoped security-scoped bookmarks for any persisted external media or custom record-root access.
- Network client entitlement if optional BYOK cloud analysis providers remain available in the App Store channel.

For Mac App Store readiness, the app still needs:

- A packaged app signed with embedded App Store sandbox entitlements.
- A real sandbox-runtime verification pass after a Mac App Store distribution identity is available.
- A final decision on whether the Python sidecar and bundled runtime remain inside the app/container, move to an XPC service, or are excluded from the Mac App Store channel.

Current engineering preparation:

- `RecordsIndexService` defaults to `~/Library/Application Support/InsightKit/Records` when the app is sandboxed.
- Custom records roots are saved with app-scoped security-scoped bookmarks when sandboxed.
- The Swift app passes the selected records root to the Python sidecar with `INSIGHTKIT_RECORDS_ROOT`.
- Evidence: `logs/diagnostics/2026-05-24/sandbox-records-root-proof.json`.
- Record storage moved to the app container by default, or explicit user-selected folder access with stored bookmarks.

## Manual App Store Owner Tasks

- Publish a public privacy policy URL.
- Review and publish `docs/release-privacy-policy-draft.md` or a legally reviewed replacement.
- Use `docs/release-app-store-privacy-answers.md` to enter final App Store Connect privacy answers.
- Complete App Store Connect app privacy answers for local media, transcripts, notes, optional cloud provider transmission, diagnostics, and third-party partners.
- Confirm whether the App Store channel supports optional cloud providers or ships local-only.
- Review App Review metadata and screenshots after the final sandboxed build exists.
