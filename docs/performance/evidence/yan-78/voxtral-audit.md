# Voxtral 58-second evidence and token audit

The two saved passes completed and their journal, report, input, and native flush records agree. Token-only reconstruction repairs a visible UTF-8 defect and exposes part of the English spacing problem; substantial omissions and substitutions remain. This audit ran no ASR inference and changed no raw evidence.

The baseline is `awni/voxmlx` at `e6d193e85e84e30f26e370c66973ce287b8a9d57`, with `T0mSIlver/Voxtral-Mini-4B-Realtime-2602-MLX-4bit` at `e41b00294733d2db2fe767cd7c5454ba617c2bed` (4 bit, group size 64). Native input blocks are 80 ms and the delay setting is 480 ms; the generic report argument `chunk_ms: 320` does not set the native block size. Model setup was 6.988 s.

| Existing measurement | Pass 1 | Pass 2 |
| --- | ---: | ---: |
| First nonempty native text, from stream start | 2.990 s | 6.604 s |
| Final native text available, from stream start | 59.792 s | 66.548 s |
| Native EOF requested | 58.408 s | 62.128 s |
| Native flush duration | 1.378 s | 4.389 s |
| Largest source release lateness | 1.162 s | 0.099 s |

These timing numbers remain the original native-output measurements. The fixture begins with two seconds before the first speech segment; these are not word-end latency measurements. Empty `[STREAMING_PAD]` output is excluded from first text.

| Text rendering and score | Pass 1 | Pass 2 |
| --- | ---: | ---: |
| Literal native text: CER | 24/65 = 36.92% | 35/65 = 53.85% |
| Literal native text: WER | 28/28 = 100.00% | 28/28 = 100.00% |
| Whole saved-token IGNORE decode — diagnostic: CER | 21/65 = 32.31% | 32/65 = 49.23% |
| Whole saved-token IGNORE decode — diagnostic: WER | 28/28 = 100.00% | 28/28 = 100.00% |
| STREAMING_WORD group spacing — diagnostic: CER | 21/65 = 32.31% | 32/65 = 49.23% |
| STREAMING_WORD group spacing — diagnostic: WER | 21/28 = 75.00% | 22/28 = 78.57% |

CER extracts Han characters; WER uses the existing English word regex after NFKC and lowercasing. Both exclude punctuation, speakers, timestamps, and cross-language order. The repeated passes share one synthetic fixture and model weights; they are not independent quality samples.

The native loop calls `Tekkenizer.decode([token_id], IGNORE)` separately for every token. All 735 recorded token decodes per pass reproduce their exact saved deltas and final literal text. Three Chinese characters (`固`, `测`, `冻`) each span token byte fragments: individual decoding produces six replacement characters, while whole-token decoding restores those three Han characters. All other characters are retained.

Whole-token decoding does **not** restore English spaces: the retained content-token bytes contain no ASCII space. The [original paper, §3.1](https://arxiv.org/html/2602.11298v1#S3.SS1) defines [W] at emission-group onset and allows consecutive words to share a group. The [model maintainer response](https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602/discussions/39) likewise describes `[STREAMING_WORD]` in terms of emission groups. The installed tokenizer maps this marker to ID 33, ignores it under IGNORE, and does not insert spaces.

The third rendering splits saved IDs only at ID 33, decodes each segment with the same IGNORE decoder, removes only empty decoded segments, and joins the others with one space. It does not guess boundaries within a segment or correct words. Thus `inputwillbe`, `replayedfor`, `Iwill`, and `checkthe` remain joined. Its WER is a rendering diagnostic, and neither it nor the literal 100% WER is a pure measure of recognition errors.

Complete literal, whole-token, and boundary-group text plus token IDs are retained in the adjacent audit JSON. The two whole-token outputs are:

Pass 1 — full-token decode diagnostic:

> 我们先固定今天的测试文件和操作顺序。Thesameinputwillbereplayedforeverymeasuredrun.决定使用冻结方案,不再运行中修改内容。Iwillcheckthefaultsandwaitforthenextone.所有内容都是个什么不来自这个会议

Pass 2 — full-token decode diagnostic:

> 我们先固定今天的测试文件和操作顺序。Thesameinputwillbereplayedforeverymeasuredrun.决定使用冻结方案,不再运行中修改内容。Iwillcheckthefaultsandthewaytentsforthenextone.Soeveryoneshouldremember,butrightjustremember.

The boundary-only first English sentence is `The same inputwillbe replayedfor every measured run.` in both passes. Its ordered letters match the reference after removing whitespace, illustrating why literal WER should not be described as every word being wrong.

Recognition and coverage problems remain visible after either reconstruction:

- Both passes omit the Chinese overlap sentence `这段短暂交叉发言也保留在测试里。` and the English sentence `A failed validation produces no benchmark result.`
- Both substitute `不再` for `不在` and render the hashes/durations sentence with `faults` and other changes.
- Pass 1 ends with a substantially altered Chinese sentence. Pass 2 ends with an English sentence about remembering that has no corresponding reference content. No word-level timestamp attribution is inferred.

The journal has 4,392 complete JSON lines with consecutive sequence numbers. Each pass contains 725 releases and 725 callbacks, covering exactly 928,000 frames in contiguous 1,280-frame intervals. Both report 735 token emissions, with 73 and 76 nonempty text deltas. EOS count is zero. The first flush snapshot accounts for 920,320 fed frames plus 7,680 buffered frames; the second accounts for 898,560 plus 29,440. Both snapshots total the full input, have an initialized decoder, and are followed by native flush completion. Delivery and flush accounting do not prove every utterance was transcribed; the known EOS-reset loss path was not exercised.

The worker exited 0 after 135.923 s. Across 130 resource samples, maximum worker RSS was 1,002,976 KiB (979.469 MiB, 0.9565 GiB). This omits a complete accounting of unified/GPU memory. Whole-machine used swap rose from 21,436.81 MiB to 25,302.75 MiB, an observed increase of 3,865.94 MiB against an already large baseline; it cannot be assigned entirely to the worker. Thermal readings remained 0 in sampled checks. The repeated pass had slower first text and a longer flush; this audit does not establish the cause.

The controller records identical installed-app build, executable, runtime-config, and consent state before and after, with one app process and no writable records handle in all its sampled idle checks. The audit also confirmed unchanged hashes for all source evidence read. No app integration or five-minute stability conclusion follows from this finite-source test.

Evidence: raw report (`logs/yan78/voxtral/short.json`), event journal (`logs/yan78/voxtral/short.json.events.jsonl`), resource samples (`logs/yan78/voxtral/short.json.resources.json`), controller (`logs/yan78/voxtral-short.controller.json`).

Audit JSON: [published audit](voxtral-audit.json); raw source: `logs/yan78/voxtral/audit.json`. Tokenizer SHA-256: `8434af1d39eba99f0ef46cf1450bf1a63fa941a26933a1ef5dbbf4adf0d00e44`. Audio SHA-256: `8d61f394b9f63f5a5afc7f7190a02a4f614e6c0ae2c3a2c640188dce84619cfb`. Reference SHA-256: `fd1cf2eecbd755c08cb747ea6253d759e053cb4b3d09d4a19902f0b3c4155108`.
