# Qwen3.5-2B local summary screen — YAN-77

The selected local Qwen3.5-2B four-bit model can generate the current seven-module
Smart Minutes JSON, but this screen does **not** support advancing this
configuration into concurrent ASR/LS-EEND testing. Seven of eight responses passed
strict schema validation. Six of those seven complete responses contained
substantive fidelity errors. The earliest live prefix correctly preserved the
unapproved proposal and unknown assignments, with only a minor unsupported
alternative and a ledger-contract difference. The eighth response reached the
1,536-token limit and was not a complete JSON package. Product postprocessing did
not resolve the substantive content errors.

This is a decision about the measured model, prompt, runtime, and token budget on
eight short synthetic inputs. It is not a claim about every Qwen model or every
local summarization design. No product provider, default model, installed app,
analysis configuration, or consent was changed.

## Evidence and outcome

- [Frozen inputs and expectations](../../../evals/local_summary/v1/README.md)
  describe four existing synthetic cases plus three complete cumulative prefixes
  and one final rendering of a new 110-second bilingual story.
- [run.json](run.json) retains every raw response, parsed raw and product
  postprocessed payload, validation error, structural assessment, timing, model
  revision, package version, and source digest. `execution_status: completed`
  means all eight attempts ran; it does not mean they passed quality checks.
- [semantic-review.json](semantic-review.json) records independent agent review
  of each frozen checkpoint and all generated claims, separately for raw and
  postprocessed stages. It is not owner acceptance or a validated automatic
  semantic metric. Two stages of one response are not independent samples.

| Input | Prompt tokens | Output tokens* | First text | Complete schema-valid package | Raw schema |
| --- | ---: | ---: | ---: | ---: | --- |
| Chinese release decision, final | 925 | 1,028 | 4.33 s | 13.84 s | Pass |
| English offline pilot, final | 927 | 814 | 1.15 s | 8.59 s | Pass |
| Mixed design review, final | 927 | 934 | 1.16 s | 9.71 s | Pass |
| Sound check only, final | 838 | 558 | 1.10 s | 6.22 s | Pass |
| Bilingual prefix through 28 s, live | 856 | 762 | 1.09 s | 8.07 s | Pass |
| Bilingual prefix through 64 s, live | 974 | 1,036 | 1.23 s | 10.75 s | Pass |
| Bilingual prefix through 110 s, live | 1,111 | 1,536 | 1.35 s | Unavailable; truncated at 15.48 s | Fail |
| Same complete bilingual story, final | 1,169 | 1,518 | 1.62 s | 15.59 s | Pass |

\* MLX's `generation_tokens` includes the stop token when one is produced. The
truncated response consumed its request and was not retried. There was no extra
compatibility generation, cloud request, or prompt-tuning round.

The complete-package median across the **seven structurally valid responses**
was 9.71 seconds; their range was 6.22–15.59 seconds. These are completion costs,
not a measure of usable, faithful summaries. The truncated response is retained
in the table and excluded only from that explicitly conditioned statistic.

Examples that establish the fidelity problem:

- The Chinese source specifies Friday without a calendar anchor. The response
  sets `action_tracks[0].due_at` to `2024-05-05 17:00:00`, invents a red-theme
  alternative in `decision_ledger[0].options`, and creates timeline events beyond
  the 15-second input. Postprocessing clips the last timestamp from 24 to 15
  seconds, but keeps the previous 16-second entry, producing a 16→15 sequence.
  All four timeline entries and the invented date and option remain.
- The English source assigns Blair a checklist. The response substitutes a
  launch-meeting task and adds a rationale that real data is unavailable. Neither
  is stated in the source.
- A source consisting only of a brief sound check produces a substantive
  decision and system-owned action. Empty decision and action arrays were allowed
  by the frozen expectations, so filling them was not necessary to pass schema.
- The final bilingual source corrects the **demo checklist** to Ren/Monday while
  the **risk list** remains unassigned and undated. The output transfers this
  assignment to the risk list, invents `2024-01-01`, and adds a future launch
  decision that the source explicitly does not approve.

The detailed review also covers proposals versus decisions, speaker attribution,
missing commitments, negation, corrected historical values, and unsupported
claims outside the required decision/action modules. Structural span or literal
owner checks are screening aids; they never assign semantic success.

## Measurement boundary

The machine reported `MacBookPro18,1`, 16 GiB RAM, macOS 27.0, AC power, and nominal
thermal state before and throughout the observed samples. Ordinary background
applications remained running. All model work held the shared `installed-app`
lock, with idle live-session/job status checked before and during execution.
There was no simultaneous experiment ASR, diarization, audio capture, or UI test.

One model load took 1.56 seconds, after imports and local file verification. The
worker's import/startup phase preceded that timer; it is not part of the load
number. The first request's first text took 4.33 seconds; subsequent requests took
1.09–1.62 seconds. Each request used a fresh prompt cache and the same loaded
model. No previous model output was included in later input. This does not
establish reboot-cold or controlled warm-machine latency.

`first_token_wall_s` and `first_text_wall_s` happened to match for all eight
requests. They include chat-template preparation and work up to the first
generation response. MLX's `library_prompt_tps` measures a library phase that
includes prefill and the first decode step; dividing prompt tokens by that value
does not isolate pure prefill. Do not add it to the inclusive first-token timer.

Generation time and library generation throughput include the token consumer's
raw-text write/flush cost. They measure generation with evidence capture, not
isolated GPU kernel speed. `complete_package_available_wall_s` ends after strict
JSON/schema validation and product postprocessing, before the experiment's
structural assessment. It is absent for truncation. `request_wall_s` also includes
assessment. No displayed summary or installed-app latency was measured.

MLX allocator peak memory ranged from 2.10 to 2.26 GB per request, including loaded
model allocations. This is not process RSS, total device memory, or headroom
under concurrent ASR. The 93.10-second worker/controller event interval and the
97.77-second outer observation interval have different endpoints and are not
additional model-latency stages.

The installed `6a85f89` / build `20260909123140` bundle and executable hashes,
runtime configuration hash, consent hash, and aggregate Records file metadata
were equal before/after. This is preservation evidence, not a fresh acceptance
test of that build. No private Record content was used; only file metadata was
observed for preservation. Host process lists and raw operational logs remain
local.

## Reproduction

This experiment uses the text-only MLX loader for the community conversion of
[Qwen's Qwen3.5-2B model](https://huggingface.co/Qwen/Qwen3.5-2B). The selected
[MLX four-bit repository](https://huggingface.co/mlx-community/Qwen3.5-2B-4bit/tree/674aaa7240b91e8012fcad5d791b7dfe5ba90207)
is pinned to `674aaa7240b91e8012fcad5d791b7dfe5ba90207`. Its eleven file sizes and
SHA256 hashes are in `run.json`; no weight files are committed here.

Use a separate Python 3.11 environment for model dependencies:

```sh
uv venv --python 3.11 logs/yan77/venv
uv pip install --python logs/yan77/venv/bin/python \
  mlx-lm==0.31.3 mlx==0.32.2 mlx-metal==0.32.2 \
  transformers==5.16.1 huggingface-hub==1.30.0 jsonschema==4.26.0
```

Acquire the pinned public repository in an isolated directory and retain the
`model` object from `run.json` as the model manifest:

```sh
HF_HUB_DISABLE_IMPLICIT_TOKEN=1 HF_HUB_DISABLE_TELEMETRY=1 \
  logs/yan77/venv/bin/python - <<'PY'
from pathlib import Path
import json
from huggingface_hub import snapshot_download

evidence = json.loads(Path('docs/experiments/2026-09-09-qwen-local-summary/run.json').read_text())
manifest = evidence['model']
snapshot_download(repo_id=manifest['repo_id'], revision=manifest['revision'],
                  local_dir='logs/yan77/models/qwen3.5-2b-4bit', token=False)
Path('logs/yan77/model-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
PY
```

The controller checks all listed file hashes and rejects unlisted safetensors
before loading a model. After an authorized idle/preservation preflight, run
once under the shared lock:

```sh
python3.11 scripts/agent_harness.py lock --resource installed-app --timeout 60 -- \
  .venv/bin/python scripts/compare_local_summary.py run \
  --model-path logs/yan77/models/qwen3.5-2b-4bit \
  --model-manifest logs/yan77/model-manifest.json \
  --python logs/yan77/venv/bin/python \
  --output logs/yan77/round1 \
  --max-tokens 1536 --request-timeout 120 --load-timeout 120
```

The output directory must not exist. The worker inherits an allowlist of basic
environment variables and explicitly disables Hugging Face networking, implicit
tokens, and telemetry. Generation is greedy, seed 7, thinking disabled, with no
provider resolver, retry, or fallback. The live input uses the product's current
inclusive 120-second transcript window; all frozen story prefixes fit within it.
Product system/live/final prompts, schema, service, validator, and postprocessor
hashes are recorded in `run.json`. Frozen expectations are review data and never
appear in the model prompt.

Raw JSON is parsed strictly before product validation and postprocessing. Fenced
or non-finite JSON is rejected and preserved as text. The runner does not use a
repair parser to claim raw schema compliance. Postprocessing receives a deep
copy; the original payload remains available even if a later stage changes it.
A wall timeout terminates the worker and leaves subsequent cases `not_run`.

## Delivery and next action

The runner/assessment regressions cover loss of a virtual environment through
symlink resolution, non-finite JSON receipts, timeout termination with partial
text, source hash changes, future-prefix leakage, cross-module false matches,
unknown or wrong-task assignment, and raw/postprocessed confusion. Full Harness
and exact-commit CI results are recorded with the pull request.

Do not adopt this measured configuration or spend the next performance window on
its concurrent ASR/LS-EEND integration. Continue the separately owned VibeVoice,
Nemotron, and Voxtral ASR comparison. The original plan's conditional 4B comparison
is now triggered by this 2B result. Preserve this first screen, then pre-register
the smallest useful subset of the same frozen inputs for one Qwen3.5-4B four-bit
comparison, retaining task identity, relative dates, abstention, and correction
checks. If 4B also fails fidelity, stop at that evidence rather than adding
concurrent model load. This screen does not authorize an unbounded tuning search.
