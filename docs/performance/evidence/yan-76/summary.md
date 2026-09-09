# Qwen model and chunk comparison — YAN-76

The 0.6B candidate reduced foreground ASR processing time on this machine.
Eight-second chunks retained more of the reference text than four-second hard
cuts. This supports further evaluation of 0.6B with context-preserving streaming;
it does not support changing the installed model or shortening its chunk
constant based on this sample.

Measured on 9 September 2026 using an M1 Pro with 16 GB RAM, AC power, low-power
mode off, MLX 0.31.2, and `mlx-qwen3-asr` 0.3.5. The runtime was the owner-accepted
PR #122 revision `6a85f89efc8357af09fd59aa0d2edcffff7e3a92`. The installed app,
ASR preferences, telemetry consent, and Records were preserved. All 92 requests
completed; the full models and media remain local.

## Results

Each cell containing two times reports **first pass / immediate second pass**.
Each model/cadence combination used a fresh process; its second pass reused the
same session and identical 58-second excerpt. The initial chunk is two seconds
of silence in every case. Model initialization is measured separately from the
request times below.

| Model | Subsequent chunk size | Total request service, s | Median text-bearing request, s | Maximum request, s | Chinese edits / 65 | English edits / 28 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Current 1.7B | 8 s | 25.336 / 11.485 | 1.808 / 1.018 | 8.236 / 3.317 | 0 | 0 |
| Candidate 0.6B | 8 s | 10.583 / 3.490 | 0.530 / 0.491 | 4.528 / 0.529 | 1 | 0 |
| Current 1.7B | 4 s | 15.468 / 7.162 | 0.625 / 0.626 | 5.547 / 0.807 | 2 | 7 |
| Candidate 0.6B | 4 s | 6.515 / 3.623 | 0.293 / 0.292 | 1.670 / 0.341 | 2 | 2 |

The two passes produced identical text within each model/cadence combination.
They therefore provide one quality example per combination. The medians describe
requests within a pass, not independent benchmark repetitions or a population
latency distribution. Full values, transcripts, and raw-report hashes are in
[results.json](./results.json); all request spans are in
[chunk-metrics.json](./chunk-metrics.json).
There are seven text-bearing requests per eight-second pass and twelve per
four-second pass. Totals and maxima include every request, including silence.

At eight seconds, the second-pass median fell from 1.018 s to 0.491 s and total
service from 11.485 s to 3.490 s. Shortening 0.6B chunks to four seconds reduced
per-request time but raised second-pass total service to 3.623 s, about 3.8%,
because more requests were needed.

## What contributes to delay

Eight-second model/session initialization took 1.964 s for 1.7B and 0.283 s for
0.6B. Lazy VAD, aligner, and MLX preparation still occurs inside initial requests.
The first speech request spent 6.165 s and 3.214 s respectively inside forced
alignment, including model preparation and alignment inference. This is a new
process in an existing boot with uncontrolled file caches, not a reboot-cold
measurement.

Across the second eight-second pass, feature preparation, generation, and text
parsing consumed 6.927 s for 1.7B and 1.945 s for 0.6B. Inclusive alignment took
another 3.932 s and 1.125 s. These are non-overlapping library phases; alignment
preparation/inference subspans are nested and must not be added again. The
remaining request time includes VAD, conversion, and other runtime work.

A serial replay projection puts the second-pass first text at 10.968 s for
1.7B/8 s, 10.486 s for 0.6B/8 s, 6.746 s for 1.7B/4 s, and 6.330 s for 0.6B/4 s,
measured from audio time zero. The initial silence is included and the model is
assumed ready at time zero. First-pass projections are 18.236 s, 14.528 s,
11.547 s, and 7.488 s respectively. These estimates omit capture, IPC, UI work,
speaker enrichment, and the product's queue/drop policy. They are not observed
subtitle publication times. The limited reduction from changing only the model
motivated the four-second experiment.

## Quality findings

At eight seconds, 0.6B substituted `再` for `在` in `不在运行中`. Both models
matched all 28 normalized English reference words.

Four-second cuts added two Chinese characters in both models: a duplicated `是`
at a sentence boundary and a standalone `你` (1.7B) or `意` (0.6B) after a small
speech tail. The 1.7B output lost part of “and durations before the next run”
and produced `language`; it also changed `result` to `language`. The 0.6B output
changed `result` to `Mark resolved`. English word error rates became 7/28 (25%)
and 2/28 (7.14%). Those erroneous generations ended with EOS and were not marked
truncated, so a generation-token cap does not explain the observed errors.

Scores use NFKC-normalized Han characters for CER and lowercase English
words/numbers for WER. They omit punctuation, speaker identity, timestamps, and
cross-language ordering. Scoring uses raw service emissions before Swift-side
deduplication or later full-recording refinement.

## Coverage and next action

This is one synthetic bilingual excerpt with two alternating voices, seven
complete reference utterances, 65 Han characters, and 28 English words. The
reference schedules intersect, but acoustic overlap was not established: the
generator does not stretch short utterances to fill their reference windows.
The original local receipt's overlap claim is explicitly superseded in
[manifest.json](./manifest.json). Natural meetings, quiet speech, overlap
recognition, speaker assignment, and long-session behavior remain unmeasured.

Process RSS samples are retained locally but omit a full accounting of
Metal/MLX allocations. They do not establish whole-app peak memory or memory
savings. The earlier 26-second installed-app smoke was a different cohort and
cannot serve as this experiment's baseline.

The next ASR experiment should preserve acoustic/context continuity while
testing shorter publication intervals. Keep 0.6B as a candidate, and check
recognition quality on more representative speech before changing defaults.
LS-EEND, local Qwen3.5-2B summaries, and other streaming models from the later
plan steps have not been benchmarked in YAN-76.

See the [protocol and reproduction notes](../../qwen-live-screening.md) and
[manifest](./manifest.json) for model/file pins, environment, preservation
receipts, timing boundaries, and the local raw-artifact inventory.
