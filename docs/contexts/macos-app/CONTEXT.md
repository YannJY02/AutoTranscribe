# macOS App

Language for the native InsightKit app experience. This context names user-visible workflows and app-state concepts without treating Swift implementation names as the domain model.

## Language

**Home Workspace**:
The app's starting surface for choosing live capture, import, or records review.
_Avoid_: Dashboard, landing page

**Live Workspace**:
The workflow for capturing an active meeting and producing live transcript and insight state.
_Avoid_: Recording page, live view

**Live Session Finalization**:
The post-stop Live Workspace phase that turns captured media, transcript state, Smart Minutes, and notes into a saved record-ready meeting asset.
_Avoid_: Stop handler, save helper, cleanup step

**Session Shell**:
The shared three-panel app skeleton used by live, import, and record-review workflows to keep Smart Minutes, media/transcript, and notes aligned.
_Avoid_: Layout wrapper, split view

**Session Phase**:
The user-visible stage of a live or import session, such as preparing, running, post-session finalization, processing, or reviewing.
_Avoid_: Enum state, internal mode

**Import Workspace**:
The workflow for selecting existing media and turning it into a record.
_Avoid_: Upload flow, file picker

**Records Workspace**:
The workspace for finding and reopening saved meeting assets.
_Avoid_: Library, archive

**Record Review**:
The reopened view of a saved record, including media, transcript, Smart Minutes, notes, and exports.
_Avoid_: Detail page, playback page

**Record Index**:
The app-maintained view of local record folders used for listing, filtering, search, and reopening records.
_Avoid_: File browser, archive scan

**Panel Data Source**:
The app-side contract that lets panels read chapters, Smart Minutes, transcript rows, media state, and notes without coupling to one workflow implementation.
_Avoid_: View model dump, UI adapter

**Audio Input Mode**:
The user's selected capture source: microphone, system audio, or mixed audio.
_Avoid_: Device mode

**Capture State**:
The user-visible state of a live capture, such as waiting, preparing runtime, warming model, capturing, transcribing, refreshing, or recovering permission.
_Avoid_: Status string

**Simultaneous Visual Presentation**:
The Live Workspace presentation mode where screen content and camera presence coexist as one visual surface. Record Review should treat the result as one media surface, not as two competing visual sources.
_Avoid_: Separate camera and screen recordings, source toggle conflict, custom layout editor

**Permission Recovery**:
The app state where capture is blocked until the user restores a required macOS permission.
_Avoid_: Error handling

**Time-Bound Note**:
A note attached to a playback time so it can later seek back to the same meeting moment.
_Avoid_: Comment, annotation

**Media Seek**:
A user action that jumps playback to the time represented by a transcript row, timeline beat, evidence span, or note.
_Avoid_: Jump, scrub

**Media Timeline**:
The playback clock inside the saved audio or video, starting at 00:00 when the record media begins. Record Review timestamps should refer to this clock, not to when live processing happened.
_Avoid_: Wall-clock time, chunk time, processing time

**Transcript Recovery**:
The user-triggered path for regenerating a missing or stale media-timed transcript from a saved record's media.
_Avoid_: Retry button, draft transcript restore

**Insight Refresh**:
An app-visible update of live or final Smart Minutes based on the current transcript and provider state.
_Avoid_: Regenerate, summarize

**Live Transcript Pipeline**:
The app-side module seam that turns audio chunks into Live Transcript Delta, optional Insight Refresh, provider-degradation state, and Live Workspace metrics.
_Avoid_: processChunk helper, live ASR wrapper

**Needs Review Count**:
The number of generated items that should be treated as uncertain and checked by the user.
_Avoid_: Warning count, error count

**Export Document**:
A shareable Markdown or PDF representation of a record.
_Avoid_: Report, file output

**Settings Workspace**:
The app surface for local runtime, provider, and permission configuration.
_Avoid_: Preferences
