# Native streaming ASR screening (YAN-78)

## Question and fixed cohort

Compare VibeVoice-ASR-Streaming-1.5B, Nemotron 3.5 ASR Streaming 0.6B,
and Voxtral Mini 4B Realtime on the owner's M1 Pro / 16 GiB machine.
This is a component experiment with finite clocked WAV input. Installed-app
capture, transport, UI, queue/drop policy and natural-meeting quality are outside
this measurement. Keep the installed app, runtime configuration and consent intact.

The first cohort uses exactly the 58-second mono 16-kHz PCM16 excerpt from
[YAN-76](https://github.com/YannJY02/AutoTranscribe/blob/4177c54d48017429fd22e936f02c881218dceccf/docs/performance/qwen-live-screening.md): SHA256
`8d61f394b9f63f5a5afc7f7190a02a4f614e6c0ae2c3a2c640188dce84619cfb`;
reference SHA256
`fd1cf2eecbd755c08cb747ea6253d759e053cb4b3d09d4a19902f0b3c4155108`.
There are 65 Chinese reference characters and 28 English reference words under
the declared scoring rules, two alternating synthetic voices and two seconds of
initial silence. Reference windows that intersect do not establish acoustic overlap.

All three candidates receive a real local attempt. The initial order is Nemotron,
Voxtral, then VibeVoice because VibeVoice requires a local weight conversion.
After Nemotron, VibeVoice conversion finished while the Voxtral transfer was still
in progress; the recorded pre-inference amendment runs VibeVoice next, then Voxtral.
Each model loads in a new offline subprocess, then runs two streams with the same
loaded weights and fresh per-stream state. First-stream setup and lazy compilation
remain visible. The second stream is a timing reuse check, not another quality sample.
Do not select the faster stream to represent the experiment or call this boot-cold.

A single 300-second extension per eligible model is conditional on useful short
results, resource headroom, or a specific unresolved state-retention question.
VibeVoice stays under the officially documented eight-minute scope. Record the
reason before any extension. An adapter failure warrants only a bounded follow-up
for its identified cause; retain the failed evidence. A negative quality result
is sufficient to reject an immediate product switch.

## Implementations and model pins

| Candidate | Runtime | Weights | Native cadence |
| --- | --- | --- | --- |
| Nemotron | NVIDIA/NeMo-Speech.cpp v0.1.0, `4f9676226f667d14608487df744f375db87127f8`, official macOS arm64 Metal C ABI | NVIDIA GGUF Q8_0, `1c8deaecc64b91f034d73e08dd8b64625eb3395d` | 320 ms encoder mode, 320 ms input packets |
| Voxtral | awni/voxmlx `e6d193e85e84e30f26e370c66973ce287b8a9d57` | T0mSIlver/Voxtral-Mini-4B-Realtime-2602-MLX-4bit, `e41b00294733d2db2fe767cd7c5454ba617c2bed` | Original 80 ms microphone loop, 480 ms configured delay |
| VibeVoice | mlx-audio `17001a6950956302f15b53d86b601324efe716ba` | Microsoft `4262d23d8a539a6530cf64fbd0b1751ef9a30853`, verified tied head, LM-only 4bit; audio encoders BF16 | 2.933 s audio step, 3.467 s native window at 24 kHz |

The Voxtral conversion is a community model whose card attributes the original
Mistral model; that conversion's equivalence to the original weights is not
independently established. Configured cadence/delay is not measured text latency.
Nemotron uses a fixed `auto` language prompt and disables endpointing, punctuation,
VAD and separate diarization. Its cumulative partials and synchronous final flush
are captured through the C ABI. Voxtral retains the stock stream, caches, EOS
reset and final flush, replacing only microphone acquisition with the finite WAV.
VibeVoice preserves native streaming state; input resampling can read only the
released input frontier plus the declared FIR halo, which is also clocked.

## Clock, quality and resource definitions

- Start the stream clock immediately before the adapter call, after initial report
  publication. Release audio only after its sample-clock deadline; accelerated
  mode is available for troubleshooting and must never become real-time evidence.
- First text is the first nonempty emitted text event. Preserve delta, cumulative
  and final semantics. Model speaker tags and control text remain in raw evidence;
  candidate-specific extraction must be reported separately from recognition.
- `final_text_available_ms` is frozen as soon as the adapter returns finalized
  text, before CER/WER scoring. It is an upper bound that includes the adapter's
  flush/cleanup, distinct from individual text-event timestamps.
- Source lateness is actual release minus the WAV deadline. It is not token
  alignment, queue depth, or speech-to-text latency. The adapter can fall behind
  and then catch up; all releases and text changes are retained.
- Use YAN-76 normalization: NFKC, lowercase, curly apostrophe to straight;
  Chinese CER over Han characters, English WER over ASCII word/number tokens.
  These scores do not test punctuation, speaker identity, time alignment or
  cross-language order. Review raw text for omissions and invented content.
- Poll worker RSS/CPU once per second; RSS does not fully account for GPU/shared
  memory. Keep adapter-specific MLX counters separate. Start on AC power with
  nominal thermal state; record thermal/swap state and app idleness. Serialise
  model runs and conversions with the repository `installed-app` lock.
  Nemotron ran while the other pinned public weights were downloading; record
  that I/O confound, especially for setup and first-stream timing. Do not infer
  a precise performance ranking from small differences between candidates.

The controller permits at most 1,200 seconds per candidate process and an 8 GiB
worker RSS sample. Generative adapters have 4,096 output tokens per stream;
Nemotron instead has finite input and wall-clock bounds. Stop on a failed
preflight, model exception, incomplete input/finalization, token limit, timeout,
RSS limit, serious thermal pressure or app activity. Preserve partial reports,
stdout/stderr, events and resource samples. Never automatically rerun a failure.

## Execution and evidence

Use `scripts/compare_streaming_asr.py` with model-specific isolated Python and
local pinned runtime/model paths, `--pacing realtime --passes 2`, fixed input and
reference, and a new output path. It imports no application provider or capture
code. Its child receives a core environment allowlist and offline flags.

Acquire the lock before invoking the external controller. Local
`logs/yan78/run_guarded.py` verifies app/configuration/consent before and after,
checks app idleness, power and thermal state, and records source hashes. It is
archived with the published experiment evidence. Model downloads are separate
public, pinned, hash-verified reads. Model weights, dependency environments and
full local logs are excluded from Git; publish compact synthetic evidence and
an inventory of raw paths and hashes.

Doctor and the frozen corpus check must pass before actual model work. Run
adapter/clock/failure tests before the first cohort, independent review before
handoff, and the repository full Harness on final content. Commit, push, open a
PR and verify CI on that exact head. Record results and decisions in YAN-78 and
aggregate with YAN-76 / YAN-77; product defaults and merge retain their own gates.
