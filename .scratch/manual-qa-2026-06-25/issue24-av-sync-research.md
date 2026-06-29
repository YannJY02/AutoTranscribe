# Issue 24 audio-video-transcript sync research

Status: active
Last reviewed: 2026-06-27

## Purpose

Issue 24 is no longer a simple "audio stream shorter than video stream" defect.
The latest owner retest still reports perceived audio/video sync problems even
when the saved `recording.mp4` passes duration-level diagnostics.

This note records the evidence-backed path for synchronizing audio, video, and
transcript timelines. It should guide the next implementation pass.

## Prior fixes reviewed

1. 2026-06-25: Visual recording start was moved until after audio capture
   startup, so video no longer started before the selected audio source.
2. 2026-06-26: Visual recording was stopped before finalization, and playback
   progress observability was improved.
3. 2026-06-27: `ReviewMediaComposer` was changed to compose the shortest
   playable duration instead of padding shorter audio to a longer video.

Those fixes addressed start ordering, stop ordering, and stream duration
equality. They did not introduce a shared media clock across audio capture,
video capture, and transcript output.

## Latest local evidence

Latest owner retest record inspected:

- Record folder: `~/Documents/InsightKit/Records/20260627-1025-live-record-e1ed1d25`
- Final saved media: `recording.mp4`
- Diagnostic output: audio duration `26.000s`, video duration `26.000s`,
  transcript last segment end `24.960s`, failures `[]`

Temporary capture sources for the same session:

- Video-only temp file: `recording.mp4`, video duration `54.933333s`
- Audio temp file: `recording.wav`, audio duration `26.000000s`
- Composed temp file: `recording-with-audio.mp4`, audio/video duration
  `26.000000s`

This proves the current diagnostic is necessary but insufficient. The output is
length-aligned, but the composer may have selected the wrong 26-second window
from a 54.9-second video source.

## Current code finding

`AVFoundationReviewMediaComposer` currently uses:

- `timelineDuration = CMTimeMinimum(videoDuration, audioDuration)`
- video range: `[0, timelineDuration]`
- audio range: `[0, timelineDuration]`

`ChunkAssembler` emits audio chunk timestamps from accumulated sample count
starting at zero. `VideoCaptureService` starts its `AVAssetWriter` session at
the first video sample buffer presentation timestamp. There is no persisted
mapping that says which audio sample time corresponds to which video PTS.

Therefore the app can produce an output with equal stream durations while still
using the wrong source window.

## Research-backed standard

Primary-source references:

- Apple `AVAssetWriter.startSession(atSourceTime:)` defines writer sessions
  around a source timestamp, not around wall-clock duration alone:
  https://developer.apple.com/documentation/avfoundation/avassetwriter/startsession%28atsourcetime%3A%29
- Apple CoreMedia exposes sample-buffer presentation timestamps through
  `CMSampleBufferGetPresentationTimeStamp`:
  https://developer.apple.com/documentation/coremedia/cmsamplebuffergetpresentationtimestamp%28_%3A%29
- Apple `AVCaptureDataOutputSynchronizer` exists specifically to deliver
  synchronized data from multiple capture outputs:
  https://developer.apple.com/documentation/avfoundation/avcapturedataoutputsynchronizer
- Apple `AVAudioNode.installTap` provides an `AVAudioTime` with each audio
  buffer, which is the right place to preserve audio timing:
  https://developer.apple.com/documentation/avfaudio/avaudionode/installtap%28onbus%3Abuffersize%3Aformat%3Ablock%3A%29
- Apple ScreenCaptureKit capture is sample-buffer based and should be treated
  as a timestamped capture source:
  https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos
- FFmpeg timestamp filters such as `setpts`, `asetpts`, `trim`, and `atrim`
  reinforce the same rule for post-processing: shift, trim, and rebase tracks
  by explicit timestamps, not by blind duration equality:
  https://ffmpeg.org/ffmpeg-filters.html

The standard approach is to pick one canonical media timeline, preserve source
timestamps into that timeline, and rebase derived artifacts such as transcript
segments and evidence spans to the final playback timeline.

## Recommended implementation path

### 1. Add capture timeline instrumentation first

Persist a small `capture_timeline.json` sidecar for each live session:

- session recording anchor in a monotonic clock
- video first/last sample PTS and source file duration
- audio first/last buffer host time or sample time and source file duration
- chosen source ranges for composition
- final output duration
- transcript rebase offset

The existing issue 24 diagnostic should fail when these fields are missing for
new live recordings, and should print the chosen audio/video crop ranges.

### 2. Replace zero-based composition with offset-aware composition

Preferred target:

- write audio and video into one canonical asset using one media timeline; or
- for capture APIs that must remain separate, compute the timeline
  intersection from recorded anchors before composing.

For separate source files:

1. Convert audio buffer timing and video sample-buffer PTS into the same master
   timeline.
2. Compute `intersectionStart = max(audioStart, videoStart)`.
3. Compute `intersectionEnd = min(audioEnd, videoEnd)`.
4. Insert video range starting at `intersectionStart - videoStart`.
5. Insert audio range starting at `intersectionStart - audioStart`.
6. Insert both at composition time zero with identical duration.
7. Store the crop/rebase values for diagnostics.

Do not use `CMTimeMinimum(videoDuration, audioDuration)` from zero as the
primary rule. It only equalizes duration.

### 3. Rebase transcript and Smart Minutes to the final media timeline

After final media composition, transcript segments, Timeline Beats, and Evidence
Spans must be expressed in final playback time:

`finalTime = sourceAudioTime - compositionIntersectionStart`

If final media transcription is run against the composed media, that already
uses final playback time. If any live transcript timing is reused for recovery,
it must be rebased with the same composition offset.

### 4. Add a sync-specific QA gate

Duration equality is only a baseline. Add at least one sync gate:

- generated fixture with a visual flash and an audio click at known timestamps;
  assert final audio peak and video frame change differ by less than the chosen
  tolerance; or
- manual clapper test protocol for owner retest, with the diagnostic reporting
  offset direction and approximate milliseconds.

Recommended tolerance for product QA: keep perceived offset under 150 ms unless
the team chooses a stricter target.

## Decision

Best path: fix the capture timeline model, not another duration crop.

Issue 24 should stay open until the app records and uses a shared audio/video
timeline anchor, composes by source-window intersection, and verifies sync with
an offset-aware test. Issue 26 remains the transcript-side contract: saved
transcript timestamps must point into the final media timeline.

## 2026-06-27 implementation note

The recommended path has been implemented for the Live Workspace review-media
composition path:

- `ReviewMediaComposer` now composes by audio/video source-window intersection.
- Live capture records video start and first audio start into
  `LiveMediaCaptureTimeline`.
- New live records persist `capture_timeline.json` for diagnostics.
- The issue 24 diagnostic now warns when a video record has equal audio/video
  durations but no capture timeline sidecar.

Remaining owner validation is perceptual: a new installed-app capture must be
played back to confirm the visible audio/video timing is acceptable.
