from scripts import asr_model_catalog as catalog
from scripts.asr_runtime_bootstrap import DEFAULT_FUNASR_MODEL, DEFAULT_QWEN_MLX_MODEL, DEFAULT_WHISPER_MODEL, _repo_for_whisper
from scripts.transcriber import DEFAULT_MODEL_NAME, FUNASR_ASR_MODEL, QWEN_MLX_MODEL


def test_safe_defaults_stay_on_cached_production_models():
    assert DEFAULT_WHISPER_MODEL == "large-v3"
    assert DEFAULT_MODEL_NAME == "large-v3"
    assert DEFAULT_FUNASR_MODEL == catalog.FUNASR_DEFAULT_ASR_MODEL
    assert FUNASR_ASR_MODEL == catalog.FUNASR_DEFAULT_ASR_MODEL
    assert DEFAULT_QWEN_MLX_MODEL == catalog.QWEN_MLX_DEFAULT_MODEL
    assert QWEN_MLX_MODEL == catalog.QWEN_MLX_DEFAULT_MODEL


def test_new_candidate_models_are_exposed_without_unattended_downloads():
    assert catalog.WHISPER_RECOMMENDED_FAST_MODEL == "large-v3-turbo"
    assert catalog.WHISPER_RECOMMENDED_FAST_MODEL in catalog.WHISPER_PRESETS
    assert catalog.FUNASR_RECOMMENDED_ASR_MODEL == "FunAudioLLM/Fun-ASR-Nano-2512"
    assert catalog.FUNASR_RECOMMENDED_ASR_MODEL in catalog.FUNASR_PRESETS
    assert catalog.FUNASR_RECOMMENDED_ASR_MODEL not in catalog.FUNASR_UPDATE_MODELS
    assert catalog.QWEN_MLX_DEFAULT_MODEL in catalog.QWEN_MLX_PRESETS


def test_turbo_whisper_alias_resolves_to_supported_faster_whisper_repo():
    assert _repo_for_whisper("large-v3-turbo") == "mobiuslabsgmbh/faster-whisper-large-v3-turbo"
    assert catalog.whisper_repo_for_model("Systran/faster-whisper-large-v3") == "Systran/faster-whisper-large-v3"


def test_qwen_aliases_resolve_to_supported_hub_repos():
    assert catalog.qwen_mlx_repo_for_model("Qwen3-ASR-1.7B-MLX-4bit") == "aufklarer/Qwen3-ASR-1.7B-MLX-4bit"
    assert catalog.qwen_mlx_repo_for_model("Qwen/Qwen3-ASR-1.7B") == "Qwen/Qwen3-ASR-1.7B"
