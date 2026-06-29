# Product Model

Language for InsightKit as a personal meeting-asset product. This context names the user-facing concepts that should stay stable across runtime, app, export, and integration work.

## Language

**InsightKit**:
A personal macOS meeting assistant that turns live or imported meeting media into searchable, reviewable, and exportable meeting assets.
_Avoid_: AutoTranscribe, Feishu clone, Lark clone

**AutoTranscribe**:
The repository's legacy local transcription capability and lineage. Use this name only when discussing the older desktop/downloads watcher and plain transcript output, not the current meeting-assistant product.
_Avoid_: InsightKit

**Meeting Asset**:
A durable personal knowledge object created from a meeting or recording. It combines media, transcript, structured minutes, notes, and exportable documents.
_Avoid_: File, artifact, project

**Canonical Meeting Asset Source**:
The single saved meeting-asset state that Record Review, Smart Minutes, exports, and notes should read from for the same record. It keeps media, media-timed transcript, speaker names, notes, and the insight package consistent across views.
_Avoid_: Per-view copy, duplicate review source, separate summary resource

**Meeting Asset Health**:
The app-visible completeness state of a saved meeting asset, such as complete, missing transcript, fallback Smart Minutes, damaged transcript, or missing media.
_Avoid_: File validation, loader status, diagnostics result

**Record Folder**:
The local folder representation of a saved record. It contains the media file, metadata, transcript, minutes, insight package, notes, and exports needed to reopen or recover the meeting asset.
_Avoid_: Dump folder, cache directory

**Record**:
A saved meeting asset that can be reopened, searched, reviewed, annotated, and exported.
_Avoid_: Meeting, job, session

**Session**:
A bounded meeting activity that is being captured, imported, transcribed, or analyzed before it becomes a record.
_Avoid_: Record, file

**Smart Minutes**:
The structured meeting-summary surface that turns transcript evidence into overview, highlights, speaker perspectives, decisions, actions, and timeline entries.
_Avoid_: AI notes, summary blob, minutes text

**Smart Minutes Module**:
A named section inside Smart Minutes, such as Session Overview, Highlight Insight, Speaker Perspective, Decision Ledger, Action Track, Timeline Beat, or Related Links Section.
_Avoid_: Tab, widget, random section

**Reference Output Pattern**:
A privacy-safe structure reference extracted from historical sample outputs. It describes reusable module shapes without copying the original meeting content, people, tasks, or third-party UI.
_Avoid_: Fixture, golden output, current design spec

**Meeting Envelope**:
The export header that names the document, topic, meeting time, participants or speaker fallback, source, media type, duration, and review notice for a record.
_Avoid_: Header, metadata block

**AI Review Notice**:
The explicit warning in app-generated minutes or exports that generated content may be inaccurate and should be checked against source media before archival, sharing, or decisions.
_Avoid_: Legal disclaimer, placeholder text

**Related Links Section**:
The export section that points back to the original record, transcript, media playback, or other provenance links for the meeting asset.
_Avoid_: Link dump, appendix links

**Insight Package**:
The complete structured insight payload for a session or record. It is the canonical package behind Smart Minutes.
_Avoid_: JSON result, analysis output

**Session Overview**:
The top-level summary of what the meeting was about and which topics it covered.
_Avoid_: Abstract, executive summary

**Highlight Insight**:
A high-signal quoted moment from the meeting paired with why it matters.
_Avoid_: Quote card, golden sentence

**Speaker Perspective**:
A participant-centered summary of viewpoints expressed by one speaker.
_Avoid_: Speaker summary, speaker notes

**Decision Ledger**:
The structured list of decisions, including the problem, considered options, chosen decision, rationale, and owner when known.
_Avoid_: Key decisions, decision list

**Action Track**:
A trackable follow-up task extracted from or created after the meeting.
_Avoid_: Todo, action item

**Timeline Beat**:
A time-ordered chapter in the meeting, with a timestamp, title, and short summary.
_Avoid_: Smart chapter, chapter

**Provenance Link**:
A reference that connects Smart Minutes back to source material such as the original record, transcript, media, or export.
_Avoid_: Related link

**Evidence Span**:
A timestamp range that ties a generated insight, decision, or action back to the underlying transcript or media.
_Avoid_: Citation, timestamp

**Media-Timed Transcript**:
A transcript whose timestamp ranges are measured against the saved media playback clock, so each row points to where the words are heard in the final audio or video.
_Avoid_: Live chunk transcript, processing-time transcript

**Local Personal Substitute**:
A deliberately personal/local replacement for a team or cloud collaboration feature.
_Avoid_: Missing feature, degraded feature
