import sys
import types
from types import SimpleNamespace

from scripts import transcriber
from scripts.transcriber import _speaker_annotation_from_pyannote


def _clear_pyannote_cache():
    with transcriber._model_registry_lock:
        for key in list(transcriber._models):
            if key.startswith("pyannote_pipeline:"):
                transcriber._models.pop(key, None)


def test_load_diarization_pipeline_uses_new_pyannote_token_arg(monkeypatch):
    class FakePipeline:
        calls = []

        @classmethod
        def from_pretrained(cls, model_id, **kwargs):
            cls.calls.append((model_id, kwargs))
            return object()

    fake_audio = types.SimpleNamespace(Pipeline=FakePipeline)
    monkeypatch.setitem(sys.modules, "pyannote.audio", fake_audio)
    monkeypatch.setattr(transcriber, "DIARIZATION_ENABLED", True)
    monkeypatch.setattr(transcriber, "HF_TOKEN", "test-token")
    monkeypatch.setattr(transcriber, "PYANNOTE_MODEL_ID", "pyannote/speaker-diarization-community-1")
    _clear_pyannote_cache()

    pipeline = transcriber._load_diarization_pipeline()

    assert pipeline is not None
    assert FakePipeline.calls == [
        ("pyannote/speaker-diarization-community-1", {"token": "test-token"})
    ]
    _clear_pyannote_cache()


def test_load_diarization_pipeline_falls_back_to_legacy_auth_arg(monkeypatch):
    class FakePipeline:
        calls = []

        @classmethod
        def from_pretrained(cls, model_id, **kwargs):
            cls.calls.append((model_id, kwargs))
            if "token" in kwargs:
                raise TypeError("unexpected keyword argument 'token'")
            return object()

    fake_audio = types.SimpleNamespace(Pipeline=FakePipeline)
    monkeypatch.setitem(sys.modules, "pyannote.audio", fake_audio)
    monkeypatch.setattr(transcriber, "DIARIZATION_ENABLED", True)
    monkeypatch.setattr(transcriber, "HF_TOKEN", "test-token")
    monkeypatch.setattr(transcriber, "PYANNOTE_MODEL_ID", "pyannote/speaker-diarization-3.1")
    _clear_pyannote_cache()

    pipeline = transcriber._load_diarization_pipeline()

    assert pipeline is not None
    assert FakePipeline.calls == [
        ("pyannote/speaker-diarization-3.1", {"token": "test-token"}),
        ("pyannote/speaker-diarization-3.1", {"use_auth_token": "test-token"}),
    ]
    _clear_pyannote_cache()


def test_speaker_annotation_supports_pyannote_community_output():
    exclusive = SimpleNamespace(itertracks=lambda yield_label=True: iter(()))
    regular = SimpleNamespace(itertracks=lambda yield_label=True: iter(()))
    output = SimpleNamespace(
        exclusive_speaker_diarization=exclusive,
        speaker_diarization=regular,
    )

    assert _speaker_annotation_from_pyannote(output) is exclusive
    assert _speaker_annotation_from_pyannote(regular) is regular
