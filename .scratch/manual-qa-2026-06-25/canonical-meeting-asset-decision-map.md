# Canonical Meeting Asset Decision Map

Status: active
Last reviewed: 2026-06-26

## Purpose

Resolve issue 33: whether Record Review and Smart Minutes should share one canonical Meeting Asset source, and use that rule to guide the next issue 27 fix.

## #1: Should Record Review and Smart Minutes share one source?

Blocked by: None
Type: Discuss

### Question

For one saved Record, should Record Review and Smart Minutes behave as two views over the same Meeting Asset rather than two separately prepared resources?

### Answer

Yes.

Record Review and Smart Minutes should read from the same canonical Meeting Asset source:

- one canonical review media source;
- one Media-Timed Transcript;
- one speaker-name mapping;
- one notes collection;
- one Insight Package behind Smart Minutes.

This means Record Review and Smart Minutes can have different layouts, but they should not silently use different media, timestamps, speaker names, or generated content for the same saved Record.

## #2: What is the canonical media rule?

Blocked by: #1
Type: Discuss

### Question

When a clean original recording exists, should playback surfaces use it directly instead of generating a second review-media file?

### Answer

Yes, by default.

The saved recording should be treated as the canonical review media whenever it already contains the audio/video needed for playback. Derived media may be created only as a fallback or export aid, not as an invisible replacement that changes playback quality.

For issue 27, this means the next fix should compare:

- the original captured recording;
- the media used in Record Review;
- the media used in Smart Minutes review.

The user-facing pass condition is simple: playback should sound like the original captured recording, with no added electrical noise.

## #3: What if audio and video are captured separately?

Blocked by: #2
Type: Prototype

### Question

If the app captures video and audio as separate files, how should it create one canonical review media source without adding noise or sync drift?

### Answer

Unresolved implementation ticket.

The next agent should inspect the current capture and save path, then choose the least destructive strategy:

- prefer a single original recording that already contains audio and video;
- if composition is unavoidable, create one canonical composed media file once, verify it against the original audio, and make both Record Review and Smart Minutes point to that same file;
- preserve the original captured sources for recovery and diagnosis, but do not make normal review surfaces choose between inconsistent files.

## #4: How should speaker-name edits propagate?

Blocked by: #1
Type: Discuss

### Question

Should speaker-name edits in Smart Minutes finalization and Record Review update one shared speaker mapping?

### Answer

Yes.

Speaker-name edits are corrections to the Meeting Asset, not cosmetic edits to one screen. A rename made in Smart Minutes finalization or Record Review should be visible anywhere the same Record shows transcript rows, Speaker Perspective content, exports, or evidence links.

This unblocks issue 32.

## #5: Does this require a visible product explanation?

Blocked by: #1
Type: Discuss

### Question

Should the app expose this model to users?

### Answer

Only lightly.

Users do not need to understand the internal source model. The app should simply feel consistent. If recovery media or derived media is being used because the canonical recording failed, the app should show a short status message in plain language.
