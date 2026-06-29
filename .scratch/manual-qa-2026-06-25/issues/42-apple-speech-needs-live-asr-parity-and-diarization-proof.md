# Apple Speech needs live ASR parity and diarization proof before becoming a peer local engine

Status: ready-for-human

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`
- `.scratch/manual-qa-2026-06-25/issues/38-evaluate-apple-speech-framework-as-official-transcription-backend.md`
- `.scratch/manual-qa-2026-06-25/issues/40-prototype-apple-speech-offline-media-transcription.md`
- `.scratch/manual-qa-2026-06-25/apple-speech-framework-feasibility.md`
- `.scratch/manual-qa-2026-06-25/apple-speech-live-parity-and-diarization.md`

## What happened

The owner expected Apple's first-party speech kit to be offered as a peer local realtime ASR Engine alongside the existing local ASR engines.

The installed prototype is narrower: it is an experimental audio final-media path, not a Live Workspace ASR Engine, and it does not prove Diarization.

## What I expected

Apple Speech should only be presented as a same-level local ASR Engine if it reaches functional parity with the existing local ASR Runtime Profile:

- realtime Live Workspace transcription;
- strict local behavior with clear asset/runtime status;
- Media-Timed Transcript output;
- no regression in speaker labels or Diarization expectations;
- Record save and Smart Minutes behavior consistent with other ASR engines.

If Apple's first-party API cannot provide Diarization by itself, InsightKit should either combine it with an existing local Diarization component or clearly mark the gap before exposing it as a peer engine.

## Steps to reproduce

1. Launch installed InsightKit build `20260627145522` on macOS 26+.
2. Open Settings and inspect the Apple Speech prototype controls.
3. Open Live Workspace and inspect the available ASR Engine behavior.
4. Start from the product expectation that Apple Speech should be a same-level realtime local ASR option with speaker separation.
5. Observe that the current prototype is scoped to audio final-media transcription and does not provide proven Live Workspace or Diarization parity.

## Blocked by

None - can start immediately as a parity spike.

## Additional context

The current Xcode 26 Speech SDK surface exposes `SpeechAnalyzer` async input and `SpeechTranscriber` presets for progressive live transcription, offline transcription, time-indexed live captioning, and time-indexed offline transcription with alternatives.

The same public SDK surface exposes transcript text, alternatives, confidence, and audio time ranges, but no observed meeting-speaker Diarization contract. A parity spike should therefore prove whether Apple Speech can be combined with InsightKit's existing local Diarization path, rather than assuming Apple's transcription API solves speaker separation by itself.

## Comments

### 2026-06-27 - Peer-engine parity gate installed

Issue 42 moved from `ready-for-agent` to `ready-for-human`.

Decision/proof doc:

- `.scratch/manual-qa-2026-06-25/apple-speech-live-parity-and-diarization.md`

Outcome:

- Apple Speech is not exposed as a peer local ASR Engine.
- Apple Speech remains only an experimental macOS 26+ audio final-media transcription prototype.
- Realtime Apple Speech transcription remains a plausible future implementation path, but same-level engine parity is not proven until Live Workspace integration and Diarization are both proven.
- The observed public Apple Speech transcription surface still does not provide a meeting-speaker Diarization contract, so speaker separation must either come from a separate Apple-supported speaker API or from combining Apple Speech transcription with InsightKit's existing local Diarization component.

Implementation:

- Added `AppleSpeechPeerEngineParityStatus` as a testable parity gate.
- Added `AppleSpeechRuntimeStatus.shouldExposePeerLocalASREngineOption`.
- Kept `LocalASREngine` limited to Whisper, FunASR, and Qwen3-ASR MLX.
- Updated Settings so the Apple Speech card explicitly says it is not a peer ASR Engine yet and lists blockers for strict-local readiness, Live Workspace realtime transcription, Diarization, and Record/Smart Minutes parity.
- Kept the experimental final-media toggle separate from the peer-engine gate.

Verification:

- Red check: `swift test --package-path macos/InsightKitApp --filter AppleSpeechTranscriptionServiceTests` initially failed because `AppleSpeechPeerEngineParityStatus` and `shouldExposePeerLocalASREngineOption` did not exist.
- `swift test --package-path macos/InsightKitApp --filter AppleSpeechTranscriptionServiceTests`, 9 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp --filter AppConfigStoreTests`, 7 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp`, 216 tests, 0 failures.
- `git diff --check`, passed.
- `bash -n scripts/package_insightkit_app.sh`, passed.
- `bash -n scripts/release_preflight.sh`, passed.
- Installed sync: `./scripts/sync_insightkit_app.sh --skip-tests`, build `20260627161028`.
- `plutil -p logs/workflow/latest_sync.json` reports `status = success`, `build_version = 20260627161028`, and install path `/Users/yann.jy/Applications/InsightKit.app`.
- `/Users/yann.jy/Applications/InsightKit.app/Contents/Info.plist` has `CFBundleVersion = 20260627161028`.
- `codesign --verify --deep --strict --verbose=2 /Users/yann.jy/Applications/InsightKit.app`, passed.

Owner retest:

- Open installed build `20260627161028`.
- Go to Settings and inspect the Apple Speech card.
- Expected: Apple Speech is labeled as an experimental audio final-media prototype, not a peer ASR Engine.
- Expected: the card lists Live Workspace, Diarization, and Record/Smart Minutes parity blockers.
- Expected: the normal ASR Engine picker still only offers Whisper, FunASR, and Qwen3-ASR MLX.
