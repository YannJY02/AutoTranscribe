# Local ASR Model Upgrade Blueprint

Date: 2026-05-21

## Current State

- Machine baseline: Apple M1 Pro, 16 GB memory, macOS 26.5, about 48 GB free disk.
- Cached local models:
  - `faster-whisper/large-v3` exists and is about 2.9 GB.
  - FunASR model bundle exists and is about 1.2 GB.
- Installed Python ASR dependencies:
  - Present: `faster-whisper`, `ctranslate2`, `silero-vad`, `huggingface-hub`, `torch`, `torchaudio`, `openai`.
  - Missing: `funasr`, `modelscope`, `pyannote.audio`, `google-generativeai`.
- Current stable default path:
  - Engine: `whisper`.
  - Model: `large-v3`.
  - Strict local mode expects the selected model to already exist under `~/Library/Application Support/InsightKit/models`.

## Research Summary

### Candidate Matrix

| Candidate | Fit | Local Runtime | Strength | Risk / Gate |
| --- | --- | --- | --- | --- |
| `large-v3` via faster-whisper | Keep as safe default | Already cached and dependencies installed | Best current stability on this machine | Slower than turbo |
| `large-v3-turbo` via faster-whisper | Recommended fast preset | Needs model download before switching default | OpenAI model card describes fewer decoder layers and faster inference with minor quality loss; good Apple Silicon fit through CTranslate2 CPU int8 | Do not set as default until downloaded and smoke-tested |
| `FunAudioLLM/Fun-ASR-Nano-2512` | Recommended Chinese/domain candidate | Needs FunASR + ModelScope dependency install and model download | Official FunASR docs list 800M params, Chinese/English/Japanese, dialect/accent support, and diarization examples | Needs `trust_remote_code`/`remote_code`; do not unattended-download |
| `iic/SenseVoiceSmall` | Lightweight FunASR preset | Needs FunASR dependency | 234M params, multilingual speech understanding in FunASR model zoo | Existing code uses it mostly as LID/preset; not the safest default ASR |
| Qwen3-ASR / GLM-ASR-Nano | Research-only for now | Needs newer model-specific integration | Newer official FunASR model zoo entries | Different inference surface and heavier integration; not a direct drop-in |

### Source Notes

- FunASR official README lists Qwen3-ASR and GLM-ASR-Nano as newly added on 2026-05-20, and Fun-ASR-Nano diarization support on 2026-05-19.
- FunASR model zoo lists Fun-ASR-Nano as 800M parameters and Whisper-large-v3-turbo as 809M parameters.
- OpenAI's `whisper-large-v3-turbo` model card says turbo reduces decoder layers from 32 to 4, making it faster with minor quality degradation.
- `faster-whisper` supports CTranslate2 CPU int8, which matches the current M1 Pro dependency and strict-local architecture.

## Execution Plan

### Step 1: Centralize Script Model IDs

Files:
- `scripts/asr_model_catalog.py`
- `scripts/config.py`
- `scripts/transcriber.py`
- `scripts/asr_runtime_bootstrap.py`
- `scripts/update.py`

Tasks:
- Add one script-side catalog for current defaults, recommended candidates, presets, and unattended update model IDs.
- Keep `large-v3` and current Paraformer as production defaults.
- Add `large-v3-turbo` and `Fun-ASR-Nano-2512` as supported/recommended candidates.
- Keep weekly unattended update list limited to current production defaults.

Verification:
- `python -m py_compile scripts/asr_model_catalog.py scripts/config.py scripts/transcriber.py scripts/asr_runtime_bootstrap.py scripts/update.py`
- `python -m pytest tests/test_asr_model_catalog.py tests/test_asr_runtime_status.py tests/test_asr_engine_switch_status.py tests/test_asr_dispatcher.py -q`

Rollback:
- Remove `scripts/asr_model_catalog.py` and restore hard-coded constants.

### Step 2: Fix Candidate Bootstrap Compatibility

Files:
- `scripts/asr_runtime_bootstrap.py`
- `scripts/transcriber.py`

Tasks:
- Resolve faster-whisper aliases through the installed `faster_whisper.utils._MODELS` table with a static fallback for turbo.
- Download Whisper models via `faster_whisper.utils.download_model` instead of manually constructing `Systran/faster-whisper-*`.
- Add Fun-ASR-Nano `remote_code` handling for future bootstrap/use after explicit dependency and model download.

Verification:
- Unit tests assert the turbo alias resolves to the supported faster-whisper repo.
- Runtime status remains ready for the existing `large-v3` cache.

Rollback:
- Restore previous `_repo_for_whisper` and `AutoModel(...)` arguments.

### Step 3: Surface New Candidate In The App

Files:
- `macos/InsightKitApp/Sources/InsightKitApp/Services/AppConfigStore.swift`

Tasks:
- Add `FunAudioLLM/Fun-ASR-Nano-2512` to FunASR presets.
- Do not change default Swift config from `large-v3` or current Paraformer.

Verification:
- Swift package build/test when the current unrelated UI worktree changes are ready.

Rollback:
- Remove the preset entry.

### Step 4: Deferred Explicit-Gate Work

Do only after user confirmation:

- Download `large-v3-turbo` into `~/Library/Application Support/InsightKit/models/faster-whisper/large-v3-turbo`.
- Run a real A/B transcription on the same audio with `large-v3` and `large-v3-turbo`.
- If quality is acceptable and speed improves, switch default Whisper profile to `large-v3-turbo`.
- Install `funasr`/`modelscope`, download `Fun-ASR-Nano-2512`, and test Chinese/domain audio before considering any FunASR default switch.

Stop conditions:
- Model download exceeds disk budget.
- Dependency install conflicts with current environment.
- Real audio quality regresses materially.
- App runtime status reports the selected default as not ready.
