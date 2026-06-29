import os

from scripts.asr_runtime_profile import (
    APPLE_SPEECH_ENGINE,
    attach_asr_runtime_profile,
    configured_backend_status,
    engine_status_snapshot,
    engine_options,
    normalize_diarization_engine,
    normalize_engine_name,
    peer_engine_options,
    resolve_fluid_audio_cli,
    speaker_diarization_status,
)


def test_normalize_engine_name_keeps_canonical_engines():
    assert normalize_engine_name("whisper") == "whisper"
    assert normalize_engine_name("funasr") == "funasr"
    assert normalize_engine_name("qwen") == "qwen-mlx"
    assert normalize_engine_name("qwen_mlx") == "qwen-mlx"
    assert normalize_engine_name(None, default_engine="qwen-mlx") == "qwen-mlx"
    assert engine_options() == ["whisper", "funasr", "qwen-mlx"]
    assert peer_engine_options() == ["whisper", "funasr", "qwen-mlx", "apple-speech"]


def test_normalize_diarization_engine_keeps_hidden_switch_consistent():
    assert normalize_diarization_engine("fluid") == "fluid-lseend"
    assert normalize_diarization_engine("ls_eend") == "fluid-lseend"
    assert normalize_diarization_engine("pyannote-community-1") == "pyannote"
    assert normalize_diarization_engine("campplus") == "funasr"
    assert normalize_diarization_engine("disabled") == "none"
    assert normalize_diarization_engine("unexpected") == "fluid-lseend"


def test_resolve_fluid_audio_cli_prefers_configured_executable(tmp_path, monkeypatch):
    configured = tmp_path / "fluidaudiocli"
    configured.write_text("#!/bin/sh\n", encoding="utf-8")
    configured.chmod(0o755)
    monkeypatch.setenv("PATH", os.devnull)

    assert resolve_fluid_audio_cli(configured_cli=configured, model_dir=tmp_path) == configured


def test_configured_backend_status_uses_engine_profile_rules():
    whisper = configured_backend_status("whisper", asr_device="cpu", asr_compute_type="int8")
    assert whisper["device"] == "cpu"
    assert whisper["compute_type"] == "int8"
    assert "supported_compute_types" in whisper

    funasr = configured_backend_status("funasr")
    assert funasr["device"] == "auto"
    assert funasr["compute_type"] == "float32"

    qwen = configured_backend_status("qwen", qwen_mlx_compute_type="mlx")
    assert qwen["device"] == "mlx"
    assert qwen["compute_type"] == "mlx"
    assert "bfloat16" in qwen["supported_compute_types"]


def test_speaker_diarization_status_reports_fluid_and_pyannote_paths(tmp_path):
    configured = tmp_path / "fluidaudiocli"
    configured.write_text("#!/bin/sh\n", encoding="utf-8")
    configured.chmod(0o755)

    fluid = speaker_diarization_status(
        {},
        diarization_engine="fluid",
        model_dir=tmp_path,
        configured_cli=configured,
    )
    assert fluid["engine"] == "fluid-lseend"
    assert fluid["enabled"] is True
    assert fluid["ready"] is True
    assert fluid["path"] == str(configured)

    pyannote = speaker_diarization_status(
        {"pyannote-audio": True, "torch": True},
        diarization_engine="pyannote",
        hf_token_value="token",
    )
    assert pyannote["engine"] == "pyannote-community-1"
    assert pyannote["ready"] is True


def test_engine_status_snapshot_builds_public_runtime_shape(tmp_path):
    model_path = tmp_path / "model"
    status = engine_status_snapshot(
        required={"mlx-qwen3-asr": True, "silero-vad": True},
        optional={"pyannote-audio": False, "torch": False},
        model_name="Qwen3-ASR-1.7B-MLX-4bit",
        model_path=model_path,
        model_exists=True,
        vad_engine="silero-vad",
        vad_ready=True,
        timestamps={
            "engine": "qwen-forced-aligner",
            "enabled": True,
            "ready": False,
            "model": "Qwen3-ForcedAligner-0.6B",
            "path": str(tmp_path / "aligner"),
        },
        diarization_engine="none",
    )

    assert status["model"] == {
        "name": "Qwen3-ASR-1.7B-MLX-4bit",
        "path": str(model_path),
        "exists": True,
    }
    assert status["vad"]["engine"] == "silero-vad"
    assert status["timestamps"]["engine"] == "qwen-forced-aligner"
    assert status["speaker_diarization"]["engine"] == "none"
    assert status["ready"] is True


def test_attach_asr_runtime_profile_separates_live_and_final_media_readiness():
    status = {
        "engine": "qwen-mlx",
        "engine_options": ["whisper", "funasr", "qwen-mlx"],
        "ready": True,
        "ready_by_engine": {"whisper": False, "funasr": False, "qwen-mlx": True},
        "model": {"name": "Qwen3-ASR-1.7B-MLX-4bit", "exists": True},
        "dependencies": {"required": {"mlx-qwen3-asr": True}},
        "speaker_diarization": {"enabled": True, "ready": True, "degraded": False},
    }

    result = attach_asr_runtime_profile(
        status,
        backend={"device": "mlx", "compute_type": "mlx", "resolved": "mlx"},
        warm={"ready": False, "state": "idle", "in_progress": False},
        configured_engine="qwen",
    )

    profile = result["profile"]
    assert profile["schema_version"] == 1
    assert profile["configured_engine"] == "qwen-mlx"
    assert profile["active_engine"] == "qwen-mlx"
    assert profile["technical_status"] == "ready"
    assert profile["final_media_asr"]["ready"] is True
    assert profile["live_asr"]["ready"] is False
    assert "Warmup" in profile["live_asr"]["reason"]
    assert profile["degradation"]["active"] is False
    assert result["backend"]["device"] == "mlx"


def test_attach_asr_runtime_profile_reports_warming_state_for_live_runtime():
    result = attach_asr_runtime_profile(
        {
            "engine": "whisper",
            "ready": True,
            "ready_by_engine": {"whisper": True, "funasr": False, "qwen-mlx": False},
            "model": {"name": "large-v3", "exists": True},
            "dependencies": {"required": {"faster-whisper": True}},
            "speaker_diarization": {"enabled": False, "ready": False, "degraded": False},
        },
        warm={"ready": False, "state": "warming", "in_progress": True, "attempt": 1},
    )

    profile = result["profile"]
    assert profile["technical_status"] == "warming"
    assert profile["degradation"]["active"] is True
    assert profile["live_asr"]["ready"] is False
    assert profile["final_media_asr"]["ready"] is True


def test_asr_runtime_profile_represents_apple_speech_as_limited_peer_engine():
    result = attach_asr_runtime_profile(
        {
            "engine": "whisper",
            "ready": False,
            "ready_by_engine": {"whisper": False, "funasr": False, "qwen-mlx": False},
            "model": {"name": "large-v3", "exists": False},
            "dependencies": {"required": {"faster-whisper": False}},
            "speaker_diarization": {"enabled": False, "ready": False, "degraded": False},
        },
        env={"INSIGHTKIT_APPLE_SPEECH_PROTOTYPE_ENABLED": "1"},
    )

    apple = result["profile"]["engine_profiles"][APPLE_SPEECH_ENGINE]
    assert apple["engine"] == "apple-speech"
    assert apple["selectable"] is False
    assert apple["availability_state"] == "degraded"
    assert apple["capabilities"]["final_media_asr"] is True
    assert apple["capabilities"]["live_asr"] is False
    assert apple["capabilities"]["diarization"] is False
    assert apple["limitations"]
