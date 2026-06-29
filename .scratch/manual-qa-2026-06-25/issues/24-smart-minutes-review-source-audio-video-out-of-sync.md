# Smart Minutes review source audio and video are out of sync

Status: ready-for-human

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

After a Live Workspace session ends and the Smart Minutes review experience opens, the review source media appears to have audio and video that are not synchronized.

The owner can see and hear review material, but the sound and visual playback do not appear to line up in the completed preview/review state.

## What I expected

When Smart Minutes show review source material, audio and video should remain synchronized in the single standard media player.

The user should be able to verify Transcript Segments, Timeline Beats, and Evidence Spans against the original source without the sound drifting ahead of or behind the video.

## Steps to reproduce

1. Launch the installed InsightKit app.
2. Open the Live Workspace.
3. Capture a session with camera or screen enabled and microphone or mixed audio enabled.
4. Stop the session and generate Smart Minutes.
5. In the completed Smart Minutes review experience, play `回看资料`.
6. Observe that the audio and video appear out of sync.

## Additional context

Reported during owner-led QA against installed build `20260625212142`, git revision `db4fc1b`.

This is separate from issues 20, 21, 22, and 23. Those issues cover audible playback, visible video, click-to-seek-and-play, and using one standard media player. This issue assumes the media can play, but the audio/video timing may not match.

Further triage should determine whether the audio leads the video, the video leads the audio, or synchronization drifts over time.

## Comments

### 2026-06-25 - Manual QA

The owner reported that in the post-session Smart Minutes preview/review interface, the review source audio and video seem out of sync.

Initial classification: `needs-triage`.

Why:

- The issue is user-visible and belongs to the Smart Minutes review-source bundle.
- It is independently verifiable from the earlier no-audio, no-video, click-to-seek, and split-player issues.
- The exact direction and stability of the sync offset still need diagnosis before implementation.

### 2026-06-25 - Code fix installed for owner retest

Status changed to `ready-for-human`.

Diagnosis:

- Live Workspace started the saved visual recording immediately after the user clicked start.
- Microphone or system audio capture started later, after local runtime preparation, sidecar readiness, and session setup.
- The Smart Minutes review-source composition then merged the saved video and captured audio from their own zero points, which could make the completed review media feel out of sync.

Fix:

- Moved the saved visual recording start until after the selected audio capture source has successfully started.
- The visual recording now starts just before the recording duration timer and warmup lifecycle, so the saved review media begins from the same user-visible capture boundary as the audio/transcript timeline.
- Existing one-player Smart Minutes review-source composition remains in place.

Proof:

- RED: `python -m pytest tests/test_live_review_media_sync.py -q` failed before the fix because `startVisualRecordingIfNeeded` appeared before audio capture startup in `startLiveSession`.
- GREEN: `python -m pytest tests/test_live_review_media_sync.py -q`, 1 test, 0 failures.
- Related gate: `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testPrepareTemporaryRecording --filter LiveReviewSourcePresentationTests --filter MediaSeekRequestTests`, 17 tests, 0 failures.
- Broad Swift gate: `swift test --package-path macos/InsightKitApp`, 158 tests, 0 failures.
- Installed app sync: build `20260625214038` installed to `/Users/yann.jy/Applications/InsightKit.app`.

Owner retest:

- Capture a Live Workspace session with camera or screen plus microphone or mixed audio.
- Stop the session and generate Smart Minutes.
- In Smart Minutes `回看资料`, play the single media player.
- Confirm video remains visible, sound is audible, click-to-seek still starts playback, and audio/video timing is acceptably aligned.

### 2026-06-25 - Owner retest failed after installed fix

Status changed to `ready-for-agent`.

The owner reported that the audio/video synchronization problem is still present after testing the installed build `20260625214038`.

This means the previous timing-boundary fix was insufficient. Future diagnosis should keep the current fix in place as an attempted mitigation, but should not treat it as proof that the Smart Minutes review-source timing problem is solved.

Next diagnosis should capture whether audio leads video, video leads audio, or sync drifts during playback, and should inspect the composed review media itself rather than only the live-session start ordering.

### 2026-06-26 - Installed fix and system-audio E2E proof

Status changed to `ready-for-human`.

Diagnosis:

- The previous fix aligned recording start time, but the saved visual recording could still keep running during stop/finalization after audio capture had already stopped.
- That could produce a completed `recording.mp4` whose video stream was longer than its audio stream.
- `ReviewMediaComposer` inserted the shorter audio track at time zero without padding the remaining video timeline, so AV playback could expose a real audio/video duration gap.
- A separate observability gap made Live review playback hard to verify: `回看资料` playback time was not written back to `currentPlaybackTime`, so the app could appear stuck at the clicked timestamp even while the AVPlayer was moving.

Fix:

- Stop and finish visual recording immediately during `stopLiveSession`, before background transcript/finalization work can extend video capture.
- Pad short composed audio with empty audio time range up to the video duration, so the single standard media player has one coherent audio/video timeline.
- Wire Live review `MediaPlayerView` time updates back into the Live view model, so click-to-seek playback progress is visible in the Live review state.

Proof:

- RED/GREEN media timing regression: `python -m pytest tests/test_live_review_media_sync.py -q`, 3 tests, 0 failures.
- Playback state regression: `swift test --package-path macos/InsightKitApp --filter MediaSeekRequestTests`, 10 tests, 0 failures.
- Standard install sync: `bash scripts/sync_insightkit_app.sh`; Swift and Python gates passed and installed build `20260626144645` to `/Users/yann.jy/Applications/InsightKit.app`.
- Diagnostic script added: `scripts/diagnose_issue24_media_timeline.py`.
- First retry using microphone record `live-9A838721-5715-4CC3-9576-0BF935DD0B05` confirmed the user suspicion that the sample was not useful for audio sync: `recording.mp4` had video but no audio stream.
- System-audio retry `live-6B97D6C8-585F-4790-8FFD-76DD73F6722A` passed media timing diagnostics:
  - metadata duration `84.000s`
  - format duration `84.632s`
  - audio duration `83.955s`
  - video duration `84.632s`
  - failures: none
- New installed-build system-audio retry `live-B5BD191C-0E4E-4A36-A24D-350155C1E65F` passed media timing diagnostics:
  - metadata duration `71.001s`
  - format duration `71.277s`
  - audio duration `70.492s`
  - video duration `71.277s`
  - Smart Minutes timestamps: `00:22`, `00:34`, `00:42`, `00:49`, `00:50`
  - failures: none
- Installed-app Live review proof on `live-B5BD191C-0E4E-4A36-A24D-350155C1E65F`:
  - clicking `00:22 New build system audio start` moved `回看态` to `00:22`;
  - the standard player showed playback toggle `on` and timeline about `22.05s`;
  - a later state read showed `回看态 00:56` and timeline about `56.64s`, proving playback did not stay frozen at the clicked timestamp;
  - clicking `00:34 New build marker five` moved `回看态` to `00:34`, playback toggle stayed `on`, and the timeline later advanced again.

Owner retest:

- Use the installed app at `/Users/yann.jy/Applications/InsightKit.app`, build `20260626144645`.
- For this retest, use system audio or mixed audio if the microphone source is unreliable.
- Capture camera or screen plus audio, stop, generate Smart Minutes, and play `回看资料`.
- Confirm the review media is audible, video remains visible, time links start playback, and the perceived audio/video timing is acceptable.

Scope note:

- Records Workspace playback after reopening a saved Record is still tracked separately as issue 25. This issue only covers the Live Workspace Smart Minutes `回看资料` path.

### 2026-06-26 - Owner retest passed

The owner confirmed the Smart Minutes review-source audio/video synchronization issue is fixed in the installed app.

### 2026-06-27 - Regression reproduced after microphone audio recovered

Status changed to `ready-for-agent` after owner retest showed the new installed fix is still insufficient.

The owner reported that microphone audio is now audible, but the Live Workspace review media again feels out of sync.

Reproduced evidence from the latest saved Record:

- Record Folder: `20260627-1008-live-record-bbe1a3f0`.
- Meeting ID: `live-CFD54B99-3528-470E-90B1-910EBBE1A3F0`.
- Saved media stream durations: audio `39.950s`, video `47.002s`.
- `scripts/diagnose_issue24_media_timeline.py` failed with audio/video stream duration delta `7.052s`.
- Transcript markers were inside the shorter audio timeline, with the last transcript ending at `36.959s`.

Diagnosis:

- The previous fix stopped obvious long-running visual capture during finalization, but the composer still treated the full video duration as the canonical review timeline.
- When the separately captured audio was shorter than the video, the composer padded the audio track with empty time instead of trimming the video to the actual playable audio timeline.
- That made the final review media retain visual-only tail time, which can appear as audio/video drift or delayed visual alignment in playback.
- The saved Record metadata also used the UI recording timer rather than the actual composed media duration, so Record Review could still advertise a longer timeline than the playable review media.

Fix:

- `ReviewMediaComposer` now composes independent audio and video onto the shortest playable media timeline instead of padding short audio to a longer video timeline.
- `records.save` now uses the actual playable media duration when a media file is available, falling back to the UI recording timer only when media duration cannot be read.

Proof:

- `python -m pytest tests/test_live_review_media_sync.py -q`, 3 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp --filter ReviewMediaComposerTests/testComposeVideoWithAudioTrimsVideoToShorterAudioTimeline`, 1 test, 0 failures.
- `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testSaveToRecordsUsesPlayableMediaDurationWhenAvailable`, 1 test, 0 failures.
- `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testPrepareTemporaryRecordingComposesSinglePlayableVideoWhenVideoAndAudioAreCaptured`, 1 test, 0 failures.
- `swift test --package-path macos/InsightKitApp`, 195 tests, 0 failures.
- Installed sync succeeded with the already-passed local gates via `./scripts/sync_insightkit_app.sh --skip-tests`.
- Installed build: `20260627101746`; proof: `logs/workflow/latest_sync.json`.

Owner retest:

- Launch `/Users/yann.jy/Applications/InsightKit.app`, build `20260627101746`.
- Capture a Live Workspace session with camera or screen plus microphone audio.
- Stop the session and generate Smart Minutes.
- Play `回看资料` in the Live Workspace review.
- Confirm sound remains audible and the single media player no longer shows obvious audio/video drift.
- Open the saved Record and confirm Record Review uses the same aligned media timeline.

### 2026-06-27 - Research follow-up after owner retest still failed

The owner reported that audio/video synchronization is still not acceptable.

New local evidence changes the diagnosis:

- Latest inspected record: `20260627-1025-live-record-e1ed1d25`.
- Final saved `recording.mp4` passes duration-level diagnostics:
  - audio duration `26.000s`
  - video duration `26.000s`
  - transcript last segment end `24.960s`
  - failures: `[]`
- The temporary video-only source for the same session is `54.933333s`, while
  the temporary audio source is `26.000000s`.
- The composed temp file is exactly `26.000000s`, which means the latest fix
  can create equal-length output while still selecting the wrong video source
  window.

Conclusion:

- This is not solved by another duration-level trim.
- The next fix needs a shared capture timeline: audio buffer timing, video
  sample-buffer PTS, composition source ranges, and transcript rebasing must all
  use one final media timeline.

Research note:

- `.scratch/manual-qa-2026-06-25/issue24-av-sync-research.md`

Next agent action:

- Add capture timeline instrumentation and make `ReviewMediaComposer` compose
  by timestamp/offset intersection instead of always inserting audio and video
  from source time zero.
- Extend `scripts/diagnose_issue24_media_timeline.py` so a future pass cannot
  be declared from duration equality alone.

### 2026-06-27 - Offset-aware media timeline fix installed

Status changed to `ready-for-human`.

Tight repro loop:

- Command: `swift test --package-path macos/InsightKitApp --filter ReviewMediaComposerTests`
- RED before fix: `testComposeVideoWithAudioUsesTimelineOffsetToSelectMatchingSourceWindow` failed because the composed output still sampled the red first-second video window even when the timeline said audio started at the green second-second window.
- This matched the owner symptom: a final file can have equal audio/video durations while still using the wrong source window.

Fix:

- Added `ReviewMediaCompositionTimeline` and changed `ReviewMediaComposer` to compose the intersection of audio/video source windows on a shared master timeline.
- Added `LiveMediaCaptureTimeline` so Live Workspace records the video source start and first audio source start.
- Tightened video start capture from "start recording was requested" to "first video frame was actually written".
- Passed the captured timeline into review media composition instead of using a zero-aligned default.
- Wrote `capture_timeline.json` next to the temporary composed media and copied it into the saved Record Folder for diagnostics.
- Extended `scripts/diagnose_issue24_media_timeline.py` so old duration-only passes warn when `capture_timeline.json` is missing.

Proof:

- Focused RED/GREEN: `swift test --package-path macos/InsightKitApp --filter ReviewMediaComposerTests`, 2 tests, 0 failures after fix.
- Call-site regression: `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testPrepareTemporaryRecordingComposesSinglePlayableVideoWhenVideoAndAudioAreCaptured --filter LiveSessionViewModelTests/testPrepareTemporaryRecordingPassesCaptureTimelineToReviewMediaComposer`, 2 tests, 0 failures.
- Structural timing gate: `python -m pytest tests/test_live_review_media_sync.py -q`, 3 tests, 0 failures.
- Old owner sample diagnostic now warns instead of overclaiming: `capture_timeline.json is missing; duration equality alone cannot prove audio/video source-window sync`.
- Full Swift gate: `swift test --package-path macos/InsightKitApp`, 197 tests, 0 failures.
- Full Python gate: `python -m pytest -q`, 225 tests, 0 failures, 1 warning.
- Installed sync: `./scripts/sync_insightkit_app.sh --skip-tests`, installed build `20260627104951` to `/Users/yann.jy/Applications/InsightKit.app`.

Owner retest:

- Launch `/Users/yann.jy/Applications/InsightKit.app`, build `20260627104951`.
- Capture a new Live Workspace session with camera or screen plus microphone audio.
- Stop the session and generate Smart Minutes.
- Play `回看资料` and confirm audio/video timing is acceptable.
- Open the saved Record Folder and confirm it contains `capture_timeline.json`; if sync still appears wrong, run `python3 scripts/diagnose_issue24_media_timeline.py <Record Folder>` and report the warning/failure output.

### 2026-06-27 - Retimed video sample-buffer fix installed

Status remains `ready-for-human`.

Owner retest result:

- Audio and transcript timestamps are now synchronized.
- Video is still visibly delayed behind the audio.

New inspected record:

- Record Folder: `20260627-1056-live-record-e69519e2`.
- Final saved `recording.mp4` duration: audio `41.900s`, video `41.900s`.
- Temporary audio source duration: `42.000s`.
- Temporary video-only source duration: `63.381667s`.
- `capture_timeline.json` only reported video starting `0.100224s` after audio, so the recorded timeline sidecar did not explain the `21s+` video-source expansion.

Diagnosis:

- The previous composer and capture-timeline fixes could produce equal-length final media and preserve the audio/transcript clock, but the video-only recording could already have a distorted internal PTS timeline before composition.
- `VideoCaptureService` was appending the original `CMSampleBuffer` directly into `AVAssetWriter`, so camera or ScreenCaptureKit source timestamps could stretch the saved video timeline relative to the real recording clock.
- Once the source video PTS is wrong, trimming or offset composition can still select an apparently valid but visually delayed frame window.

Fix:

- Added `VideoRecordingTimeline` to generate video presentation times from `ProcessInfo.processInfo.systemUptime` elapsed time.
- Changed `VideoCaptureService` to start the writer session at `.zero`.
- Rewrites each captured video frame with `CMSampleBufferCreateCopyWithNewTiming` before appending it, instead of appending the raw source sample buffer.
- Preserved first-frame host-time reporting so `capture_timeline.json` still records the real capture boundary.

Proof:

- RED: `python -m pytest tests/test_live_review_media_sync.py -q` failed on `test_video_recording_retimes_frames_to_recording_clock` before the fix because `VideoCaptureService` still appended raw sample buffers and did not call `CMSampleBufferCreateCopyWithNewTiming`.
- GREEN focused gate: `python -m pytest tests/test_live_review_media_sync.py -q`, 4 tests, 0 failures.
- New Swift regression: `swift test --package-path macos/InsightKitApp --filter VideoRecordingTimelineTests`, 2 tests, 0 failures.
- Full Swift gate: `swift test --package-path macos/InsightKitApp`, 199 tests, 0 failures.
- Full Python gate: `python -m pytest -q`, 226 tests, 0 failures, 1 warning.
- Diff hygiene: `git diff --check`, 0 failures.
- Installed sync: `./scripts/sync_insightkit_app.sh --skip-tests`, installed build `20260627110552` to `/Users/yann.jy/Applications/InsightKit.app`.

Owner retest:

- Launch `/Users/yann.jy/Applications/InsightKit.app`, build `20260627110552`.
- Capture a new Live Workspace session with camera or screen plus microphone audio.
- Stop the session and generate Smart Minutes.
- Play `回看资料`; confirm audio, transcript timestamp, and visible video motion now align.
- If video still lags, keep the new Record Folder and compare the temp video-only duration against final media duration; after this fix they should no longer diverge by tens of seconds.

### 2026-06-27 - Retimed-frame attempt worsened owner-visible sync; return to diagnosis

Status changed to `needs-triage`.

Owner retest:

- The owner reported that build `20260627110552` made the issue worse.
- Treat the retimed sample-buffer approach as a failed hypothesis, not as the next baseline.

Newest local record inspected:

- Record Folder: `20260627-1114-live-record-1a9935ba`.
- Meeting ID: `live-B87D161E-A0D5-4B46-ADD7-16D51A9935BA`.
- Final saved `recording.mp4` duration: audio `8.705s`, video `8.705s`, format `8.705s`.
- Temporary audio source duration: `10.000s`.
- Temporary video-only source duration: `23.356667s`.
- `capture_timeline.json` reported `composition_video_start_sec` `1.296631s`.
- `scripts/diagnose_issue24_media_timeline.py` still produced no failures, proving the current diagnostic loop can pass while the owner-visible sync is worse.

Process decision:

- Stop implementing issue 24 in this context.
- Roll back the retimed sample-buffer experiment from the working tree and installed app; rollback install build `20260627112556` only removes the worsened experiment and is not a fix claim.
- Hand off to a fresh diagnosis session.
- The next session must first build a red-capable feedback loop for visible video lag. Duration equality, stream presence, and transcript timestamp alignment are insufficient acceptance signals.
- If a red-capable loop cannot be built against the current app architecture, route this through an architecture/prototype slice before any production media-pipeline fix.

### 2026-06-27 - Red-capable source-timeline loop added

Status changed to `ready-for-agent`.

Matt workflow packet:

- Goal: create an agent-runnable feedback loop that goes red on the known owner-visible video lag instead of passing on final-media duration equality.
- Context: this issue file, `/tmp/insightkit-issue24-av-sync-handoff-20260627-1126.md`, `.scratch/manual-qa-2026-06-25/issue24-av-sync-research.md`, `docs/agents/loop-engineering.md`, ADR 0005, and the real records `20260627-1056-live-record-e69519e2` / `20260627-1114-live-record-1a9935ba`.
- Boundary: no production media-pipeline fix in this loop; no `ready-for-human` claim; issue 25 transcript/replay-following remains separate.
- Action: extended `scripts/diagnose_issue24_media_timeline.py` to inspect the `capture_timeline.json` temp source media (`videoPath` and `audioPath`) and fail when the source video timeline is much longer than the source audio/final media timeline.
- Verification: the two known owner-failed records now return nonzero with source-timeline failures, while the narrow regression gate still passes.
- Feedback: next implementation loop should target capture/writer time-base proof, not another composer crop or transcript timestamp adjustment.
- Record: proof JSON files are under `logs/diagnostics/2026-06-27/`.

Red feedback loop:

- `python3 scripts/diagnose_issue24_media_timeline.py "$HOME/Documents/InsightKit/Records/20260627-1056-live-record-e69519e2"` now exits `1`.
  - Final `recording.mp4`: audio `41.900s`, video `41.900s`.
  - Temp source media: video `63.381667s`, audio `42.000000s`.
  - Failure: source audio/video duration delta `21.382s`; source video differs from final media by `21.482s`.
  - Proof: `logs/diagnostics/2026-06-27/issue24-1056-source-timeline-red.json`.
- `python3 scripts/diagnose_issue24_media_timeline.py "$HOME/Documents/InsightKit/Records/20260627-1114-live-record-1a9935ba"` now exits `1`.
  - Final `recording.mp4`: audio `8.705s`, video `8.705s`.
  - Temp source media: video `23.356667s`, audio `10.000000s`.
  - Failure: source audio/video duration delta `13.357s`; source video differs from final media by `14.652s`.
  - Proof: `logs/diagnostics/2026-06-27/issue24-1114-source-timeline-red.json`.
- `python -m pytest tests/test_live_review_media_sync.py -q`: 4 passed.

Current finding:

- The final media stream durations and composition-window predictions can be internally consistent while the temp video source timeline is already distorted.
- The likely failure layer is capture/writer source timing, before `ReviewMediaComposer` and before AVPlayer playback.
- The current red loop is source-timeline based, not a visual clapper / pixel-audio correlation test. If the next implementation cannot prove the production capture path directly, build a throwaway AV capture/writer prototype first and hand the result back before changing production behavior.

Ranked hypotheses for the next loop:

1. `VideoCaptureService` is writing raw camera or ScreenCaptureKit sample-buffer PTS into `AVAssetWriter`, so the saved video source timeline can stretch relative to the recording clock.
2. `capture_timeline.json` records only first-frame/audio-start anchors, so it cannot yet distinguish fixed initial offset from drift or late stop without first/last PTS and host-time instrumentation.
3. The retimed sample-buffer experiment worsened sync because the production rewrite changed sample timing without a proven monotonic frame-duration/writer-session model.
4. `ReviewMediaComposer` and AVPlayer playback are less likely as the primary cause for these samples because final stream durations and composition-window duration both match.

### 2026-06-27 - Capture-clock video writer fix installed for owner retest

Status changed to `ready-for-human`.

Diagnosis:

- The red-capable source-timeline loop showed that the final composed media can have equal audio/video durations while the temporary video source timeline is already much longer than the audio source.
- The production writer path still started `AVAssetWriter` from the raw sample-buffer presentation timestamp and appended the raw `CMSampleBuffer`.
- That left the saved video source vulnerable to camera or ScreenCaptureKit source PTS drift before `ReviewMediaComposer` had a chance to crop the correct window.

Fix:

- `VideoCaptureService` now samples `ProcessInfo.processInfo.systemUptime` at the capture callback boundary, before dispatching work onto the writer queue.
- Added `VideoRecordingTimeline` to map captured frames onto a monotonic recording clock that starts at `0`.
- `AVAssetWriter` now starts its recording session at `.zero`.
- Each video sample is copied with a new presentation timestamp from the capture-time clock before being appended to the writer.
- The previous failure mode of using append-time/writer-queue timing is avoided by capturing `capturedAt` before `writerQueue.async`.

Proof:

- `swift test --package-path macos/InsightKitApp --filter VideoRecordingTimelineTests`, 2 tests, 0 failures.
- `python -m pytest tests/test_live_review_media_sync.py -q`, 5 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp`, 199 tests, 0 failures.
- `git diff --check`, 0 failures.
- `codesign --verify --deep --strict /Users/yann.jy/Applications/InsightKit.app`, passed.
- Installed sync: `./scripts/sync_insightkit_app.sh --skip-tests`, installed build `20260627115314` to `/Users/yann.jy/Applications/InsightKit.app`.
- Sync proof: `logs/workflow/latest_sync.json`.

Owner retest:

- Launch `/Users/yann.jy/Applications/InsightKit.app`, build `20260627115314`.
- Capture a new Live Workspace session with camera or screen plus microphone or mixed audio.
- Stop the session and generate Smart Minutes.
- Play `回看资料`; confirm audio, transcript timestamp, and visible video motion align.
- Run `python3 scripts/diagnose_issue24_media_timeline.py <new Record Folder>`.
- Expected diagnostic result: no source-timeline failure; temp source video and audio durations should no longer diverge by many seconds.

Scope note:

- The old failed records remain red because their source media is already written with the old timing. This build must be judged against a new installed-app capture.

### 2026-06-27 - Owner retest passed

Owner retest passed after the capture-clock video writer fix installed in build `20260627115314`.

Result:

- A new installed-app Live Workspace capture no longer shows the owner-visible Smart Minutes `回看资料` audio/video lag that issue 24 tracked.
- Issue 24 remains separate from issue 25: this issue covers capture-source audio/video synchronization for Smart Minutes review media, while issue 25 covers saved Record Review playback continuity.
- The old failed records remain useful diagnostic fixtures only; their source media was already written with old timing.

Current state:

- No further issue 24 agent action is required unless a new installed-app capture reproduces the synchronization failure.
