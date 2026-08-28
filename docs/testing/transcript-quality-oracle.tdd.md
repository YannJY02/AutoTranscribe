# Transcript Quality Oracle TDD Evidence

## Contract

Source: the user-approved second Product Quality Oracle increment.

- Reuse the frozen v1 benchmark corpus and existing real-import journey.
- Record English WER and Chinese CER under `proof.json.oracles.transcript`.
- Fail on missing or unusable measurement evidence.
- Do not invent a quality budget before a measured baseline exists.

Run the existing journey with one additional argument:

```bash
/Users/yann.jy/miniconda3/envs/transcribe/bin/python -m scripts.run_real_import_e2e \
  --sample "/Users/yann.jy/Library/Application Support/InsightKit/BenchmarkFixtures/v1/media/short-en.m4a" \
  --reference-transcript "/Users/yann.jy/Library/Application Support/InsightKit/BenchmarkFixtures/v1/reference-transcripts/short-en.json"
```

## RED and GREEN checkpoints

| Behavior | RED evidence | GREEN evidence |
| --- | --- | --- |
| Deterministic English WER and Chinese CER | `0ac982d`; collection failed because `evaluate_transcript_oracle` did not exist | `55547e9`; the focused Oracle and existing SQL/smoke suite passed 8/8 tests |
| Chinese transcript FTS proof | `dd96b1d`; the completed Chinese import failed because no ASCII search token existed | `b611570`; Chinese token selection is covered and the focused suite passed 9/9 tests |

## Frozen-corpus verification

`scripts/performance_fixture_corpus.py verify` passed with 6 fixture assets and
1,100 Record Folders. The committed manifest pins the media and reference hashes.

## Real baseline trials

| Fixture | Complete product journey | Metric | Units | Proof |
| --- | --- | --- | --- | --- |
| `short-en` | PASS | `asr.wer_pct = 71.0256` | 390 reference words; 633 hypothesis words | `/private/tmp/insightkit-transcript-en.JHUPfB/proof.json` |
| `short-zh` | PASS after the FTS regression fix | `asr.cer_pct = 38.9333` | 750 reference characters; 937 hypothesis characters | `/private/tmp/insightkit-transcript-zh.3g6zbm/proof.json` |

Both successful proofs also passed the database Oracle, exports, and clean
sidecar shutdown. The earlier Chinese failure remains at
`/private/tmp/insightkit-transcript-zh.hamcNx/proof.json`.

The full non-model Python suite passed 288 tests with 2 skipped and 3
deselected at 80.86% coverage. The isolated local runner requires
`PYTHONPATH=.` because this worktree is not installed as a package.

`passed=true` means the frozen reference was usable and the requested metric
was computed. It does not claim acceptable ASR quality. The first observed
WER/CER values are baselines; selecting a future regression budget requires a
separate human product decision.
