# YAN-78 VibeVoice read-only result audit

Two 58-second passes and one 300-second pass completed. The original reports, journals, driver, tests, preparation artifacts, and audio/reference inputs were left unchanged; their hashes are recorded in `audit.json`. This audit loaded no model and ran no inference.

## Short result: two 58-second passes

| Pass | Original Chinese CER | Original English WER | Exact `[Silence]` occurrences | Secondary WER after removing only that string | Original first text | Speaker labels |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 0/65 (0%) | 13/28 (46.43%) | 12 | 1/28 (3.57%) | 5547.840 ms | 7 labels, all 0 |
| 2 | 0/65 (0%) | 13/28 (46.43%) | 12 | 1/28 (3.57%) | 4805.698 ms | 7 labels, all 0 |

Each literal English alignment has 12 `silence` insertions plus one lexical substitution, **input → output**. The secondary calculation deletes only the exact case-sensitive string `[Silence]` before calling the unchanged scorer: Chinese remains 0/65, and English becomes 1/28. No lexical correction or reference substitution is applied. Raw text, parsed text, raw chunk boundaries, speaker labels, and token counts are identical across the two passes (20 chunks, 162 generated tokens each).

Replaying the current, hash-matched `SpeakerParser` reconstructs the saved text and every speaker event exactly. Concatenated raw chunks equal raw text; journal chunk text, cumulative publications, and speaker events match the saved report. The raw labels themselves are all `Speaker 0`; a second ID was not lost in parsing.

Both first published text events already contain `我们先固定今` alongside the leading annotation. Removing the annotation therefore does not move the first lexical publication to a later event. The original first-text metrics above remain authoritative for this run; journal samples are 5547.852 ms and 4805.701 ms because they use adjacent clock reads. Individual token/acoustic word timestamps are unavailable.

An ordered mixed-language token alignment, plus the seven label-delimited text segments in reference order, finds no lexical deletions. This checks repeated occurrences and language order rather than mere word presence. It is a transcript audit, not an acoustic alignment.

## Long result: one 300-second pass

| Measure | Original result or separate audit |
| --- | --- |
| Original Chinese CER | 0/325 (0%) |
| Original English WER | 74/140 (52.86%); 69 annotation insertions + 5 input → output substitutions |
| Secondary WER, removing only `[Silence]` | 5/140 (3.57%); Chinese remains 0/325 |
| Original first text | 4587.298 ms |
| Original final text / stream wall time | 300599.783 / 300599.792 ms |
| Native work | 103/103 chunks; 833 generated tokens; completed, no truncation reported |
| Speaker labels | 35, all raw and parsed ID 0 |
| Lexical omission audit | 0 ordered mixed-language deletions; all 35 label-delimited segments occur in reference order |

The reference is the same seven sentences repeated five times at 60-second offsets: **325 Chinese units = 65 × 5; 140 English words = 28 × 5**. This adds evidence about sustained execution and retention across repeated context, not five times as much independent lexical material. Short and long denominators are never pooled. The first long-run publication already contains Chinese text; its journal sample is 4587.303 ms and does not replace the original metric.

### Maximum source-release lateness

The saved maximum lateness is **1826.351 ms**, at release event 145. The following timeline is observed wall time from the stream start:

| Event | Time / observation |
| --- | --- |
| Previous release 141 | 94409.548 ms; due 94404.125 ms |
| Step 31 start, event 142 | 94409.648 ms |
| Next release due | 97337.500 ms; occurs while step 31 is executing |
| Step 31 end, event 144 | 99063.544 ms; 4653.895 ms elapsed |
| Recorded step 31 phases | encoding 1902.860 ms + decoding 2751.029 ms; 4 tokens |
| Late release 145 | 99163.866 ms, about 100.322 ms after step 31 ends |
| Step 32 | 99163.998–100351.341 ms |
| Next release 150 | lateness 87.762 ms |

At the end of step 31, the next source deadline had already passed by 1726.044 ms. The event gap adds about 100.322 ms; tiny differences from the saved lateness reflect adjacent clock reads. Encoding includes window preparation/resampling and `encode_speech`; decoding includes native generation, parsing, and publication. These spans locate the overrun but do not establish why the work slowed. No memory, storage IO, CPU/GPU, or thermal cause is inferred. Source lateness measures release delay for a finite paced WAV; it is not an observed production capture-queue overflow.

## Fixture and speaker provenance

The frozen manifest pins generator revision `6dff2524c06433de01e78821e641596481145a46`, the generator SHA-256, and the specification SHA-256. Both Git blobs match those hashes. The pinned `short-mixed` recipe assigns four Chinese turns to Apple **Tingting** (role 林) and three English turns to **Samantha** (role Alex) per cycle. The generator calls `say -v` with each selected voice and fails on command failure; it mixes those separate files. It removes the voice field when writing reference segments, so the reference role names alone would be weaker evidence.

The current canonical audio hash matches the frozen manifest and the experiment input receipt; the canonical reference hash also matches. All four experiment input hashes match both receipt and reports, and the 58-second PCM equals the first 58 seconds of the long WAV. This chain supports two configured synthetic voices in the tested frozen fixture. All-zero output does not demonstrate their separation. No separate auditory/acoustic identity check was performed, and scheduled overlap is not verified acoustic overlap. Event arrival labels have no acoustic timestamps, so no DER or natural-meeting diarization claim is made.

## Interpretation of `[Silence]`

The exact spelling appears in the observed generated output. It was not found in the pinned official source tree’s Python/Markdown/JSON files, or in the pinned model card and inspected tokenizer metadata; it is absent from added tokens. This is a bounded source inspection, not proof of an undocumented global convention. The official display adapter handles generic repeated bracket tags by collapsing consecutive duplicates in merged cards; it does not remove all tags. The [pinned display code](https://github.com/microsoft/VibeVoice/blob/1541f590c7099820f10ea012f48d2399282df69f/vllm_plugin/asr_streaming.py#L199-L245) and [paper Appendix A](https://arxiv.org/html/2609.02812v1#A1) describe empty no-speech chunks. The [pinned model card](https://huggingface.co/microsoft/VibeVoice-ASR-Streaming-1.5B/blob/4262d23d8a539a6530cf64fbd0b1751ef9a30853/README.md) does not supply an evaluation rule for this spelling.

Treat the removal result as a **secondary annotation sensitivity analysis**. Preserve literal benchmark scores, raw output, speaker evidence, and original timing; the sensitivity result does not replace any of them.

Full event objects, edit operations, text-offset checks, source pins, and SHA-256 receipts are in [the audit JSON](vibevoice-audit.json).
