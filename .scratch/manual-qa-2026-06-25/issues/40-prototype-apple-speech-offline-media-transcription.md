# Prototype Apple Speech offline media transcription on macOS 26+

Status: ready-for-human

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`
- `.scratch/manual-qa-2026-06-25/issues/38-evaluate-apple-speech-framework-as-official-transcription-backend.md`
- `.scratch/manual-qa-2026-06-25/apple-speech-framework-feasibility.md`

## What happened

Issue 38 decided that Apple Speech should not replace the current Whisper / FunASR / Qwen3-ASR local ASR defaults, but should get a narrow experimental prototype on macOS 26+.

The prototype should prove whether Apple's newer `SpeechAnalyzer` / `SpeechTranscriber` path can transcribe local saved media into Media-Timed Transcript rows without weakening InsightKit's macOS 14+ support or existing local ASR engines.

## What I expected

InsightKit should expose Apple Speech only as an experimental, availability-gated ASR Engine option.

The first implementation slice should support offline media transcription, not live capture. It should preserve the current macOS 14 minimum deployment target by using compile-time and runtime availability guards.

## Scope

- Add a Swift-only `AppleSpeechTranscriptionService` behind macOS 26+ availability checks.
- Support imported or saved local media first.
- Map Apple Speech result time ranges onto the saved media timeline starting at `00:00`.
- Add `NSSpeechRecognitionUsageDescription` to packaged app metadata before requesting Speech authorization.
- Expose a runtime status object for Settings / diagnostics: unsupported OS, unsupported locale, asset missing, asset downloading, installed, ready, failed.
- Keep existing Whisper / FunASR / Qwen3-ASR engines unchanged.

## Out of scope

- Replacing the default ASR Engine.
- Supporting macOS 14/15 with Apple Speech.
- Live capture integration.
- Speaker diarization.
- Public release promise for Apple Speech before the prototype proves timestamp quality and asset handling.

## Acceptance criteria

- The project still builds with the current macOS 14 minimum deployment target.
- On macOS 26+ with the required SDK/runtime, the prototype can transcribe one local audio file into transcript rows with media-timeline timestamps.
- On macOS versions below 26, Settings / runtime status reports Apple Speech as unsupported instead of exposing a broken engine option.
- Missing Apple speech assets produce an actionable runtime state instead of a generic transcription failure.
- Existing local ASR engines and issue 26's final-media timestamp rule remain unchanged.

## Verification plan

- Add focused Swift tests for availability/status mapping and media-timeline timestamp normalization.
- Build the Swift package after adding the availability-guarded service.
- If the local runtime is macOS 26+ with speech assets available, run one manual prototype transcription against a local media file.

## Comments

### 2026-06-27 - Filed from issue 38 decision

Created as the Ask Matt follow-up from issue 38 after the Apple Speech feasibility decision was accepted.

Implementation should start from this issue and the feasibility document, not from a broad ASR rewrite.

### 2026-06-27 - Prototype implemented and installed

Issue 40 moved from `ready-for-agent` to `ready-for-human`.

Implementation:

- Added a Swift-only `AppleSpeechTranscriptionService` guarded by compiler and macOS 26 availability checks.
- Added runtime status states for unsupported OS, unsupported SDK, unsupported locale, supported assets, downloading assets, installed assets, ready, and failed.
- Added locale matching for Apple Speech identifiers such as `zh-Hans` -> `zh_CN` and `en-US` -> `en_US`.
- Added media-timeline normalization so Apple Speech result ranges become saved transcript rows starting from `00:00`.
- Added `NSSpeechRecognitionUsageDescription` to the packaged app metadata.
- Added a Settings diagnostics card and explicit experimental toggle: `保存音频最终媒体时使用 Apple Speech 原型`.
- Routed saved final-media transcription through an injectable final-media transcriber. The Apple Speech prototype path is only used for audio final-media files when the experimental toggle is enabled; video final media stays on the existing local ASR path. Existing Whisper / FunASR / Qwen3-ASR defaults remain unchanged.
- Added `SO_NOSIGPIPE` protection to the Sidecar lifecycle socket path after a test fixture exposed a SIGPIPE crash class during short-lived socket writes.

Verification:

- `swift test --package-path macos/InsightKitApp --filter AppleSpeechTranscriptionServiceTests`, 7 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp --filter AppConfigStoreTests`, included in the focused AppConfig/AppleSpeech run, 6 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests`, 49 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp`, 209 tests, 0 failures.
- Real local Apple Speech smoke on macOS 26.6 with `zh_CN`: `assetStatus=supported`, one transcript segment returned with `start=0.0`.
- `git diff --check`, passed.
- `bash -n scripts/package_insightkit_app.sh scripts/release_preflight.sh`, passed.
- Installed sync: `./scripts/sync_insightkit_app.sh --skip-tests`, build `20260627145522`.
- Installed Info.plist check: `NSSpeechRecognitionUsageDescription` present in `/Users/yann.jy/Applications/InsightKit.app`.
- `codesign --verify --deep --strict /Users/yann.jy/Applications/InsightKit.app`, passed.
- Sync proof: `logs/workflow/latest_sync.json`.

Owner retest:

- Open installed build `20260627145522`.
- In Settings, check the Apple Speech experimental status card.
- If the status is usable, enable `保存音频最终媒体时使用 Apple Speech 原型`.
- Save a new local audio final-media recording and confirm transcript rows are produced from Apple Speech with media-timeline timestamps starting at `00:00`.
- Confirm a video final-media recording still uses the current local ASR path instead of the Apple Speech audio-only prototype path.
- Keep this as an experimental prototype result; do not treat it as a default ASR replacement.
