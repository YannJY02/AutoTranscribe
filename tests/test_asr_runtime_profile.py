import os

from scripts.asr_runtime_profile import (
    configured_backend_status,
    engine_status_snapshot,
    engine_options,
    normalize_diarization_engine,
    normalize_engine_name,
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
