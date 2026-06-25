# Open-Source Transcription Fork Scan

Generated: 2026-06-25  
Goal: assess whether InsightKit should fork a mature open-source transcription or meeting-notes app, then add speaker diarization and InsightKit-style Smart Minutes / records functionality.

## Executive Summary

Forking is feasible, but only in a narrow sense: it is feasible to fork a project and build an InsightKit-like product on top of it, but it is not obviously cheaper than continuing the current InsightKit architecture unless the fork already matches the desired product surface.

The strongest candidates are:

1. **HushScribe** if the goal is a native macOS, local-first meeting capture app. It is Swift/MIT and already uses ScreenCaptureKit, FluidAudio, WhisperKit, post-session diarization, local summaries, and Markdown output. The main risk is project maturity: small repo, Apple Silicon + macOS 26+ requirement, and no live speaker labels.
2. **Vibe** if the goal is a cross-platform desktop transcription app with a mature local runtime surface. It is MIT, active, Tauri/Rust/TypeScript, supports system audio, mic, diarization, summaries, local Ollama analysis, and an HTTP API. The cost is that InsightKit would effectively become a Tauri app rather than the current native SwiftUI + Python sidecar product.
3. **Buzz** if the goal is a very mature MIT desktop transcription base with broad community adoption. It has offline Whisper, live mic transcription, watch folder, speaker identification on current main/development docs, plugins, and a CLI. The product fit is weaker than Vibe/HushScribe because Buzz is a transcription utility, not a meeting-asset workspace.

The best default recommendation is **not a wholesale fork yet**. Run a short proof spike against HushScribe and Vibe, while keeping InsightKit as the canonical product. InsightKit already has a diarization route and a Smart Minutes / Records model; the missing value is not just "speaker separation", but reliable live capture, review, and insight workflow quality.

## Current InsightKit Baseline

Local repository evidence:

- `README.md` describes InsightKit as a local-first macOS meeting assistant combining a native SwiftUI app, Python sidecar, local ASR, record review, Smart Minutes, Markdown/PDF export, and release verification.
- `README.md` lists the current surface as SwiftUI app, local Unix socket JSON-RPC sidecar, Whisper/FunASR/Qwen MLX ASR paths, local record folders, Smart Minutes, decisions, actions, chapters, and exports.
- `scripts/asr_runtime_profile.py` defaults diarization engine normalization to `fluid-lseend`, with alternatives for `pyannote`, `funasr`, `auto`, and `none`.
- `macos/InsightKitApp/Sources/InsightKitApp/Services/LiveTranscriptPipeline.swift` already models a live pipeline that transcribes chunks, appends transcript deltas, and refreshes live insight when provider state allows it.

Implication: replacing the app is not buying a missing diarization checkbox. It is a product-rearchitecture decision.

## Candidate Matrix

| Candidate | Fit as Fork Base | Why It Matters | Main Risks |
| --- | --- | --- | --- |
| HushScribe | High for macOS-native spike | Swift/MIT; local meeting capture; mic + system audio; FluidAudio/WhisperKit; post-session diarization; local summaries; Markdown vault output. | Small project; macOS 26+ / Apple Silicon; no live speaker labels; would need InsightKit Records, Smart Minutes schema, import/export, search, settings, and QA hardening. |
| Vibe | High for cross-platform desktop spike | MIT; active; Tauri/Rust/TS; offline; system audio + mic; speaker diarization; summaries via Claude/Ollama; many export formats; HTTP API. | Replatform from SwiftUI; product is transcription/subtitle utility, not meeting-asset workspace; many open issues. |
| Buzz | Medium-high for transcription utility fork | MIT; very mature; large community; offline Whisper; live mic; watch folder; CLI; plugin system; current README mentions speaker identification and AI summary plugins. | Python/PyQt desktop utility, not InsightKit workspace; system audio requires routing; speaker identification status may differ between stable and development builds. |
| noScribe | Medium as reference, low as main fork | GPL; local interview transcription; pyannote speaker detection; strong editor and qualitative-research use case. | Offline/import-focused; not live meeting assistant; GPL; slow on some machines; summary/records workflow missing. |
| Speakr | Medium as web/self-host path | AGPL; self-hosted PWA/web app; recording, system/browser audio, diarization, voice profiles, summaries, search, tags, API, collaboration. | Web/server product; AGPL network-source obligations; heavier than a personal macOS app; not native. |
| Whishper / Anysub v4 | Medium as backend reference | AGPL; WhisperX worker architecture; diarization and alignment; v4 roadmap includes OpenAI/Ollama summaries. | v4 explicitly work-in-progress; no testing docs yet; web UI/summarization not fully complete. |
| OpenTranscribe | Medium-low | Rich speaker management, profiles, overlap detection, search, analysis platform. | AGPL; small repo; heavy Docker/platform architecture; likely overkill for a local personal app. |
| Meetily | Medium-low | MIT; popular; local real-time meeting assistant with summaries. | Its own README says speaker diarization is planned for PRO, so community-edition diarization fit is unclear. |
| Anarlog / Hyprnote | Medium-low | MIT local-first meeting notetaker, markdown files, BYO LLM, local transcription. | Public discussion suggests diarization/identification has been a gap; useful as product reference, weaker as diarization base. |
| MeetMemo / TranscriptionStream | Low-medium | Existing web flows for diarization + summary + export. | Smaller projects, Docker/GPU/web orientation; better as implementation references than canonical fork base. |

## Source Notes

### HushScribe

Source: [drcursor/HushScribe](https://github.com/drcursor/HushScribe), [architecture](https://github.com/drcursor/HushScribe/blob/main/ARCHITECTURE.md)

- MIT licensed, Swift macOS app.
- Captures mic and system audio, writes structured Markdown, and runs local transcription/summaries.
- Architecture uses ScreenCaptureKit, FluidAudio VAD/ASR/diarization, WhisperKit, and MLX-based local LLM inference.
- Explicit limitation: diarization runs after the session, not live; Apple Silicon and macOS 26+ required.

Assessment: closest to the current product direction, but not mature enough to assume it can replace InsightKit without a proof spike.

### Vibe

Source: [thewh1teagle/vibe](https://github.com/thewh1teagle/vibe)

- MIT licensed; 6k+ stars; active releases.
- Tauri/Rust/TypeScript app for local audio/video transcription.
- Features include system audio, microphone, speaker diarization, Ollama local analysis, Claude summaries, export formats, stable timestamps, and an HTTP API.

Assessment: strong fork candidate if replatforming to Tauri is acceptable. Less attractive if preserving native SwiftUI and current macOS release workflow matters.

### Buzz

Source: [chidiwilliams/buzz](https://github.com/chidiwilliams/buzz), [speaker discussion](https://github.com/chidiwilliams/buzz/discussions/1043)

- MIT licensed; nearly 20k stars; long-lived desktop app.
- Supports offline transcription, live mic transcription, advanced viewer, watch folder, CLI, plugin system, and multiple Whisper backends.
- Current README mentions speaker identification and plugin-based AI summaries; discussion history says speaker identification landed in latest development versions.

Assessment: safest mature desktop utility base, but less product-aligned than HushScribe or Vibe.

### noScribe

Source: [kaixxx/noScribe](https://github.com/kaixxx/noScribe)

- GPL-3.0; local desktop app for high-quality interview transcripts.
- Uses Whisper/faster-whisper and pyannote for speaker identification.
- Includes an editor for transcript review and correction.

Assessment: excellent reference for import/review workflows, not ideal as the main InsightKit fork because it is interview/offline oriented and GPL.

### Speakr

Source: [murtaza-nasir/speakr](https://github.com/murtaza-nasir/speakr)

- AGPL; self-hosted transcription and note-taking platform.
- Supports flexible capture, WhisperX/OpenAI/Mistral/custom ASR, diarization, voice profiles, summaries, per-recording chat, semantic search, tags, API, collaboration, and retention policies.

Assessment: useful if InsightKit pivots to self-hosted web/PWA. Otherwise it is too broad and license-heavy for a native personal app.

### Whishper / Anysub v4

Source: [pluja/whishper v4](https://github.com/pluja/whishper/tree/v4)

- AGPL; v3 is a local transcription/subtitle web UI.
- v4 is a rewrite using WhisperX, worker orchestration, diarization, alignment, better segment splitting, and planned OpenAI/Ollama summarization.
- v4 README says work is still in progress and testing documentation is not yet available.

Assessment: promising backend reference, not a safe app fork today.

### FluidAudio and WhisperX as Runtime Choices

Sources: [FluidAudio](https://github.com/FluidInference/FluidAudio), [WhisperX](https://github.com/m-bain/whisperX), [pyannote Community-1](https://huggingface.co/pyannote/speaker-diarization-community-1)

- FluidAudio is Swift/Apache-2.0 and offers local low-latency ASR, VAD, and speaker diarization on Apple devices with ANE/CoreML.
- WhisperX is BSD-2-Clause and provides Whisper-based ASR with word timestamps and diarization, commonly paired with pyannote.
- pyannote Community-1 is gated on Hugging Face: users must accept conditions and create an access token before downloading. It is stronger than older 3.1 in pyannote's own benchmark table, but still has model-access friction.

Assessment: if InsightKit stays native, runtime-library integration is more attractive than forking a full app.

## License Notes

Source: [GNU AGPL v3](https://www.gnu.org/licenses/agpl-3.0.en.html), [GNU GPL v3](https://www.gnu.org/licenses/gpl-3.0.en.html)

- MIT / Apache-2.0 candidates are easiest to fork and commercialize: HushScribe, Vibe, Buzz, FluidAudio, WhisperX.
- GPL candidates can be redistributed and sold, but modified distributed binaries must provide corresponding source.
- AGPL candidates add the network-interaction obligation: if users interact with a modified server over a network, they must be offered the corresponding source.

Implication: AGPL web projects are not disqualified, but choosing one makes "closed product" or "private server modifications" incompatible with the license strategy.

## Recommendation

Do not replace InsightKit with a fork yet. Run a bounded fork spike:

1. **HushScribe spike**: verify it builds/runs on the target Mac, test one real meeting recording, inspect output, measure live transcript quality, and confirm whether macOS 26+ is acceptable.
2. **Vibe spike**: verify speaker diarization and summary output on the same media, inspect the HTTP API, and estimate how much of InsightKit could become a wrapper around Vibe rather than a fork.
3. **Keep InsightKit canonical during the spike**: compare outputs against InsightKit's current FluidAudio/LS-EEND and Qwen MLX path instead of assuming the fork is better.
4. **Decision gate**: fork only if the candidate can beat InsightKit on at least two of these: live capture reliability, diarization quality, runtime packaging, import/export UX, and maintenance speed.

Estimated engineering implication:

- **Reference-only adoption**: 2-5 days to port ideas/patterns into InsightKit.
- **Runtime-library adoption**: 1-3 weeks for a focused FluidAudio/WhisperX/pyannote improvement slice with tests.
- **Full fork-to-InsightKit product**: 4-10+ weeks, because Smart Minutes, Records Workspace, import/review/export, provider settings, current QA issues, and release workflow all have to be remapped.

These are planning estimates, not measured implementation durations.

## Bottom Line

Yes, the strategy is viable, especially with HushScribe or Vibe. But the most rational first move is not "fork and migrate"; it is "fork and benchmark." InsightKit's differentiator is already the meeting-asset workflow: Smart Minutes, Records, notes, export, local runtime controls, and live insight behavior. A fork is only worth becoming the main product if it materially improves the hard parts of live capture and speaker separation without forcing a total product rewrite.
