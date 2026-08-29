# Issue #4 — Launch and Interaction Baseline

Status: **incomplete; do not close Issue #4**

This evidence set contains a complete exploratory warm run and trace-backed
hotspot ranking. It is not yet a canonical baseline because the cohort did not
retain its power-source and priming-run evidence, no cold runs have been
recorded, and Xcode 27 did not save usable Animation Hitches or App Launch
template traces.

## Warm results

Every value is in milliseconds. Each row has 10 samples; all 20 end-to-end runs
passed, with no discarded samples. Individual values are retained in
[`runs.jsonl`](./runs.jsonl).

| Records | Metric / phase | Median | Min | Max | MAD | Success |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 100 | Launch → usable Home | 1,537.86 | 1,228.62 | 1,784.05 | 53.36 | 10/10 |
| 100 | Input → stable search results | 79.70 | 74.00 | 88.69 | 3.29 | 10/10 |
| 100 | Navigate → Live interactive | 311.06 | 258.02 | 519.10 | 15.82 | 10/10 |
| 100 | Navigate → Import interactive | 91.56 | 81.94 | 126.36 | 3.74 | 10/10 |
| 100 | Navigate → Records interactive | 190.23 | 181.34 | 219.46 | 5.69 | 10/10 |
| 100 | Navigate → Settings interactive | 370.91 | 323.60 | 416.30 | 21.46 | 10/10 |
| 1,000 | Launch → usable Home | 1,407.13 | 1,106.85 | 1,647.64 | 95.81 | 10/10 |
| 1,000 | Input → stable search results | 4,746.95 | 4,736.64 | 4,798.20 | 6.14 | 10/10 |
| 1,000 | Navigate → Live interactive | 312.23 | 227.44 | 420.63 | 20.01 | 10/10 |
| 1,000 | Navigate → Import interactive | 87.72 | 81.79 | 100.29 | 4.80 | 10/10 |
| 1,000 | Navigate → Records interactive | 76.55 | 72.10 | 84.49 | 2.07 | 10/10 |
| 1,000 | Navigate → Settings interactive | 589.64 | 563.11 | 649.68 | 9.61 | 10/10 |

The measured 1,000-record search response is 59.6× the 100-record median in
this exploratory cohort. This is an observed scale difference, not yet a
regression decision.

## Ranked trace-backed hotspots

1. **Synchronous 1,000-record search on the main thread.**
   `RecordsIndexService.searchRecords` and `recordContentMatches` account for
   11,706 ms, or 68.544% of sampled running CPU time. The trace points to
   `RecordsIndexService.swift:193-194` and `:383`.
2. **Render and commit amplification around the same interaction.** Core
   Animation commit stacks account for 5,334 ms (31.233%); AppKit/hosting-view
   layout accounts for 4,926 ms (28.844%). These categories overlap with the
   search path and therefore must not be summed.
3. **Background index construction and content decoding.** Index loading
   accounts for 1,074 ms (6.289%), only 4 ms of which was sampled on the main
   thread. Content file decoding accounts for 250 ms (1.464%). The trace points
   to `RecordsIndexService.swift:128`, `:324`, and `:392`.
4. **Repeated row formatting.** `RecordListItemView.formatDate` accounts for
   568 ms (3.326%) during list rendering.
5. **Settings storage scan.** `RecordsIndexService.storageUsedLabel` accounts
   for 263 ms (1.540%) on the main thread.

The launch Time Profiler trace also places 233 ms of sampled running CPU time
under `applicationDidFinishLaunching` / `showMainWindow`; the native App Launch
template failed, so this is diagnostic context rather than a replacement for
the missing launch instrument.

## Evidence and limitations

- The installed app is pinned to revision `19d19e4`, bundle version
  `20260829173735`, and a deterministic bundle inventory.
- The synthetic corpus verified: six media assets and 1,100 Record Folders.
- Raw evidence is retained locally at
  `/Users/yann.jy/Library/Application Support/InsightKit/PerformanceEvidence/2026-08-29/issue-4-interactions/raw`.
- [`manifest.json`](./manifest.json) records every local raw file or trace
  bundle by size and SHA-256; [`quality.json`](./quality.json) records passed,
  failed, blocked, and unexecuted gates.
- Trace percentages are shares of sampled running CPU time, not wall time.
- No performance budget has been chosen, so these values are measurements, not
  product pass/fail thresholds.
- These runs used the original driver readiness boundaries. The branch now
  starts launch timing at the LaunchServices request and waits for
  destination-specific ready controls; the replacement cohort must use that
  corrected driver.
- No optimization was implemented in this ticket.

## Remaining completion gates

1. Connect AC power and retain a fresh unmeasured priming log.
2. Record three valid post-restart cold cohorts, with the protocol’s five-minute
   wait and start-gate evidence.
3. Recover scroll and resize hitch metrics with a working Xcode 27 Instruments
   path or a documented equivalent measurement source.
4. Re-run the warm cohort under the fully recorded start gate, then replace the
   exploratory statistics rather than combining cohorts.
