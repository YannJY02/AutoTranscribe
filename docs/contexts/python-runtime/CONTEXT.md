# Python Runtime

Language for InsightKit's local runtime. This context names the concepts used when transcript, speech, provider, record, and sidecar behavior are discussed.

## Language

**Sidecar**:
The local runtime companion that handles speech, transcript, records, provider checks, and insight generation for the app.
_Avoid_: Backend, server

**RPC Action**:
A named callable operation exposed by the sidecar to the app or an integration host.
_Avoid_: Endpoint, API route

**RPC Event**:
A pushed runtime message sent over the persistent RPC connection, such as transcription progress, transcription completion, or warmup state changes.
_Avoid_: Callback, notification

**Meeting ID**:
The stable identifier that ties a session, transcript, insight package, and record together.
_Avoid_: File id, job id

**Transcript Segment**:
A timestamped unit of transcript text with optional speaker, source, and confidence information.
_Avoid_: Sentence, caption

**ASR Engine**:
The selected speech-to-text engine used to turn audio into transcript segments.
_Avoid_: Model, provider

**ASR Runtime**:
The local speech runtime environment needed before an ASR engine can transcribe reliably.
_Avoid_: Dependency setup, model folder

**ASR Runtime Profile**:
The shared runtime rule set for ASR engine selection, model readiness, backend status, warm state, and diarization reporting.
_Avoid_: ASR config helper, status wrapper

**ASR Model Catalog**:
The script-side source of truth for supported ASR engines, default models, recommended candidates, and model-repository aliases.
_Avoid_: Hard-coded model list

**Runtime Warmup**:
The readiness phase in which local speech resources are prepared before live or import transcription should rely on them.
_Avoid_: Loading, boot

**Runtime Snapshot**:
A non-blocking status view of ASR backend and warm state that the app can read even while model loading or prewarm work is active.
_Avoid_: Live lock query, model probe

**Prewarm Watchdog**:
The sidecar-side guard that turns an overlong ASR prewarm into an explicit failed warm state instead of letting the app wait on an unbounded background operation.
_Avoid_: App timeout, UI spinner

**Diarization**:
Speaker separation that assigns speech spans or transcript segments to speaker labels.
_Avoid_: Speaker recognition, identity detection

**Provider**:
An external or local analysis vendor used for insight generation, distinct from the ASR engine.
_Avoid_: ASR engine, model

**Provider Probe**:
A bounded availability check that confirms whether a provider can currently produce usable insight output.
_Avoid_: Login test, health check

**Strict Local ASR**:
The policy that speech-to-text should not silently fall back to network downloads or cloud transcription.
_Avoid_: Offline mode

**Transcription Job**:
An asynchronous unit of work for importing or watching media and producing transcript-backed meeting data.
_Avoid_: Session, record

**Job Queue**:
The runtime queue that orders transcription jobs and reports job state.
_Avoid_: Task list, backlog

**Record Writer**:
The runtime component that writes a completed live or imported session into a consistent local Record Folder.
_Avoid_: Export helper, Swift file writer

**Record Save Action**:
The `records.save` RPC action used by app workflows to persist media, metadata, transcript, minutes, notes, and insight-package data through the Record Writer.
_Avoid_: Local save call, direct JSON write

**Live Transcript Delta**:
New transcript segments produced during an active live session and appended to the current meeting.
_Avoid_: Streaming text, partial result

**Final Insight Generation**:
The post-session pass that turns accumulated transcript evidence into the final insight package.
_Avoid_: Summarization
