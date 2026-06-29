# Evaluate Apple Speech framework as an official transcription backend

Status: ready-for-human

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

InsightKit currently relies on local ASR runtime choices such as Whisper, FunASR, and Qwen3-ASR MLX.

The owner asked whether Apple's official speech APIs could implement the transcription path instead of, or alongside, the current runtime.

## What I expected

Before implementation, InsightKit should have a focused feasibility decision for Apple Speech as an official transcription backend.

The decision should cover live capture, imported media transcription, timestamps suitable for Media-Timed Transcript, language support, offline/on-device behavior, diarization or speaker-label limitations, permission UX, macOS availability, App Store readiness, and how it would coexist with existing local ASR engines.

## Steps to reproduce

1. Launch the installed InsightKit app.
2. Open Settings Workspace.
3. Inspect the local speech recognition options.
4. Observe that the available choices are local ASR runtimes rather than an Apple official speech backend.
5. Compare this against the product expectation that InsightKit may benefit from a first-party macOS transcription path.

## Blocked by

None - can start as a research spike.

## Additional context

The research spike should check Apple's current Speech framework APIs, including both older recognizer surfaces and newer analyzer/transcriber surfaces, against the app's current macOS target and privacy/local-processing goals.

If Apple Speech is viable, the next issue should be a narrow prototype behind a feature flag or ASR engine option. If it is not viable, record the reason in product terms rather than leaving the question open.

Apple's current public surfaces to check include the Speech framework documentation, `SFSpeechRecognizer`, `SpeechAnalyzer`, `SpeechTranscriber`, and the WWDC 2025 SpeechAnalyzer session.

## Comments

### 2026-06-26 - Manual QA / product spike

Reported during owner-led QA with an explicit request to consider Apple's official kit for transcription.

Initial classification: `ready-for-agent`.

Why:

- The first step is research and a small feasibility decision, not a full rewrite.
- The current app already has a pluggable local speech recognition setting, so an Apple Speech feasibility spike can be scoped as one backend-option evaluation.

### 2026-06-27 - Feasibility decision recorded

Decision doc:

- `.scratch/manual-qa-2026-06-25/apple-speech-framework-feasibility.md`

Outcome:

- Do not replace the current Whisper / FunASR / Qwen3-ASR local runtime with Apple Speech as the default ASR Engine.
- Do create a follow-up prototype issue for an experimental, availability-gated Apple Speech backend on macOS 26+ using `SpeechAnalyzer` + `SpeechTranscriber`.
- Do not use the older `SFSpeechRecognizer` as the official default path for InsightKit meetings because it does not fit the app's long-form, local-first meeting transcription requirements.

Evidence checked:

- Apple Developer Documentation for `SpeechAnalyzer`, `SpeechTranscriber`, and `SFSpeechRecognizer`.
- Local Xcode 26 SDK Speech framework interface.
- InsightKit's current SwiftPM package minimum target: macOS 14.
- Existing ASR Runtime Profile and strict local ASR language in project docs.

Recommended next issue:

- Prototype Apple Speech offline media transcription on macOS 26+ behind an experimental ASR Engine option.
- Keep live capture, diarization, and default-engine replacement out of that first prototype.

### 2026-06-27 - Decision accepted and prototype issue filed

Owner decision:

- Accept the feasibility direction: do not replace the current Whisper / FunASR / Qwen3-ASR defaults with Apple Speech.
- Continue with a narrow experimental Apple Speech prototype for offline media transcription on macOS 26+.

Ask Matt route:

- This is not a new triage item; issue 38 already produced a decision.
- The follow-up is a single, independently grabbable prototype issue, so it should move to implementation through that issue rather than expanding issue 38.

Follow-up:

- `.scratch/manual-qa-2026-06-25/issues/40-prototype-apple-speech-offline-media-transcription.md`

Current state:

- No further issue 38 research action is required unless the Apple Speech product decision changes.
