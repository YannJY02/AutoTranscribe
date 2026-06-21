# InsightKit Privacy Policy Draft

Status: draft for release review. This is not legal advice and must be reviewed before publication.

## Product Boundary

InsightKit is a local-first macOS meeting asset app for personal use. It imports or records meeting audio/video, creates timestamped transcripts, generates meeting minutes, stores notes, and exports Markdown/PDF files.

## Data Stored Locally

InsightKit stores meeting assets on the user's Mac unless the user chooses a different export location:

- Imported or recorded audio/video copies.
- Timestamped transcript segments and speaker labels.
- AI-generated meeting summaries, decisions, action items, highlights, and chapters.
- Time-bound notes created by the user.
- Markdown and PDF exports.
- Runtime settings, such as selected ASR and insight provider configuration.

The default record location used by the current local build is:

```text
~/Documents/InsightKit/Records/
```

Runtime configuration is stored under:

```text
~/Library/Application Support/InsightKit/
```

Provider API keys are stored in the macOS Keychain service:

```text
com.yannjy.insightkit.keys
```

## Network Processing

InsightKit does not upload meeting data by default in the local-first workflow.

If the user enables an optional cloud insight provider, transcript text and related meeting content needed to generate summaries may be sent to the configured provider's API endpoint. The current BYOK model uses the user's own provider key. The selected provider's terms and privacy policy apply to that processing.

The app must not be described as fully offline when a cloud provider is enabled.

## Diagnostics

InsightKit does not automatically upload diagnostics in the current local build. Logs, diagnostics, and crash reports may exist on the user's Mac for troubleshooting. Users may choose to share those files manually when asking for support.

## Permissions

InsightKit may request these macOS permissions depending on the workflow used:

- Microphone: for live recording and realtime transcription.
- Camera: for video capture workflows.
- Screen recording: for screen or system-audio capture workflows.
- File access: for importing media files, writing record assets, and exporting Markdown/PDF files.

## User Control And Deletion

Users can manage meeting records by deleting the corresponding record folder under the InsightKit records directory. Deleting a record folder removes the local media copy, transcript, notes, generated minutes, and exports for that record.

To remove provider credentials, delete the saved InsightKit keychain entries for `com.yannjy.insightkit.keys` or use the app's settings flow when available.

## App Store Privacy Notes

For an App Store release, the published privacy policy URL must match the final distribution channel:

- Local-only build: disclose local storage and user-managed files; do not claim developer-side collection if no data leaves the device.
- Build with optional cloud providers: disclose optional transmission of meeting text/user content to the configured provider.
- Build with telemetry or automatic crash reporting: disclose diagnostic collection if such functionality is added later.

Apple references:

- App privacy details: <https://developer.apple.com/app-store/app-privacy-details/>
- App privacy reference: <https://developer.apple.com/help/app-store-connect/reference/app-information/app-privacy>
- Privacy policy URL requirement: <https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/>
