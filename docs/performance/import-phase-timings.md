# Import phase timings

Import jobs expose local diagnostic spans under `phase_timings` in each job
returned by `transcription.status` (including `active_job`, `queue`, and
`last_completed.job`). This adds a measurement source for YAN-10 / GH-6.
Existing progress, push events, UTC timestamps, and transcription results keep
their existing meaning. In particular, `started_at` remains the enqueue time.

## Reading a snapshot

The timing subtree has only `schema_version` (1), `job_id`, `clock`
(`monotonic_ns`), `sampled_offset_ns`, and `spans`. Each span contains a fixed
`phase`, `start_offset_ns`, nullable `end_offset_ns`, `duration_ns`, and
`outcome`. All offsets use the recorder's creation as zero in the same sidecar
process. Convert durations to milliseconds by dividing by 1,000,000; do not
subtract UTC fields or compare offsets from different jobs or processes.

While a span is open, its outcome is `running`, its end is null, and its
duration ends at the snapshot's sampling time. A closed span has `completed`,
`failed`, `cancelled`, or `skipped`. Snapshots are detached copies and cannot
change the stored observations. Phase completion describes the call's outcome,
not the quality of its returned transcript or minutes.

Recorders are in memory for the lifetime of the existing JobQueue. Poll and
retain the selected job's timing subtree during a diagnostic run, including
after execution has ended. There is no automatic file, SQLite persistence,
new push stream, or external telemetry. Sidecar shutdown loses these spans;
this feature does not provide recovery across restarts. Do not publish the
entire status response: its existing fields can contain paths, titles and
error text. The new timing subtree contains none of those fields or payloads.

## Boundaries

| Phase | Start and stop |
| --- | --- |
| `queue_wait` | Queue admission to worker selection, or cancellation before selection |
| `job_execution` | Worker selection to its terminal handling and cleanup |
| `transcription` | Runner's call to `transcribe`, including its temporary audio cleanup |
| `audio_preparation` | Audio extraction and duration probe |
| `speech_detection` | Qwen's VAD check |
| `qwen_session_ready` | Model source/cache lookup and worker ready barrier |
| `qwen_session_initialize` | Actual Session construction, only attributed to the job that created that worker |
| `qwen_worker_wait` | Qwen transcription request submission to worker selection, or startup failure |
| `qwen_session_transcribe` | Actual third-party `Session.transcribe` call on the owning thread |
| `segment_conversion` | Conversion of Qwen results to application segments |
| `speaker_attachment` | Independent speaker attachment, or an explicit skipped path |
| `persist_segments` | Transcript segment insertion loop |
| `final_generation` | Runner's first `build_final` call |
| `final_generation_fallback` | Runner's local fallback after that call raises |
| `persist_final` | Provenance attachment, metadata read and insight package store |
| `record_write` | Import runner's direct `RecordWriter.write_record` call |

These are nested, inclusive spans: `transcription` contains audio preparation
and Qwen work; initialization can overlap the ready barrier. Do not sum all
spans. List order can differ from chronological order because initialization
is attached as a completed receipt. Use offsets when building a timeline.
Cached or prewarmed sessions have no new initialization receipt for that job;
missing initialization does not mean a zero-cost initialization was measured.

The Qwen library can perform ASR, alignment and built-in diarization within
`qwen_session_transcribe`. Those costs remain inseparable here. Speaker
attachment may also return successfully without usable labels because the
existing diarization implementation permits a degraded result. The
`final_generation` call includes any internal provider handling and fallback;
`final_generation_fallback` covers only the runner's exception fallback.

Cancellation is cooperative. Existing job status can say `cancelled` or
`paused_by_live` while a synchronous model call is still unwinding. Open spans
continue to update until that call actually returns, then `job_execution`
closes as cancelled. A successfully returned model call can therefore have a
completed span within a cancelled job. Cancelling a queued job creates no
execution or model span. Failures retain earlier spans; a successful fallback
does not replace the failed attempt.

## Coverage and use

The context is set around each queued job and restored afterwards. Ordinary
direct `transcribe(path)` and Live chunk calls do not create a recorder. Qwen
worker requests carry a separate optional recorder member, never an additional
third-party model argument, and cached workers do not retain previous jobs.

This is instrumentation, not a measured speed improvement or a completed
benchmark. It does not time media selection, first visible progress, the
Swift-side final refresh, Record Review readiness, playback, or native export.
The direct Import record write is not the protocol's `records.save` RPC span.
Do not relabel the inclusive transcription envelope as pure ASR time or its
ratio as a canonical ASR RTF. Continue to use the
[installed-app benchmark protocol](./installed-app-benchmark-protocol.md) for
cohort controls, UI boundaries, repeated runs, resources, source hashes and
quality gates. Stubbed timing tests establish measurement behavior, not model
quality or installed-app performance.
