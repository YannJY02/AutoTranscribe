# InsightKit App Store Privacy Answer Draft

Status: draft. Use this as an owner checklist before entering answers in App Store Connect.

Apple requires app privacy details in App Store Connect for new apps and app updates. App Store Connect also requires a privacy policy URL for macOS apps.

Apple references:

- App privacy details: <https://developer.apple.com/app-store/app-privacy-details/>
- App privacy reference: <https://developer.apple.com/help/app-store-connect/reference/app-information/app-privacy>
- App information / privacy policy URL: <https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/>

## Release Channel Decision

Choose one release channel before submitting privacy answers:

- `local-only`: local ASR, local record storage, no cloud insight provider in the submitted build.
- `optional-cloud-provider`: local record storage plus user-configured BYOK cloud insight provider.

The current repo supports optional cloud analysis paths, so a public App Store build must either disable that path or disclose it accurately.

## Data Types To Review

| App Store data type | Current InsightKit behavior | Draft answer |
| --- | --- | --- |
| Audio Data | Imported or recorded meeting audio/video is stored locally for replay and transcription. | Not collected by developer in `local-only`; disclose if uploaded to a provider or developer service. |
| Other User Content | Transcripts, meeting summaries, notes, action items, decisions, and exported documents are created from user meetings. | Not collected by developer in `local-only`; disclose optional third-party processing in `optional-cloud-provider`. |
| Search History | Record search queries are local UI state for finding records. | Not collected unless later synced or logged remotely. |
| Product Interaction | The current local build has no automatic telemetry upload. | Not collected unless analytics are added later. |
| Crash Data / Diagnostics | Local logs and macOS crash reports may exist on the user's Mac; no automatic upload is implemented. | Not collected unless automatic crash reporting is added later. |
| Identifiers | No InsightKit account ID is implemented in the current personal local build. Provider keys are stored in Keychain and are not InsightKit user identifiers. | Not collected unless account/sync features are added later. |

## Optional Cloud Provider Disclosure

If the submitted build includes cloud insight providers:

- Disclose that transcript text and meeting/user content may be sent to the user-selected provider for summarization.
- State that the provider is configured by the user with their own API key.
- Review whether the provider is a third-party partner for App Store privacy purposes.
- Do not claim all processing happens on device.

## Owner Inputs Still Required

- Public privacy policy URL.
- Support URL.
- App Store app record, SKU, name, subtitle, category, and age rating.
- Final decision: local-only App Store build or optional cloud-provider App Store build.
- Confirmation that no analytics, crash uploader, or third-party SDK telemetry is present in the submitted build.
- Final privacy answers entered in App Store Connect.
