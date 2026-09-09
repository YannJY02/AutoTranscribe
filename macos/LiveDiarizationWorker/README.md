# Live diarization worker

`InsightKitLiveDiarization` holds one FluidAudio LS-EEND model and streaming state
across audio chunks. It reads JSONL from stdin and writes one JSON response per
request to stdout. Dependency diagnostics are redirected to stderr. Closing stdin
releases the active session and exits.

Build on macOS 14 or newer with Swift 6:

```sh
scripts/build_live_diarization_worker.sh release
xcrun swift test --package-path macos/LiveDiarizationWorker
```

The build script prints the executable path; build output goes to stderr. SwiftPM
resolves FluidAudio at the revision in `Package.swift` and `Package.resolved`,
including its text-processing binary dependency. The worker uses LS-EEND APIs that
are absent from FluidAudio's v0.12.4 tag, so the upstream revision is pinned.

The worker loads existing compiled weights directly with Core ML's CPU backend.
It does not download models. The default is the cached DIHARD3 500 ms model under
`~/Library/Application Support/FluidAudio/Models/ls-eend/dih3/`. Set
`INSIGHTKIT_LSEEND_MODEL_PATH` or a start request's `model_path` to an existing local
`.mlmodelc` directory to override the cache location. `variant` selects cache
lookup (`dihard3`, `dihard2`, `ami`, or `callhome`); an explicit model path takes
precedence.

## Protocol

```json
{"id":1,"action":"start","session_id":"recording-1","variant":"dihard3"}
{"id":2,"action":"feed","session_id":"recording-1","wav_path":"/absolute/chunk.wav","offset_ms":0}
{"id":3,"action":"feed","session_id":"recording-1","wav_path":"/absolute/next.wav","offset_ms":1000}
{"id":4,"action":"finish","session_id":"recording-1"}
```

IDs are nonempty strings or integers and must be unique within an active session.
`start` replaces a different active session after releasing it. Starting the same
active session again is rejected. `reset` releases the matching session without
finalizing it; `finish` flushes pending right context, returns the last cumulative
timeline, and releases the session. Each later recording requires `start`.

`feed` accepts local RIFF/WAVE files containing mono 16 kHz PCM16 or IEEE float32
audio. Offset is on the recording media clock. Omit it to append exactly after the
last accepted sample. Forward gaps are fed as silence so speaker timing remains
absolute. An integer offset may round down by less than one millisecond; that
chunk appends at the exact sample cursor. Larger overlaps or older chunks are
rejected. Validation failures preserve the session; an inference failure releases
it because partial inference cannot be retried safely.

Every response includes `id`, `ok`, `session_id`, `session_active`, `spans_mode`
(`cumulative`), `spans`, `received_until_ms`, and `finalized_until_ms`. A span is
`{"start_ms":0,"end_ms":1000,"speaker":"SPEAKER_00"}`. Multiple speaker spans
can overlap. Speaker slots are session-local, zero-based model outputs, not person
identities. Responses contain only finalized predictions; received audio can
extend beyond the finalized cursor while LS-EEND waits for right context. Final
speech frames remain visible while their segment is still open: the snapshot
includes that segment only through the finalized cursor. Padding is clipped to
the accepted media duration. Errors add
`error: {"code":"...","message":"..."}`; malformed JSON has a null ID.

The worker bounds requests at 64 KiB, chunks at 30 seconds, gaps at 120 seconds,
sessions at one hour, and accepted requests at 20,000 per session. Audio is fed in
500 ms blocks; raw prediction storage retains 512 frames while finalized spans
remain available for the bounded session. An oversized JSON line is discarded
through its newline, allowing the next request to proceed. The caller should
terminate the process if its request deadline expires rather than retry an
ambiguous feed.

Tests use a fake inference engine to verify state reuse, gaps, ordering, cleanup,
failure invalidation, framing, WAV validation, and final padding. They also use
the real SDK timeline without a model to verify stable open speech and exclude
unstable right context. A subprocess test sends two requests independently while
keeping stdin open; both must respond within two seconds without loading a model.
A real-model smoke test must use the repository's shared capture/performance
resource lock and does not substitute for human speaker-quality evaluation.
