# Live review media does not display video

Status: ready-for-human

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

When reviewing a completed Live Workspace session, the central media area did not show the expected video. Instead, the review surface showed a dark media placeholder with a generic playback icon, while transcript rows and chapter entries were visible below and beside it.

The user expected to be able to review the captured video alongside the transcript and Smart Minutes, but the media view did not display the recorded visual content.

## What I expected

In review state, the Session Shell should show playable meeting media when the live session captured video or screen content.

If no video was actually saved, the app should clearly say that only audio/transcript is available instead of showing a broken or generic media placeholder.

## Steps to reproduce

1. Launch the installed InsightKit app.
2. Open the Live Workspace.
3. Start a live recording session with video or screen capture enabled.
4. Stop the session and enter review/post-session state.
5. Look at the central media area above the transcript rows.
6. Observe that the video does not display normally and the media area shows a dark placeholder instead.

## Additional context

Reported during owner-led manual QA against installed InsightKit build `20260625094746`.

Visible session context:
- meeting ID: `live-CE6088C3-93DB-4FDE-AD59-9BAD0732FDFD`
- transcript rows and chapter entries were visible
- Smart Minutes content was visible
- the problem is specifically with the review media display, not with transcript or Smart Minutes availability

This may be related to whether the live session saved an actual video asset, whether the review view loaded the saved media correctly, or whether the media player is showing an unhelpful fallback state. It should be triaged as a Record Review / live review media behavior issue.

## Comments

### 2026-06-25 - Manual QA

The owner reported that video could not display normally when reviewing the record after a live session.

### 2026-06-25 - Batch dependency triage

Promoted to `ready-for-agent`.

Code triage found that Live Session currently prepares a combined audio WAV for saving and uses that as the review media URL. `VideoCaptureService.startRecording(to:)` exists, but no current Live Session path calls it. This issue should follow the Capture Preview wiring and aspect-ratio fixes unless the chosen implementation is to show an explicit audio-only review state.

See `.scratch/manual-qa-2026-06-25/triage-dependency-map.md`.

### 2026-06-25 - Additional evidence

The owner provided another completed Live Workspace session where review state still showed a dark generic playback placeholder instead of the captured video.

Visible session context:
- meeting ID: `live-37056EA5-F6A0-44D6-9701-7E500A5935AE`
- review state around `00:05`
- transcript rows, chapter entries, and Smart Minutes were visible
- the central media area still did not display normal video content

This is the same behavior as this issue, not a new issue.

### 2026-06-25 - Diagnosing-bugs implementation pass

Root cause found: Live Session prepared a combined audio WAV for review and records saving, but no Live Session path started `VideoCaptureService.startRecording(to:)`. Even if a video file existed, `prepareTemporaryRecordingForSave` preferred audio chunk concatenation and could override video review media.

Implemented:

- Live Session now starts a visual mp4 recording when a camera or screen visual source is selected.
- Stop flow now finishes video writing before preparing review media and record saving.
- `prepareTemporaryRecordingForSave` now prefers a usable existing video recording for review.
- If a visual source was expected but no usable video frames were saved, the app falls back to audio while showing an explicit audio-only review message instead of a misleading broken-video placeholder.
- Video writing only counts as usable after at least one real video frame is received.
- Added regression coverage:
  - `LiveSessionViewModelTests/testPrepareTemporaryRecordingPrefersExistingVideoRecordingForReview`
  - `LiveSessionViewModelTests/testPrepareTemporaryRecordingShowsAudioOnlyStatusWhenExpectedVideoIsMissing`

Verification:

- Red loop: `testPrepareTemporaryRecordingPrefersExistingVideoRecordingForReview` initially failed because `prepareTemporaryRecordingForSave` returned nil instead of using `recording.mp4`.
- Green loop: issue 08 media tests passed after implementation.
- Media-chain target gate passed for issues 01, 02, and 08.
- Full gate: `swift test --package-path macos/InsightKitApp` passed, 135 tests, 0 failures.
- Installed app sync completed together with issues 01 and 02.
- Installed app: `/Users/yann.jy/Applications/InsightKit.app`.
- Installed build: `20260625113541`.
- Sync proof: `logs/workflow/latest_sync.json`.
- Sync gates: Swift package tests passed; Python unittest suite passed with `Ran 136 tests ... OK`.

Owner retest focus:

- If camera or screen capture is enabled and frames are captured, review media should be video rather than the generic audio placeholder.
- If video capture cannot save frames, the app should say that the review is audio/transcript/notes-only.

### 2026-06-25 - Owner retest passed

The owner confirmed that the shared Capture Preview / Record Review media-chain fix was successful.
