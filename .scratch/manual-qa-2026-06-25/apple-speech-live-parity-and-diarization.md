# Apple Speech Live ASR Parity And Diarization Gate

Status: decision-ready
Date: 2026-06-27
Related issue: `.scratch/manual-qa-2026-06-25/issues/42-apple-speech-needs-live-asr-parity-and-diarization-proof.md`

## Decision

Do not expose Apple Speech as a peer local ASR Engine yet.

Current allowed exposure:

- Apple Speech may remain an experimental macOS 26+ audio final-media transcription prototype.
- Apple Speech must not appear in the same `LocalASREngine` picker as Whisper, FunASR, or Qwen3-ASR MLX until live transcription, strict-local runtime readiness, Media-Timed Transcript output, Diarization, and Record/Smart Minutes parity are all proven.
- The Settings Workspace must explicitly show the parity blockers instead of implying an invisible capability downgrade.

## Answer To The Product Question

Realtime Apple Speech transcription is plausible because the newer Speech framework exposes live analyzer/transcriber shapes.

Same-level InsightKit engine parity is not proven yet. The checked public Apple Speech transcription surface provides transcript text, alternatives, confidence, and audio time ranges, but no observed meeting-speaker Diarization contract. That means Apple Speech alone should not be described as solving speaker separation.

To reach peer-engine parity later, InsightKit would need one of these:

- an Apple-supported speaker separation API with proof against meeting audio; or
- an Apple Speech live transcription adapter combined with the existing local Diarization component, preserving speaker-label and speaker-rename behavior.

## Implemented Gate

- Added `AppleSpeechPeerEngineParityStatus` as a testable gate.
- Added `AppleSpeechRuntimeStatus.shouldExposePeerLocalASREngineOption`.
- Kept the current `LocalASREngine` list limited to Whisper, FunASR, and Qwen3-ASR MLX.
- Updated Settings so the Apple Speech card says it is not a peer ASR Engine and lists blockers:
  - `strict-local runtime` when assets/runtime are not installed and ready;
  - Live Workspace realtime transcription;
  - Diarization;
  - Record save and Smart Minutes parity.
- Kept the existing experimental final-media toggle separate from the peer-engine gate.

## Verification

- Red check: `swift test --package-path macos/InsightKitApp --filter AppleSpeechTranscriptionServiceTests` initially failed because `AppleSpeechPeerEngineParityStatus` and `shouldExposePeerLocalASREngineOption` did not exist.
- `swift test --package-path macos/InsightKitApp --filter AppleSpeechTranscriptionServiceTests`, 9 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp --filter AppConfigStoreTests`, 7 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp`, 216 tests, 0 failures.
- `git diff --check`, passed.
- `bash -n scripts/package_insightkit_app.sh`, passed.
- `bash -n scripts/release_preflight.sh`, passed.
- Installed sync: `./scripts/sync_insightkit_app.sh --skip-tests`, build `20260627161028`.
- Installed app proof: `logs/workflow/latest_sync.json`, `/Users/yann.jy/Applications/InsightKit.app/Contents/Info.plist`, and `codesign --verify --deep --strict --verbose=2 /Users/yann.jy/Applications/InsightKit.app`.

## Owner Retest

Open installed build `20260627161028`, go to Settings, and inspect the Apple Speech card.

Expected:

- Apple Speech is still scoped as an experimental audio final-media prototype.
- It is not shown as a peer local ASR Engine alongside Whisper, FunASR, and Qwen3-ASR MLX.
- The Settings card explicitly says Apple Speech is not a peer ASR Engine yet and lists Live Workspace, Diarization, and Record/Smart Minutes parity blockers.
- Existing local ASR Engine choices and Diarization expectations remain unchanged.
