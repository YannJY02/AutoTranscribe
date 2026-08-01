# Installed-App Performance Benchmark Protocol

Status: canonical

This protocol defines comparable performance measurement for InsightKit on the
accepted reference Mac. It measures the packaged Canonical Installed App and
its Python sidecar. It does not choose optimizations or set performance
budgets.

## Workflow authority

Matt workflow remains authoritative for ticket claiming, dependency order,
one-ticket-per-task execution, verification, resolution, and map updates.
`find-skills` may select non-Matt auxiliary skills, but those skills cannot
override the Matt workflow. Profiling is evidence collection, not permission
to implement a suspected optimization.

## Reference environment

- Hardware: MacBook Pro (`MacBookPro18,1`), Apple M1 Pro, 16 GB memory.
- App: `/Users/yann.jy/Applications/InsightKit.app`, packaged in Release mode
  from a clean source revision.
- Record the source revision, `CFBundleVersion`, code-directory hash, executable
  SHA-256, macOS build, Xcode build, and tool versions for every cohort. Also
  record a deterministic installed-bundle inventory SHA-256 over the sorted
  relative path, type, byte size, and SHA-256 (or symlink target) of every
  bundle entry, including nested helpers, resources, and the Python sidecar.
- Plug into power, disable Low Power Mode, and keep display connections and
  brightness fixed.
- Close unrelated apps. Before a run, require system CPU below 5% for 60
  continuous seconds and thermal state `nominal`.
- Keep fixture hashes, InsightKit configuration, provider/model, and network
  type fixed. A change to any fixed field starts a new cohort.
- Keep cold and warm results separate. Do not compare different cohorts as one
  sample.

## Reference Benchmark Corpus

The corpus contains reproducible, sanitized meeting media. Existing private
Record Folders are not corpus inputs. Each media file and reference transcript
must be pinned by SHA-256 before the first measured run.

| Fixture ID | Duration | Language | Speakers | Canonical media |
| --- | ---: | --- | ---: | --- |
| `short-zh` | 5 minutes | Chinese | 2 | M4A |
| `short-en` | 5 minutes | English | 2 | M4A |
| `short-mixed` | 5 minutes | Chinese/English | 2 | M4A plus MP4 companion |
| `long-mixed` | 60 minutes | Chinese/English | 3 | M4A plus MP4 companion |

The MP4 companions reuse the exact M4A audio content. Fixtures retain natural
pauses and limited overlapping speech. Noise and accent stress corpora are out
of scope. Each reference transcript also identifies expected decisions,
actions, and evidence-bearing spans needed for Smart Minutes quality checks.

The corpus manifest must record, for every asset:

- fixture ID, absolute local path, byte size, SHA-256, container, codecs, and
  exact media duration;
- language and speaker count;
- reference-transcript path and SHA-256;
- expected decision, action, and evidence-span counts;
- generation or source provenance and confirmation that the asset is safe for
  local benchmark use.

No baseline run is valid until this manifest is frozen. Live Workspace replays
the fixtures through system audio. Microphone and mixed-input paths receive
permission and functionality smoke checks only; they are not cross-run
performance samples. Do not add a virtual-audio dependency.

Records Workspace uses deterministic, sanitized collections of 100 and 1,000
complete, parseable Record Folders. The 100-record collection represents the
current personal scale; the 1,000-record collection is the growth case. Their
fixture manifest records the generator source revision and version, seed, and
a deterministic collection SHA-256 over the sorted relative path, type, byte
size, and content SHA-256 of every entry. Media interaction uses the mixed MP4
companions.

The frozen v1 inputs are pinned in the
[fixture corpus manifest](./fixture-corpus-manifest.json). Use the
[generation and verification instructions](./fixture-corpus.md) before any
baseline ticket runs.

## Cold and warm runs

**Cold run**:

1. Restart the reference Mac.
2. Wait five minutes, then satisfy the CPU and thermal start gate.
3. Confirm that InsightKit and its sidecar are not running.
4. Launch the Canonical Installed App for the first time after restart.

**Warm run**:

1. In the same boot, complete one successful unmeasured priming run of the
   scenario.
2. Reset only scenario outputs and relaunch the app.
3. Preserve OS, file, and model caches.

Never use `purge` or manually delete system caches. Between long runs, wait
until thermal state returns to `nominal`.

## Run counts and summaries

| Scenario cost | Cold | Warm |
| --- | ---: | ---: |
| Launch, interactions, and five-minute fixtures | 3 | 10 |
| Sixty-minute fixtures and resource curves | 3 | 3 |

Keep every raw run, including task failures and statistical outliers. Report
individual values, median, minimum, maximum, median absolute deviation, success
rate, and failure count. Do not silently exclude a sample. This protocol does
not assign pass/fail budgets or promise a p95 from samples of three or ten;
those decisions follow completed baselines.

Before the first measured run, freeze a `scenario_parameters` block in the
cohort manifest. It contains hashes for replayable keyboard, pointer, scroll,
and resize input traces; workspace navigation order; the generated-record
search query; playback window (60 seconds); seek target (60% of media
duration); and post-workload recovery window (five minutes). Every repeated run
uses that block unchanged. A missing or changed parameter starts a new cohort.

## Scenario matrix

| Performance ticket | Required scenarios |
| --- | --- |
| [Measure launch, workspace loading, and interaction responsiveness](https://github.com/YannJY02/AutoTranscribe/issues/4) | Installed-app launch to usable Home Workspace; navigation to each workspace; input response; Record list and long transcript scrolling; window resize |
| [Measure Live Workspace first-transcript and sustained-flow performance](https://github.com/YannJY02/AutoTranscribe/issues/5) | System-audio replay of all short fixtures and `long-mixed`; runtime readiness; capture start; first and steady transcript deltas; queue depth and drops; Insight Refresh |
| [Measure Import Workspace transcription, finalization, and export throughput](https://github.com/YannJY02/AutoTranscribe/issues/6) | Import all M4A fixtures; first progress; transcription and diarization; finalization; Record save; Markdown and PDF export |
| [Measure Smart Minutes time to useful and final insight](https://github.com/YannJY02/AutoTranscribe/issues/7) | Fixed provider/model on every fixture; readiness; first useful output; refresh; final valid Insight Package |
| [Measure Records Workspace indexing, opening, search, and media interaction](https://github.com/YannJY02/AutoTranscribe/issues/8) | Index refresh and fixed-query search at 100 and 1,000 records; Record open and asset load; MP4 start, seek, and sustained playback |
| [Measure sidecar lifecycle and whole-app resource efficiency](https://github.com/YannJY02/AutoTranscribe/issues/9) | App and sidecar startup/shutdown; idle, active, and post-workload resource curves across launch, Live, Import, Smart Minutes, Record Review, and long-workload recovery |

## Metric contract

Metric names use `<domain>.<event_or_span>_<unit>`. Every recorded metric must
include its name, value, unit, direction (`lower`, `higher`, or `informational`),
start event, stop event, component, phase, and measurement source. Durations use
a monotonic clock. RTF is processing seconds divided by media seconds.

### User-perceived metrics

| Metric | Start | Stop | Direction | Primary source |
| --- | --- | --- | --- | --- |
| `app.launch_to_home_usable_ms` | Launch request accepted by LaunchServices | Home Workspace is foreground, rendered, and accepts input | lower | signpost + App Launch |
| `workspace.navigation_to_interactive_ms` | Navigation action accepted | Destination workspace is rendered and accepts its first input | lower | signpost + Time Profiler |
| `interaction.input_response_ms` | Keyboard or pointer event delivered | Corresponding visible state is committed | lower | signpost + System Trace |
| `interaction.scroll_hitch_rate_pct` | Fixed scroll gesture begins | Gesture and deceleration end | lower | Animation Hitches; `100 * hitch duration / scenario duration` |
| `window.resize_hitch_rate_pct` | Fixed resize gesture begins | Final layout settles | lower | SwiftUI + Animation Hitches; same ratio |
| `live.runtime_ready_ms` | Runtime preparation begins | Capture State first reports runtime ready | lower | signpost + unified log |
| `live.capture_start_ms` | Confirmed start action | First captured system-audio sample | lower | signpost + unified log |
| `live.first_transcript_delta_ms` | First captured audio sample | First non-empty Live Transcript Delta is visible | lower | signpost + unified log |
| `live.chunk_latency_ms` | A live chunk closes | Its resulting transcript delta is visible | lower | per-chunk signposts |
| `live.queue_depth_count` | Sampled during capture | Instantaneous queued-work count; report max with raw series | lower | app/runtime metrics |
| `live.dropped_work_count` | Capture begins | Capture/finalization ends | lower | app/runtime metrics |
| `live.insight_refresh_ms` | Insight Refresh request | Updated valid Smart Minutes are visible | lower | signpost + RPC events |
| `import.first_progress_ms` | Media selection is confirmed | First non-zero progress is visible | lower | signpost + RPC events |
| `import.transcription_rtf` | Final transcription begins | Final transcript completes | lower | runtime monotonic timestamps |
| `import.diarization_rtf` | Diarization begins | Diarization completes | lower | runtime monotonic timestamps |
| `import.finalization_ms` | Final transcript/diarization inputs are available | Import Workspace reaches reviewable completed state | lower | signpost + RPC events |
| `records.save_ms` | `records.save` request is sent | Complete Record Folder is committed and acknowledged | lower | RPC timestamps + filesystem evidence |
| `export.markdown_ms` | Markdown export action accepted | Export Document is durably written | lower | signpost + filesystem evidence |
| `export.pdf_ms` | PDF export action accepted | Export Document is durably written | lower | signpost + filesystem evidence |
| `smart_minutes.provider_ready_ms` | Provider readiness request begins | Selected provider/model is usable or definitively fails | lower | RPC timestamps |
| `smart_minutes.first_useful_ms` | Generation request is sent | First visible schema-valid result has every required section non-empty and at least one evidence link that resolves on the frozen final Media Timeline | lower | signpost + RPC events |
| `smart_minutes.refresh_ms` | Insight Refresh request | Updated schema-valid Smart Minutes are visible | lower | signpost + RPC events |
| `smart_minutes.final_complete_ms` | Final generation request is sent | Complete schema-valid Insight Package is visible and saved | lower | signpost + RPC events |
| `records.index_refresh_ms` | Record Index refresh begins | Stable final result set is published | lower | signpost + filesystem trace |
| `records.search_result_ms` | Fixed query is submitted | Stable final result set is visible | lower | signpost + Time Profiler |
| `records.open_to_interactive_ms` | Record selection is accepted | Record Review is rendered and accepts input | lower | signpost + Time Profiler |
| `records.asset_load_ms` | Record open begins | Canonical meeting asset components publish their final health states | lower | signpost + unified log |
| `media.start_ms` | Play action is accepted | First audible/visible media sample is presented | lower | signpost + AVPlayer evidence |
| `media.seek_settle_ms` | Media Seek is accepted | Playback presents the target and resumes a stable timeline | lower | signpost + AVPlayer evidence |
| `media.playback_hitch_rate_pct` | Sustained playback window begins | Fixed playback window ends | lower | Animation Hitches; same ratio |

### Resource metrics

Resource rows use `component=app|sidecar|combined` and
`phase=idle|active|post_workload` rather than duplicating metric names.

| Metric | Definition | Direction |
| --- | --- | --- |
| `runtime.sidecar_start_ms` | Sidecar spawn request to ready handshake | lower |
| `runtime.sidecar_shutdown_ms` | Graceful shutdown request to process exit | lower |
| `resource.cpu_pct` | CPU utilization time series for the selected component and phase | lower |
| `resource.peak_rss_bytes` | Highest resident set size in the phase | lower |
| `resource.retained_rss_bytes` | Post-workload RSS minus pre-workload idle RSS after the fixed recovery window | lower |
| `resource.energy_impact` | Dimensionless Activity Monitor Energy Impact score sampled once per second; retain the raw series and report median and maximum | lower |
| `resource.max_thermal_state` | Highest observed nominal/fair/serious/critical state | lower |
| `resource.disk_read_bytes` | Bytes read in the phase | lower |
| `resource.disk_write_bytes` | Bytes written in the phase | lower |
| `resource.process_spawn_count` | Child-process spawns in the phase | lower |
| `resource.file_open_count` | File-open operations in the phase | lower |

## Measurement tools

Use tools already present on the reference Mac for the installed app:

- timing and launch: `os_signpost`, unified logging, Instruments App Launch;
- SwiftUI and interaction: SwiftUI, Animation Hitches, Time Profiler;
- blocking and concurrency: System Trace, Swift Concurrency, `sample`,
  `spindump`;
- memory: Allocations, Leaks, `vmmap`;
- files and processes: File Activity, Activity Monitor, `fs_usage`, `ps`;
- energy and thermal state: Activity Monitor and `powermetrics`;
- raw capture: `xcrun xctrace`.

Record any elevation needed by `powermetrics`; never silently omit the metric.
Use [`py-spy`](https://github.com/benfred/py-spy) as the canonical sidecar CPU
root-cause profiler. On macOS, record when attaching required elevation. Use
[`Memray`](https://github.com/bloomberg/memray) only after a memory anomaly is
observed; its instrumented run cannot supply baseline timing. Samply and
hyperfine are optional exploratory tools, not required protocol inputs.

When a canonical span lacks an existing signpost, a measurement ticket may add
the smallest signpost needed to expose its start and stop. That instrumentation
must be validated separately and must not include an optimization.

## Evidence format

Each measured scenario writes:

```text
logs/diagnostics/performance/<date>/<ticket>-<scenario>/
├── manifest.json
├── runs.jsonl
├── quality.json
├── summary.md
└── raw/
```

`manifest.json` records the cohort fields, fixture hashes, tool commands and
versions, run order, cold/warm reset evidence, and an inventory of every raw
artifact. `runs.jsonl` contains one append-only row per run and never rewrites a
failed result. `quality.json` records the quality checks below. `summary.md`
contains only derived statistics, ranked trace-backed hotspots, and explicit
limitations.

Commit small sanitized evidence. Large or sensitive traces remain on the
reference Mac; record their absolute path, byte size, and SHA-256 in the
manifest. Never commit raw meeting content, credentials, provider payloads, or
private transcript text.

## Quality and validity gates

- Record `asr.cer_pct` for Chinese, `asr.wer_pct` for English, and both for
  mixed-language fixtures against the frozen reference transcripts.
- Record transcript media coverage, segment count, dropped-work count, and
  task success.
- Validate Smart Minutes schema, required-section completeness, and every
  evidence link against the final Media Timeline.
- Validate Record Folder parseability, canonical component consistency, and
  reopen success.
- Validate media start, sustained playback, and Media Seek. Video scenarios
  retain the separate A/V-sync correctness gate.
- Preserve a run that fails quality validation, but exclude it from acceptable
  performance conclusions.
- A faster result with lower quality requires its own human decision. This
  protocol sets no quality or performance budget before baseline evidence.

## Completion rule for a baseline ticket

A baseline ticket is complete only when every required scenario has the stated
run counts, manifests and raw hashes are present, quality gates are recorded,
root-cause claims link to traces, and the ticket resolution links the sanitized
evidence directory. Suspected fixes remain hypotheses until a later ticket is
created from measured evidence.
