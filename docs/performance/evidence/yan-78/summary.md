# Local streaming ASR results — YAN-78

The three requested ASR candidates were run on the owner's **M1 Pro (10 CPU
cores), 16 GiB, macOS 27.0 (26A5425a)**. VibeVoice preserved the words best in this
small sample, but assigned every utterance to Speaker 0. Nemotron emitted text
quickly while omitting English prefixes. The tested Voxtral implementation has
rendering defects, missing passages and inconsistent results across its two
streams. These findings do not support an immediate production model switch.

The [protocol](../../streaming-asr-screening.md), [results](results.json),
[events](text-and-step-events.jsonl), [resource samples](resources.json) and
[manifest](manifest.json) preserve the measured scope. Model, runtime, input and
raw-file hashes are recorded. Model downloads and full local logs remain in
`logs/yan78/` in the experiment worktree.

## Shared 58-second input

Each model ran two streams in one fresh offline process: one after loading, then
one with the same model and fresh streaming state. Input was delivered according
to a real source clock. The sample has **65 Chinese reference characters and 28
English reference words**, two configured synthetic voices, and two seconds of
leading silence. Repeated streams are not independent recognition examples.

| Candidate | First text, first / reused stream | Chinese CER, first / reused | Literal English WER | Main observation |
| --- | ---: | ---: | ---: | --- |
| Nemotron 3.5 0.6B, official Q8 Metal | 2.620 / 2.603 s | 3/65 / 3/65 | 13/28 both | Twelve English words deleted in native output |
| VibeVoice Streaming 1.5B, LM 4bit + audio BF16 | 5.548 / 4.806 s | 0/65 / 0/65 | 13/28 both | Twelve `[Silence]` annotations plus one word substitution |
| Voxtral Mini 4B Realtime, community 4bit + voxmlx | 2.990 / 6.604 s | 24/65 / 35/65 | 28/28 both | UTF-8 damage, lost spaces, missing passages, unequal outputs |

First-text times exclude model setup and include the leading silence. They are
component publication times, not capture-to-UI measurements. Setup took 13.368 s
for Nemotron, 4.295 s for VibeVoice and 6.988 s for Voxtral; file caches and lazy
compilation were uncontrolled. Nemotron and VibeVoice ran while other public
model files were downloading. This I/O confound prevents a strict performance
ranking from small timing differences.

VibeVoice's first event already contains real Chinese words, alongside its
annotation. Removing only the exact observed string `[Silence]` gives a separate
**sensitivity WER of 1/28 (3.57%)**, `input → output`, in both streams. This does
not replace the literal result. There is no claim that the model card mandates
this annotation. All seven original speaker labels are 0 in both streams;
parser replay confirms that a second label was not lost in processing.
[Independent VibeVoice audit](vibevoice-audit.md).

Nemotron's missing prefixes are `The same input will be replayed` and
`I will check the hashes and`; `durations` is reduced to `s`. These omissions
already occur in native partial/final output. All 928,000 input frames were
pushed exactly once per stream, and finalization succeeded. Chinese errors are
`在 → 再` and deletion of `所有`. Its native word offsets include a final end time
320 ms past the audio boundary, so those offsets were not used to explain
latency. [Independent Nemotron audit](nemotron-audit.md).

Voxtral's original rendering cannot be treated as a pure recognition WER.
Re-decoding the saved token sequence as a whole repairs three Chinese characters
and gives diagnostic CER **21/65 and 32/65**. English spaces remain absent. The
native tokenizer also emits `[STREAMING_WORD]`, but the published protocol permits
multiple words in one emission group; inserting a space only at those markers
still leaves joined words and gives diagnostic WER **21/28 and 22/28**. None of
these reconstructions invents missing words or changes the retained native
results. Two complete reference utterances remain missing, `hashes` becomes
`faults`, and the second stream ends with unsupported English content.
[Independent Voxtral audit](voxtral-audit.md),
[official emission-group protocol](https://arxiv.org/html/2602.11298v1#S3.SS1).

## Five-minute VibeVoice extension

VibeVoice completed **103 native windows, 833 generated tokens and all 300
seconds**, without a truncation flag. Final text returned at 300.600 s. Chinese
CER was 0/325. Literal English WER was 74/140: 69 annotations plus five copies of
the same `input → output` substitution. Removing only the annotations gives
5/140. Ordered mixed-language and utterance checks found no lexical deletions.
All 35 native speaker labels remained 0.

This fixture repeats the same seven utterances at 60-second offsets: 325 = 65 × 5
and 140 = 28 × 5. It tests sustained execution over repeated context, not five
times the independent language or speaker coverage. The largest source delay
was **1.826 s**, following a measured 4.654 s native step near 94–99 seconds.
The next release delay fell to 87.762 ms. The logs establish that timeline, but
not the underlying cause. No acoustic word or speaker timestamps are available.

Nemotron and Voxtral did not receive five-minute extensions: their short results
already expose problems that a longer run would not isolate. The extension
choices and the order change due to download readiness were recorded separately
in the raw inventory. There were no model retries or post-result prompt changes.

## Resources, conversion and scope

| Process cohort | Peak sampled worker RSS | Adapter return after audio end |
| --- | ---: | ---: |
| Nemotron, two short streams | 1,007.55 MiB | 0.081 / 0.081 s |
| VibeVoice, two short streams | 737.11 MiB | 0.466 / 0.497 s |
| VibeVoice, one long stream | 1,374.56 MiB | 0.600 s |
| Voxtral, two short streams | 979.47 MiB | 1.792 / 8.548 s |

RSS is sampled about once per second and **does not account for complete GPU,
unified-memory or whole-application use**. These values do not establish a
memory-efficiency ranking. Per-pass peaks were not inferred from an unrelated
clock. Whole-machine swap usage was already around 20 GiB or more before every
model cohort. During Voxtral it rose from
21,436.81 to 25,302.75 MiB (3,865.94 MiB more). This is a material load confound,
not memory attributable solely to the ASR worker. All model/controller windows
started on AC power with nominal thermal state; recorded thermal samples remained
nominal. The installed app revision
`6a85f89`, build `20260909123140`, executable, runtime configuration and telemetry
consent hashes matched before and after every window. No app/provider setting or
private meeting input was used for the experiment.

VibeVoice required a local conversion. All 13 official source files passed their
pinned hashes. The duplicate output head was removed only after elementwise
equality to the tied embedding was verified; strict weight loading remained
active. Actual converted tensor storage is **2,255,212,288 bytes**, comprising
1,386,664,704 bytes of non-language-model BF16 weights and 868,547,584 bytes of
language-model storage. The 7.212-second conversion reported a separate MLX peak
of 2,886,665,240 bytes; that conversion counter is not an ASR inference peak.
[Conversion evidence](conversion.json), [dependency versions](dependencies.json),
[download hashes](model-downloads.json).

The synthetic voice configuration is Tingting/Samantha, backed by the frozen
fixture's generation and hash chain. There was no independent auditory speaker
verification. Scheduled overlap is not verified acoustic overlap; quiet speech,
natural multiparty meetings, diarization error rate, capture/IPC/UI delay, the
product queue/drop policy and long-meeting stability remain unmeasured. This
screening cannot support a claim about any original model's maximum accuracy.

## Original plan and decisions

| Plan item | Evidence and present decision |
| --- | --- |
| Publish text before speaker/summary updates | [PR #122](https://github.com/YannJY02/AutoTranscribe/pull/122) received owner product acceptance; its separate review follow-ups remain in YAN-75. |
| Qwen 0.6B versus 1.7B | [PR #124](https://github.com/YannJY02/AutoTranscribe/pull/124) completed the same 58-second content comparison. At 8-second cadence, reused-stream median service time was 0.491 versus 1.018 s, with CER 1/65 versus 0/65 and WER 0/28 for both. Hard 4-second cuts worsened recognition and were rejected. |
| Continuous LS-EEND plus local generative summary | [YAN-77 / PR #127](https://github.com/YannJY02/AutoTranscribe/pull/127) tested 2B and the preplanned 4B fallback. 2B produced 7/8 complete packages, six materially inaccurate; 4B produced three complete packages and two truncations in five planned cases. Sound-check improved, but complete Chinese/English outputs still added unsupported owner/priority details. Neither tested configuration met the gate for a joint ASR/LS-EEND/summary load experiment. That joint measurement was not run. |
| VibeVoice short conversation; Nemotron/Voxtral native alternatives | All three ran locally; VibeVoice also completed the one five-minute extension. Keep the individual negative findings and the useful VibeVoice lexical result; none is an immediate replacement for the accepted product configuration. |

The previous Qwen timing used measured service durations with a **projected**
serial feed schedule, unlike this experiment's clocked source. Its quality
reference is shared, but its projected first-text times are not mixed into the
native timing table. These experiments are candidate screens, with no production
default change, merge or release.
