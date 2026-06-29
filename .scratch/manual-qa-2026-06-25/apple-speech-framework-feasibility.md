# Apple Speech Framework Feasibility For InsightKit

Status: decision-ready
Date: 2026-06-27
Related issue: `.scratch/manual-qa-2026-06-25/issues/38-evaluate-apple-speech-framework-as-official-transcription-backend.md`

## Decision

Do not replace the current Whisper / FunASR / Qwen3-ASR local runtime with Apple Speech as the default ASR Engine.

Do add a follow-up prototype issue for an experimental, availability-gated Apple Speech backend on macOS 26+ using `SpeechAnalyzer` + `SpeechTranscriber`.

Rationale:

- The current app targets macOS 14 in `macos/InsightKitApp/Package.swift`.
- The newer Apple Speech transcription surface (`SpeechAnalyzer`, `SpeechTranscriber`, `AssetInventory`) is macOS 26+ in the Xcode 26 SDK and Apple documentation.
- The older `SFSpeechRecognizer` surface is available on macOS 10.15, but Apple documents service availability, network/throttling concerns, and a one-minute task limit. That does not fit InsightKit's meeting-length transcription and strict-local ASR expectation.
- The new macOS 26+ surface has the right shape for InsightKit: async audio input, file and live analysis, downloadable speech assets, locale checks, and result time ranges.

## Source Evidence

Primary Apple sources checked:

- Apple Developer Documentation: `SpeechTranscriber` - https://developer.apple.com/documentation/speech/speechtranscriber
- Apple Developer Documentation: `SpeechAnalyzer` - https://developer.apple.com/documentation/speech/speechanalyzer
- Apple Developer Documentation: `SFSpeechRecognizer` - https://developer.apple.com/documentation/speech/sfspeechrecognizer
- Local Xcode SDK: `/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.0.sdk/System/Library/Frameworks/Speech.framework`

Local SDK observations:

- `SpeechTranscriber` and `SpeechAnalyzer` are marked available on macOS 26.0+.
- `SpeechTranscriber` exposes `progressiveLiveTranscription`, `offlineTranscription`, `timeIndexedOfflineTranscriptionWithAlternatives`, and `timeIndexedLiveCaptioning` presets.
- `SpeechTranscriber.Result` carries a `CMTimeRange`; `SpeechTranscriber.ResultAttributeOption` includes `audioTimeRange`.
- `SpeechAnalyzer` accepts async `AnalyzerInput` sequences and has audio-file convenience entry points.
- `AssetInventory` exposes supported/installed asset state and install requests for speech modules.
- `SFSpeechRecognizer` supports file and buffer recognition, but its header still documents service limits and a one-minute duration expectation for the older recognizer path.

## Fit Against InsightKit Requirements

### Live Workspace

Fit: plausible on macOS 26+.

`SpeechAnalyzer` can consume an async sequence of `AnalyzerInput` values. A prototype should adapt `MicCaptureService` / mixed audio output into `AnalyzerInput`, preserving `bufferStartTime` so emitted transcript segments stay on the Media Timeline.

Risk:

- Need to prove live latency and finalization behavior with real microphone and system-audio captures.
- Need to verify whether Speech authorization is required separately from microphone permission in this path.
- The first prototype should avoid changing the existing Sidecar pipeline and should publish Apple Speech results through the same Transcript Segment contract.

### Imported Media

Fit: strong on macOS 26+.

`SpeechAnalyzer` has file-oriented entry points and `SpeechTranscriber` has time-indexed offline presets. This maps better to InsightKit's Final Media Transcription than the older `SFSpeechURLRecognitionRequest` path.

Prototype priority:

1. Start with imported audio/video media after extracting or reading the audio track.
2. Convert Apple time ranges into `TranscriptEntry` / Media-Timed Transcript rows.
3. Compare timestamps against the final media clock.

### Timestamps

Fit: strong enough for a prototype.

The new API reports result ranges as `CMTimeRange` and supports audio time-range attributes. This is a better fit for issue 26's final-media timeline rule than relying only on live chunk time.

Acceptance requirement:

- No saved transcript row should use wall-clock or live-processing time.
- Apple Speech rows must be normalized to the saved media timeline starting at 00:00.

### Language Support

Fit: conditional.

The new API exposes `supportedLocales` and `installedLocales`, and assets may need installation through `AssetInventory`. InsightKit should not show Apple Speech as available until the requested locale is supported and installed or installable.

Open validation:

- Verify Simplified Chinese, English, and mixed meeting behavior on the actual target Macs.
- Decide whether locale is user-selected, auto-detected elsewhere, or derived from app settings.

### Offline / On-Device Behavior

Fit: plausible only with the new macOS 26+ surface.

`AssetInventory` and installed locale state make the new API align with the product's local-first posture. The old `SFSpeechRecognizer` path should not be treated as strict local because it can depend on service availability and documented limits.

Acceptance requirement:

- Apple Speech backend must expose runtime status: unsupported, asset missing, asset downloading, installed, ready, failed.
- It must never silently fall back to network speech recognition when the user selected a strict-local mode.

### Diarization

Fit: insufficient by itself.

The checked public surfaces provide transcription, alternatives, confidence, and time ranges, but no meeting-speaker diarization contract equivalent to InsightKit's speaker labels.

Product implication:

- Apple Speech can be a transcription backend.
- It should not be described as solving speaker diarization.
- Speaker rename/manual correction should remain available, and automatic diarization should stay with existing local diarization components unless a separate Apple-supported speaker API is found.

### Permission UX

Fit: manageable.

Live capture still requires microphone permission. Speech recognition use also needs a clear usage description and authorization path. The packaged app currently has `NSMicrophoneUsageDescription`; an Apple Speech prototype should add and verify `NSSpeechRecognitionUsageDescription` before requesting Speech authorization.

### App Store / Distribution

Fit: better than Python ASR dependencies, but only for macOS 26+ users.

Apple Speech is a first-party public framework and should be easier to explain in App Store privacy review than bundled third-party ASR runtimes. The limitation is platform reach: InsightKit currently supports macOS 14+, so Apple Speech cannot be the default ASR Engine without dropping older macOS support.

## Recommended Next Issue

Create a narrow prototype issue:

Title: `Prototype Apple Speech offline media transcription on macOS 26+`

Scope:

- Add a Swift-only `AppleSpeechTranscriptionService` behind compile-time and runtime availability checks.
- Support imported media / saved media first, not live capture.
- Add `NSSpeechRecognitionUsageDescription` to packaged Info.plist.
- Expose a runtime status object similar to current ASR Runtime Snapshot: unsupported OS, unsupported locale, asset missing/downloading/installed, ready, failed.
- Map `SpeechTranscriber.Result` time ranges into Media-Timed Transcript rows.
- Keep the feature behind an experimental ASR Engine option and do not remove existing local ASR engines.

Out of scope:

- Replacing Whisper/FunASR/Qwen3-ASR as defaults.
- Speaker diarization.
- Public release promise for macOS 14/15 users.
- Full live capture integration before offline-media timestamps are proven.

## Acceptance Criteria For Prototype

- Builds on the current package while preserving macOS 14 minimum deployment through availability guards.
- On macOS 26+, can transcribe one local audio file into transcript rows with timestamps on the media timeline.
- On macOS <26, Settings Workspace reports Apple Speech as unsupported instead of exposing a broken option.
- If required Apple speech assets are missing, the app reports an actionable installation state.
- Existing local ASR engines remain unchanged.
