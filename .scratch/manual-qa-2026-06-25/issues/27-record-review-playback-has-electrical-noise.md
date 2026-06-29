# Record Review playback has electrical noise

Status: ready-for-human

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

During Record Review playback, the owner hears electrical noise or buzzing in the media audio.

The record can be played back, but the playback audio quality is not clean enough for normal review.

## What I expected

Record Review playback should sound like the captured meeting source without added electrical noise, buzzing, clipping, or distortion.

If the source media itself is noisy, InsightKit should avoid adding extra noise during capture, media composition, saving, or playback.

## Steps to reproduce

1. Launch the installed InsightKit app.
2. Open a saved Record or create a new Live Workspace session and save it as a Record.
3. Play the saved media in Record Review.
4. Listen for electrical noise, buzzing, clipping, or distortion during playback.

## Blocked by

None - can start immediately.

## Additional context

Reported during owner-led QA after issue 26 owner retest passed.

This is separate from issue 25, which covers playback auto-pausing. This issue covers audio quality during playback.

## Comments

### 2026-06-26 - Manual QA

The owner reported electrical noise during playback.

Initial classification: `ready-for-agent`.

Why:

- The user-visible failure is concrete and tied to Record Review playback.
- A diagnosing loop can inspect whether the noise is introduced by capture, media composition, saved media, or playback.

### 2026-06-26 - Diagnosing Bugs

Diagnosis:

- The tight feedback loop reproduced a likely electrical-noise cause in code: loud mixed input could hit full-scale `1.0`, and WAV writing could store over-range samples as `Int16.max`.
- This is hard clipping: the waveform is cut into a flat top when it exceeds the saved-audio range. In listening terms, that can become buzzing, harshness, or electrical-sounding distortion.
- A quick scan of existing local `recording.wav` files found at least one older Record with full-scale samples: `/Users/yann.jy/Documents/InsightKit/Records/live-12649D1E-0E2D-4D51-99DD-4AFC913011FF/recording.wav`. That supports the clipping path, but also means old already-clipped media may not be repairable by this code change.

Fix:

- Added `AudioSampleLimiter` so audio samples are bounded before saved playback media reaches full-scale clipping.
- Added mixed-input headroom in `AudioMixBus`, so loud microphone plus loud system audio no longer sums into a clipped output.
- Applied the limiter in `ChunkAssembler` before writing 16-bit WAV samples, so unexpected over-range values do not become full-scale flat-top samples.

Verification:

- RED loop failed before implementation:
  - `swift test --package-path macos/InsightKitApp --filter AudioMixBusTests/testMixedModeUsesHeadroomInsteadOfClipping --filter ChunkAssemblerTests/testWAVWriterAvoidsFullScaleClippingForOverRangeSamples`
  - Failure showed mixed output at `1.0` and saved WAV samples at `Int16.max`.
- Same focused loop passed after implementation: 2 tests, 0 failures.
- Related gate passed: `swift test --package-path macos/InsightKitApp --filter AudioMixBusTests --filter ChunkAssemblerTests --filter LiveSessionViewModelTests/testPrepareTemporaryRecording`, 11 tests, 0 failures.
- Full Swift gate passed: `swift test --package-path macos/InsightKitApp`, 178 tests, 0 failures.
- `bash scripts/sync_insightkit_app.sh` passed Swift and Python gates and installed build `20260626203055`.
- `codesign --verify --deep --strict --verbose=2 /Users/yann.jy/Applications/InsightKit.app` passed.

Human retest:

1. Launch `/Users/yann.jy/Applications/InsightKit.app`, build `20260626203055`.
2. Create a new Live Workspace recording, preferably with mixed audio or a loud-but-not-dangerous test sound.
3. Save it as a Record, then open Record Review and play the saved media.
4. Confirm playback has no added buzzing, harsh electrical sound, clipping, or distortion.
5. If an old Record still sounds bad, create a fresh Record before failing this issue, because old media may already contain clipped samples written by the previous build.

Current classification: `ready-for-human`.

### 2026-06-27 - Owner retest passed

The owner confirmed issue 27 is resolved after the canonical media-source fix. No further agent action is required unless a fresh Record Review playback adds electrical noise that is not present in the captured source media.

### 2026-06-26 - Owner retest basically passed

The owner confirmed the canonical media-source fix basically passes. A small amount of residual noise remains, but the owner judged it likely comes from the microphone/source rather than added playback distortion.

This issue should no longer block the current implementation queue unless fresh playback adds obvious electrical noise beyond the captured source.

### 2026-06-26 - Owner retest failed

The owner retested the installed build and still heard electrical noise during playback.

The previous audio headroom / clipping-prevention fix is therefore not sufficient proof that the user-visible problem is solved.

Updated expected direction:

- InsightKit should not create a separate degraded playback resource when a clean captured media file already exists.
- Record Review and Smart Minutes review should use the originally recorded media as the canonical review source whenever possible.
- If the app must compose or transform media, the resulting review media must preserve the captured audio quality and not add electrical noise.
- The acceptance test should compare the original captured media, Record Review playback, and Smart Minutes review playback for the same fresh session.

Current classification: `ready-for-agent`.

### 2026-06-26 - Canonical media fix installed

Diagnosis:

- The failed owner retest showed the previous audio limiter fix was not sufficient.
- The next RED loop targeted the canonical Meeting Asset rule from issue 33: if the original captured video already has an audio track, InsightKit should not silently generate a second `recording-with-audio.mp4` and use that transformed file as the review source.
- The test first failed because `prepareTemporaryRecordingForSave` did not inspect whether the original video already had audio; it always tried to compose a derived review video whenever separate audio chunks existed.
- A quick local media scan found that some saved `recording.mp4` files already contain both `video:h264` and `audio:aac`, while others are video-only. The save path therefore must branch based on the real media tracks.

Fix:

- Added `MediaAssetInspecting` with an AVFoundation-backed inspector.
- `LiveSessionViewModel.prepareTemporaryRecordingForSave` now keeps the original video as the canonical review media when that video already contains an audio track.
- Composition remains available only for video-only recordings that also have a separate audible source.
- Record Review and Smart Minutes continue to receive the same `mediaURL` / `reviewSourceMediaURL` for the saved session.

Verification:

- RED loop failed before implementation:
  - `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testPrepareTemporaryRecordingKeepsOriginalVideoWhenItAlreadyHasAudio`
  - Failure showed that the composer was called and the result became `recording-with-audio.mp4` instead of the original `recording.mp4`.
- Focused media-save gate passed after implementation:
  - `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testPrepareTemporaryRecordingKeepsOriginalVideoWhenItAlreadyHasAudio --filter LiveSessionViewModelTests/testPrepareTemporaryRecordingComposesSinglePlayableVideoWhenVideoAndAudioAreCaptured --filter LiveSessionViewModelTests/testPrepareTemporaryRecordingPrefersExistingVideoRecordingForReview --filter LiveSessionViewModelTests/testPrepareTemporaryRecordingShowsAudioUnavailableStatusWhenVideoHasNoCapturedAudio`
  - 4 tests, 0 failures.
- Related ViewModel gate passed:
  - `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests`
  - 43 tests, 0 failures.
- Full Swift gate passed:
  - `swift test --package-path macos/InsightKitApp`
  - 179 tests, 0 failures.
- Standard sync passed Swift and Python gates and installed build `20260626210922`.
- `codesign --verify --deep --strict --verbose=2 /Users/yann.jy/Applications/InsightKit.app` passed.
- No temporary debug instrumentation remains.

Human retest:

1. Launch `/Users/yann.jy/Applications/InsightKit.app`, build `20260626210922`.
2. Use the same kind of recording that previously produced electrical noise.
3. If the saved media already contains clean audio, confirm Record Review and Smart Minutes review play that same clean media without added electrical noise.
4. If the new recording still produces electrical noise, check whether the saved `recording.mp4` is video-only. If it is video-only, the remaining problem is likely the fallback composition/audio-source path rather than unnecessary replacement of a clean original recording.

Current classification: `ready-for-human`.
