"""Canonical local ASR model identifiers for InsightKit scripts."""

from __future__ import annotations

WHISPER_DEFAULT_MODEL = "large-v3"
WHISPER_RECOMMENDED_FAST_MODEL = "large-v3-turbo"
QWEN_MLX_ENGINE = "qwen-mlx"
QWEN_MLX_DEFAULT_MODEL = "Qwen3-ASR-1.7B-MLX-4bit"
QWEN_MLX_FP16_MODEL = "Qwen3-ASR-1.7B"
QWEN_MLX_FORCED_ALIGNER_MODEL = "Qwen3-ForcedAligner-0.6B"

WHISPER_PRESETS = [
    WHISPER_RECOMMENDED_FAST_MODEL,
    WHISPER_DEFAULT_MODEL,
    "large-v2",
    "large-v1",
    "medium",
    "small",
    "base",
    "tiny",
]

FUNASR_LID_MODEL = "iic/SenseVoiceSmall"
FUNASR_DEFAULT_ASR_MODEL = "iic/speech_paraformer-large-vad-punc_asr_nat-zh-cn-16k-common-vocab8404-pytorch"
FUNASR_RECOMMENDED_ASR_MODEL = "FunAudioLLM/Fun-ASR-Nano-2512"
FUNASR_VAD_MODEL = "iic/speech_fsmn_vad_zh-cn-16k-common-pytorch"
FUNASR_PUNC_MODEL = "iic/punc_ct-transformer_zh-cn-common-vocab272727-pytorch"
FUNASR_SPK_MODEL = "iic/speech_campplus_sv_zh-cn_16k-common"

FUNASR_PRESETS = [
    FUNASR_LID_MODEL,
    FUNASR_RECOMMENDED_ASR_MODEL,
    FUNASR_DEFAULT_ASR_MODEL,
    "iic/speech_seaco_paraformer_large_asr_nat-zh-cn-16k-common-vocab8404-pytorch",
    "iic/speech_paraformer-large-contextual_asr_nat-zh-cn-16k-common-vocab8404",
]

QWEN_MLX_PRESETS = [
    QWEN_MLX_DEFAULT_MODEL,
    QWEN_MLX_FP16_MODEL,
    "Qwen/Qwen3-ASR-1.7B",
    "aufklarer/Qwen3-ASR-1.7B-MLX-4bit",
]

# Keep the unattended weekly updater limited to the currently configured
# production defaults. New large candidate models should be bootstrapped only
# after an explicit model-selection action.
FUNASR_UPDATE_MODELS = [
    FUNASR_LID_MODEL,
    FUNASR_DEFAULT_ASR_MODEL,
    FUNASR_VAD_MODEL,
    FUNASR_PUNC_MODEL,
    FUNASR_SPK_MODEL,
]

WHISPER_REPO_FALLBACKS = {
    "large": "Systran/faster-whisper-large-v3",
    "large-v3": "Systran/faster-whisper-large-v3",
    "large-v3-turbo": "mobiuslabsgmbh/faster-whisper-large-v3-turbo",
    "turbo": "mobiuslabsgmbh/faster-whisper-large-v3-turbo",
}

QWEN_MLX_REPO_FALLBACKS = {
    QWEN_MLX_DEFAULT_MODEL: "aufklarer/Qwen3-ASR-1.7B-MLX-4bit",
    QWEN_MLX_FP16_MODEL: "Qwen/Qwen3-ASR-1.7B",
    QWEN_MLX_FORCED_ALIGNER_MODEL: "Qwen/Qwen3-ForcedAligner-0.6B",
}


def whisper_repo_for_model(model_name: str) -> str:
    """Resolve a faster-whisper size alias or Hub repo ID to a download repo."""
    normalized = model_name.strip()
    if "/" in normalized:
        return normalized
    try:
        from faster_whisper.utils import _MODELS

        repo = _MODELS.get(normalized)
        if repo:
            return str(repo)
    except Exception:
        pass
    return WHISPER_REPO_FALLBACKS.get(normalized) or f"Systran/faster-whisper-{normalized}"


def qwen_mlx_repo_for_model(model_name: str) -> str:
    """Resolve a Qwen MLX local folder name or Hub repo ID to a download repo."""
    normalized = model_name.strip()
    if "/" in normalized:
        return normalized
    return QWEN_MLX_REPO_FALLBACKS.get(normalized, normalized)


def is_funasr_nano_model(model_name: str) -> bool:
    return "Fun-ASR-Nano" in model_name
