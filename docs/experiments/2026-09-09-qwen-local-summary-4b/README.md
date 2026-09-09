# Qwen3.5-4B conditional local summary screen — YAN-77

The approved conditional comparison is complete. The measured Qwen3.5-4B
four-bit configuration improves several errors in the preserved
[2B screen](../2026-09-09-qwen-local-summary/README.md), but does **not** meet the
prerequisite for concurrent ASR/LS-EEND testing. Of five preregistered requests,
three produced schema-valid packages: the sound-check response was faithful,
while the Chinese and English meeting responses still contained material
fidelity errors. Two correction-story responses reached the 1,536-token cap and
could not produce complete packages. The remaining three controls were stopped
by the registered rule. There was no retry, tuning round, or 2B rerun.

This negative result completes this bounded summary experiment; it does not
establish that all Qwen configurations or local summarization approaches fail.
The streaming ASR results are being reviewed and delivered separately. The installed app,
production provider, model settings, consent, and Records were preserved.

## Evidence and comparison

- [Preregistered selection and stop rule](../../../evals/local_summary/v1/qwen-4b-screen.json)
  selects five original cases covering observed 2B failures. The contract was
  recorded in Linear and copied locally before generation; its hash and contents
  are retained in [run.json](run.json). The dataset, expected facts, product
  prompts, generation settings, and runtime versions match the 2B screen.
- [run.json](run.json) preserves every raw output, raw/postprocessed payload when
  available, strict validation, structural checks, timings, source/model hashes,
  preservation results, and the three `not_run_by_stop_rule` controls.
- [semantic-review.json](semantic-review.json) audits each frozen checkpoint and
  every visible generated object, with separate raw/postprocessed verdicts and
  payload hashes. Review was conducted by an independent agent who did not author
  the fixtures or run the model; it was not blind to the 2B result. It is neither
  owner acceptance nor an automatic quality metric.

| Same input | 2B complete package | 4B complete package | 4B output tokens* | 4B first text | 4B result |
| --- | ---: | ---: | ---: | ---: | --- |
| Chinese release decision, final | 13.84 s | 17.60 s | 768 | 3.60 s | Complete; fidelity fails |
| English offline pilot, final | 8.59 s | 18.66 s | 879 | 2.72 s | Complete; fidelity fails |
| Sound check only, final | 6.22 s | 4.45 s | 104 | 2.53 s | Complete; fidelity passes |
| Bilingual prefix through 110 s, live | Truncated at 15.48 s | Truncated at 31.30 s | 1,536 | 3.24 s | No complete package |
| Same complete bilingual story, final | 15.59 s | Truncated at 31.56 s | 1,536 | 3.42 s | No complete package |

\* MLX generation counts include the stop token when one is produced. Times for
truncated outputs are request duration, not time to a usable summary. The first
three 4B prompts contain 925, 927, and 838 tokens; the correction prompts contain
1,111 and 1,169. These match their respective 2B formatted prompt token counts.
For each selected input, the transcript and formatted prompt token-ID SHA256
also match the 2B run exactly. Stage A is deliberately enriched for 2B failures,
so aggregate pass percentages
across the eight-case 2B screen and five-case 4B screen are not comparable.

Observed improvements and remaining problems:

- **Chinese:** 4B preserves “周五前” and test-environment verification, replacing
  2B's invented absolute date. It still assigns the decision to 乙 despite no
  explicit decision owner, adds an unspecified `high` priority, and invents an
  “other colors” alternative. Its timeline now stays within the source duration.
- **English:** 4B retains Blair's checklist and the offline decision. It still
  assigns Blair as decision owner, adds `high` priority, and invents a rationale
  about online operation causing misleading results or risk. Raw timeline
  timestamps of 40 and 90 seconds exceed this 13.2-second source. Postprocessing
  clips both to 13 seconds, repairing the task's position but still placing the
  decision outside its 4–8.6-second source segment. It does not resolve the
  material content errors.
- **Sound check:** the response explicitly says there is no substantive meeting
  content and leaves all six array modules empty. This fixes the 2B fabricated
  decision and system-owned action in this input.
- **Corrections:** visible text correctly keeps Ren/Monday attached to the demo
  checklist while the risk list remains unknown. Both attempts nevertheless
  truncate and contain unsupported decision ownership and other content errors.
  The final-mode text also describes an unapproved cloud proposal as rejected.
  Partial object review documents these observations; it does not reconstruct or
  accept the incomplete JSON. No postprocessed payload exists for either case.

The material failures alone would stop advancement. The two truncations had
already failed the all-pass condition before semantic review, so the mixed design
review and the 28-second and 64-second prefixes were not generated. No joint-load
test is justified by this screen.

## Measurement boundary

One model load took 2.01 seconds after imports and file verification. Each request
used the same loaded weights and a fresh prompt cache; prior summaries were never
included as input. First text ranged from 2.53 to 3.60 seconds. The Chinese and
English complete outputs took longer than their 2B equivalents. The sound-check
output took less time because it emitted only 104 tokens versus 558 for 2B; this
is not evidence that 4B is generally faster. The final story regressed from a
complete but unfaithful 2B response to a truncated 4B response at the same cap.

MLX allocator peak memory ranged from 3.62 to 3.75 GB, compared with 2.10–2.26 GB
in the full 2B screen. These include model allocations and are not process RSS,
system memory, or headroom under ASR. The machine was the same MacBookPro18,1 with
16 GiB RAM and macOS 27.0 on AC power. Observed thermal states were nominal before,
during, and after generation. Ordinary background applications were present; the
shared installed-app lock excluded experiment ASR, diarization, capture, and UI
tests. This was not a randomized benchmark or a reboot-cold measurement.

First-text timers include template preparation through the first returned text.
Library prompt throughput includes prefill and the first decode step; it cannot
isolate pure prefill. Generation metrics include raw-text evidence writes.
Complete-package timing ends after strict JSON/schema validation and product
postprocessing, before structural assessment. These are component measurements,
not latency to a displayed or faithful Smart Minutes result.

Before/after bundle and executable hashes, runtime configuration and consent
hashes, and aggregate Records metadata matched. The installed revision remained
`6a85f89`, build `20260909123140`. Idle live-session and job checks passed. No
private recording content was read. Preservation is not a new acceptance test of
the installed build; local operational logs and process lists are not published.

## Reproduction and decision boundary

The source model is [Qwen3.5-4B](https://huggingface.co/Qwen/Qwen3.5-4B), observed
at revision `851bf6e806efd8d0a36b00ddf55e13ccb7b8cd0a`. The text-only MLX loader
used the [community four-bit conversion](https://huggingface.co/mlx-community/Qwen3.5-4B-4bit/tree/0e7ffd5c629ef7719d4cbc04069232580bfa9d9c),
pinned to `0e7ffd5c629ef7719d4cbc04069232580bfa9d9c`. The eleven local files total
3,061,130,647 bytes; every size and SHA256 is recorded in `run.json`. Weights are
not committed. Runtime versions and isolated-environment setup match the
[2B reproduction instructions](../2026-09-09-qwen-local-summary/README.md#reproduction).

Acquire that pinned conversion and save the `model` object from this report's
`run.json` as a manifest. After an authorized idle/preservation preflight, the
stage-A invocation is:

```sh
python3.11 scripts/agent_harness.py lock --resource installed-app --timeout 60 -- \
  .venv/bin/python scripts/compare_local_summary.py run \
  --model-path logs/yan77/models/qwen3.5-4b-4bit \
  --model-manifest logs/yan77/4b-preparation/model-manifest.json \
  --model-repo mlx-community/Qwen3.5-4B-4bit \
  --python logs/yan77/venv/bin/python \
  --output logs/yan77/four-b/round1 \
  --max-tokens 1536 --request-timeout 120 --load-timeout 120 \
  --case zh-release-decision-final \
  --case en-launch-plan-final \
  --case insufficient-transcript-final \
  --case bilingual-plan-correction-prefix-03 \
  --case bilingual-plan-correction-final
```

The output directory must not exist. This is reproduction documentation, not an
instruction to rerun the completed experiment. The runner checks model files,
supports explicit ordered case selection, and retains all attempts. The operator
enforces the preregistered five-to-three stage gate and total generation budget;
the runner does not automate that decision. On this measured result, the correct
next action is to retain the current product configuration and continue the
separate ASR work, not to run stage B or a combined resource experiment.
