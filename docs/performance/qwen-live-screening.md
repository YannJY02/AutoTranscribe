# Qwen live ASR component screening

This experiment implements [YAN-76](https://linear.app/yannjy/issue/YAN-76),
the second step authorized after owner acceptance of
[PR #122](https://github.com/YannJY02/AutoTranscribe/pull/122).
It compares a downloaded Qwen3-ASR-0.6B candidate with the currently installed
Qwen3-ASR-1.7B model, using the accepted runtime's foreground transcription path.
The [measured results](./evidence/yan-76/summary.md) include the initial model
comparison and a subsequent four-second chunk experiment.

## Scope

The input is the first 58 seconds of the frozen `short-mixed` fixture: two
alternating synthetic voices in Chinese and English. Reference time windows
intersect, but actual acoustic overlap was not established. The excerpt
retains the initial two seconds of silence. Requests use a two-second initial
chunk followed by seven eight-second chunks. Each model runs in its own process,
with the same excerpt repeated once using the same model session.

The candidate is
[`aufklarer/Qwen3-ASR-0.6B-MLX-4bit`](https://huggingface.co/aufklarer/Qwen3-ASR-0.6B-MLX-4bit)
at revision `bc441bd1e4295c1f42d9879f056049a925b6e013`.
The existing 1.7B weights and forced aligner are reused from the local cache.
Both models use the installed `mlx-qwen3-asr` 0.3.5 runtime and MLX 0.31.2.
Model files and their declared quantization configurations are recorded
separately: this compares these two deployable candidates, rather than isolating
parameter count as the sole independent variable.

The production app, analysis preferences, telemetry consent, and Records are not
changed. All inference uses local files after the explicit model download.

## Measurement boundaries

- Report initialization, the first speech request, and reused-session requests
  separately. A new process in the same boot is not the canonical protocol's
  reboot-based cold run.
- Preserve VAD and word timestamps. Foreground text bypasses speaker enrichment,
  as in the accepted progressive pipeline; forced alignment remains part of
  the foreground request.
- Preserve inclusive timing relationships. Alignment is nested inside the
  library transcription call, so those durations must not be added together.
- Chinese CER and English WER compare normalized recognized text with the
  frozen reference. Retain substitutions, omissions, insertions, and failed
  requests; these scores do not establish speaker or overlap accuracy.
- Any queue or publication delay derived from request durations is a serial
  replay estimate. It does not measure capture, RPC, UI publication, or the
  product's bounded queue and drop policy.

This is a bounded model-screening experiment. It does not complete the
[installed-app benchmark protocol](./installed-app-benchmark-protocol.md),
establish real-meeting accuracy, or measure sustained long-session behavior.
No installation or model-default decision follows from speed alone.

## Reproduce a model run

First verify the frozen corpus as described in [fixture corpus](./fixture-corpus.md),
then convert its first 58 seconds to mono 16-kHz PCM16 WAV and retain all complete
reference segments ending at or before 58 seconds. Verify the model file pins
and confirm the installed app has no active recording, transcription job, or
watcher. Keep each model's output name unique; the script refuses to overwrite
an earlier report or its logs.

Run each model sequentially under the shared resource lock, using the installed
ASR interpreter and a clean checkout of the accepted runtime. The actual
controller inherited only `PATH`, `HOME`, `TMPDIR`, `LANG`, `LC_ALL`, and
`LC_CTYPE` from its parent. Reproduce that environment boundary so old model,
language, token-limit, or alignment overrides cannot leak into the run:

```bash
python3.11 scripts/agent_harness.py lock --resource installed-app --timeout 60 -- \
  /usr/bin/env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
  LANG="${LANG:-en_US.UTF-8}" LC_ALL="${LC_ALL:-}" LC_CTYPE="${LC_CTYPE:-}" \
  /Users/yann.jy/miniconda3/envs/transcribe/bin/python \
  scripts/compare_qwen_live_asr.py \
  --runtime-root /absolute/path/to/accepted-runtime-checkout \
  --model /absolute/path/to/downloaded-model \
  --runtime-config /absolute/path/to/asr-only-config-snapshot.json \
  --input /absolute/path/to/short-mixed-58s.wav \
  --reference /absolute/path/to/reference-58s.json \
  --output /absolute/path/to/new-model-result.json
```

This is the inner model-run command; the actual local controller also sampled
power, thermal state, process usage, and preservation receipts. Its source hash
and output receipts are retained in the evidence manifest.

The worker resolves local model paths before importing the runtime and performs
no network model acquisition. The report is updated after every request;
initialization errors, failed chunks and subprocess timeouts retain partial
evidence and return a failing exit code. Adjacent stdout/stderr logs are retained.
Timing callbacks and wrappers are confined to that process and leave the
installed library files unchanged.

## Four-second variant

After the eight-second comparison, the same measurement script was used with a
two-second initial chunk followed by fourteen four-second chunks. The exact
[worker wrapper](./evidence/yan-76/run-four-second-worker.py.txt) changes only
`BOUNDARIES_MS`, then invokes the existing worker entry point. Its recorded
location was `logs/yan76/run_four_second_worker.py`; copy it there before use
because it resolves the repository root relative to that path. Supply the same
runtime, model, configuration, input, reference, and unique output arguments.

This wrapper enters worker mode directly and does not enforce a timeout itself.
The experiment's local `logs/yan76/run_models.py --four-second` controller ran
each model sequentially under the shared installed-app lock, checked for active
work, and enforced a 1,200-second deadline per model process with process-group
cleanup.
A reproduction must supply the same lock, idle checks, and an external deadline.
The controller and wrapper hashes are in the evidence manifest. Each cadence
starts fresh processes; the four-second cohort does not reuse the eight-second
model sessions. No production chunk size was edited.

## Local evidence

The experiment's raw artifacts live under `logs/yan76/` in its worktree.
`input-receipt.json` pins the source media and reference hashes, converted PCM
audio, seven reference segments, and successful frozen-corpus verification.
Its initial overlap description is superseded by `coverage-correction.json`;
the original receipt is retained unchanged.
`models/` contains model file inventories and download/configuration receipts.
`preflight.json` records the accepted app build, unchanged configuration and
consent fingerprints, idle preflight, power and thermal state. The separate
`pre-run-cpu.json` retains a 60-second sample of the normal background workload.

Reviewed results are under `docs/performance/evidence/yan-76/`;
model weights and raw media remain local and outside Git.
