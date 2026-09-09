# Progressive live transcript validation

Contract: [YAN-75](https://linear.app/yannjy/issue/YAN-75) / [GitHub #121](https://github.com/YannJY02/AutoTranscribe/issues/121).

This slice publishes recognized text before speaker enrichment and live Smart Minutes. It retains the selected ASR model, the first 2-second/subsequent 8-second chunk schedule, and the existing analysis preference. Later model comparisons require owner feedback on this slice.

## Regression evidence

- A controlled 400 ms summary held the previous transcript pipeline for 406.96 ms. The progressive pipeline returns the transcript request independently; separate bounded queues own summaries and speakers.
- The portable `LiveProgressiveWorkspaceTests/testSecondTranscriptAppearsBeforeDelayedSummary` fixture uses the normal RPC clients with a 6-second summary. On base `18fea4b`, its 1.5-second second-transcript assertion failed. On the progressive implementation, that assertion and the 1.5-second stop assertion passed. Both native runs retain window screenshots. The fixture runs inside the isolated test app because the sandboxed UI runner cannot host its Unix socket.
- Python tests cover private word timestamps, word-level speaker changes, partial stability, deduplicated rows, bounded audio retention, initialization cancellation, stop/restart races, and transcript recovery. Summary tests cover single-flight admission and independent live/final provider metadata.
- Helper tests cover the real JSONL process with stdin kept open, the pinned SDK's open speaker intervals, right-context exclusion, sub-millisecond offset rounding, gaps, invalid input, and session cleanup.

Local evidence is under `logs/yan75/`; the full Harness independently records its selected gates and file digests. Run it before handoff:

```sh
python3.11 scripts/agent_harness.py verify --issue 121 --mode full
```

## Bounded local model smoke

The frozen `short-zh` synthetic fixture matched its committed SHA256. One 26-second excerpt was split at 0/2/10/18/26 seconds. The current Qwen3-ASR-1.7B-MLX-4bit instance was reused across its three speech chunks and produced the expected three transcript passages, with recognition errors still present.

Observed ASR calls for the 8-second chunks took 18.7, 35.8, and 16.7 seconds in this run. These are limited, partly cold observations, not a steady-state benchmark. This slice removes downstream waiting; it does not establish real-time ASR on the test Mac.

The first combined smoke exposed a helper input-buffering bug. After fixing it, the same audio and previously recognized text were replayed through the real LS-EEND helper without repeating ASR. A copied standalone executable loaded the existing local DIHARD3 500 ms weights, reused one process, and assigned `SPEAKER_00`, `SPEAKER_01`, `SPEAKER_00`. Startup plus the first silent chunk took 837 ms; subsequent feeds took 74/69/69 ms. Those feed times exclude ASR and capture buffering. This checks local integration on synthetic voices; real conversations, quiet interruptions, overlapping speech and long sessions still require human evaluation.

## Manual acceptance

1. Record a short conversation with two people taking turns, including a sustained sentence and a brief interruption. Observe text arrival, later speaker corrections, and Smart Minutes updates.
2. Continue speaking while a summary is updating. Check that newly recognized text keeps appearing and speaker labels retain the same person across turns.
3. Stop, reopen the saved Record, and compare media duration, transcript seek times, speaker labels and generated minutes. Start a second session and confirm that old text or summaries do not appear in it.

Report text delay, speaker mistakes, summary delay and stop/save behavior separately. Owner acceptance and any later model changes remain explicit follow-up gates.
