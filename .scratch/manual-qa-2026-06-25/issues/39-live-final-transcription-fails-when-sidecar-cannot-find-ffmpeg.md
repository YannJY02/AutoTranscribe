# Live final transcription fails when the sidecar cannot find ffmpeg

Status: ready-for-human

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

After a live recording completed, InsightKit showed that final review transcription was not finished and also displayed a local service version/status warning.

The failed session was `live-A82D25D9-77EC-4813-9984-4DD063A528DD`.

## What I expected

After recording stops, InsightKit should either:

- generate the final media transcript and save the Record normally, or
- show a precise, actionable warning when the captured audio is effectively silent or the local media decoder is unavailable.

It should not collapse media decoder failures, sidecar build mismatch, and silent input into the same generic local-service warning.

## Steps to reproduce

1. Launch the installed InsightKit app from `/Users/yann.jy/Applications/InsightKit.app`.
2. Start a live recording with microphone or mixed input.
3. Stop the recording after enough time for final media review to be generated.
4. Observe whether the final transcript and Record are saved.
5. If the warning appears, inspect the saved or temporary media audio level and the sidecar final media transcription result.

## Blocked by

None - fix has been implemented and installed for human retest.

## Additional context

Diagnostics from the reported session:

- The installed sidecar was healthy for ASR runtime status, but direct `asr.transcribe_media` on the temporary MP4 initially failed with `[Errno 2] No such file or directory: 'ffmpeg'`.
- The sidecar environment launched by the macOS app did not guarantee Homebrew executable paths such as `/opt/homebrew/bin`, so GUI-launched sidecars could miss `ffmpeg`.
- The same session's temporary media existed, but its audio was effectively silent: `mean_volume/max_volume = -91.0 dB`, so even after `ffmpeg` became available, ASR returned an empty transcript.
- During the original screenshot window, two InsightKit app builds were present in logs/process history, which exposed that build-mismatch recovery was skipped when an existing sidecar socket passed `ensureReady`.

## Comments

### 2026-06-27 - Fix implemented and installed

Code changes:

- `PythonRuntimeEnvironment.prepared` now always adds common executable search paths, including `/opt/homebrew/bin`, while preserving existing `PATH` entries first.
- `SidecarManager.startIfNeeded` now checks sidecar/app build mismatch even when an existing socket successfully responds to `ensureReady`.
- `ChunkAssembler` now tracks emitted chunk RMS and exposes an audible-content check.
- live review-source preparation now treats near-digital-silent chunks as no captured audio instead of saving them as a usable final transcription source.

Verification:

- Direct RPC before the fix: `asr.transcribe_media` failed with missing `ffmpeg`.
- Direct RPC after the PATH fix: `asr.transcribe_media` no longer failed with missing `ffmpeg`; it returned empty segments because the reported media was silent.
- `swift test --package-path macos/InsightKitApp`: 193 tests, 0 failures.
- Installed build: `/Users/yann.jy/Applications/InsightKit.app`, `CFBundleVersion=20260627095346`, `InsightKitGitRevision=db4fc1b`.

Human retest:

- Record a short live session while speaking clearly into the selected microphone.
- Confirm the bottom developer status shows a non-zero mic level during recording.
- Confirm final media transcription no longer fails with the local-service/ffmpeg path issue.

### 2026-06-27 - Owner retest passed

The owner confirmed issue 39 is resolved after the final-transcription environment and silent-audio detection fix. No further agent action is required unless a fresh audible recording still fails final media transcription because the sidecar cannot find the media decoder.
