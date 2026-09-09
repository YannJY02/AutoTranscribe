"""Model-free checks for the bounded Qwen comparison protocol."""

from contextlib import nullcontext
import json
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace
import wave

import pytest

from scripts import compare_qwen_live_asr as bench


def make_input(tmp_path, *, channels=1, width=2, rate=16000, seconds=58):
    audio = tmp_path / "input.wav"
    with wave.open(str(audio), "wb") as stream:
        stream.setparams((channels, width, rate, 0, "NONE", "not compressed"))
        stream.writeframes(b"\0" * channels * width * rate * seconds)
    reference = tmp_path / "reference.json"
    reference.write_text(json.dumps({"segments": [
        {"start_ms": 2000, "end_ms": 8000, "text": "你好世界"},
        {"start_ms": 11000, "end_ms": 17000, "text": "The same input."},
    ]}), encoding="utf-8")
    return audio, reference


def model_dir(path):
    path.mkdir(parents=True)
    (path / "config.json").write_text("{}")
    (path / "model.safetensors").write_bytes(b"fake, never loaded")
    return path


class FakeRecorder:
    def __init__(self, label):
        self.label = label

    def snapshot(self):
        return {"job_id": self.label, "spans": []}


FAKE_TIMING = SimpleNamespace(TimingRecorder=FakeRecorder, timing_context=lambda recorder: nullcontext())


def test_exact_chunk_pcm_is_reused_for_both_passes(tmp_path):
    audio, reference = make_input(tmp_path)
    receipt, chunks = bench.prepare_input(audio, reference, tmp_path)
    assert [(item["start_ms"], item["end_ms"]) for item in chunks] == [
        (0, 2000), (2000, 10000), (10000, 18000), (18000, 26000),
        (26000, 34000), (34000, 42000), (42000, 50000), (50000, 58000),
    ]
    assert receipt["selected_duration_ms"] == 58000
    assert receipt["reference_text"] == "你好世界 The same input."
    for chunk in chunks:
        with wave.open(str(chunk["path"]), "rb") as stream:
            assert stream.getnframes() == chunk["audio_ms"] * 16


@pytest.mark.parametrize("settings", [{"channels": 2}, {"width": 1}, {"rate": 8000}, {"seconds": 57}])
def test_rejects_audio_that_would_need_resampling_or_padding(tmp_path, settings):
    audio, reference = make_input(tmp_path, **settings)
    with pytest.raises(ValueError):
        bench.prepare_input(audio, reference, tmp_path)


def test_rejects_partial_reference_at_slice_boundary(tmp_path):
    audio, reference = make_input(tmp_path)
    reference.write_text(json.dumps({"segments": [{"start_ms": 57000, "end_ms": 59000, "text": "unfinished"}]}))
    with pytest.raises(ValueError, match="crosses"):
        bench.prepare_input(audio, reference, tmp_path)


def test_chinese_cer_and_english_wer_keep_their_own_units():
    metrics = bench.quality_metrics("你好世界。 Don't change 42 files.", "你好世。 Don’t change 42 file.")
    assert metrics["chinese_cer"] == {"errors": 1, "reference_units": 4, "hypothesis_units": 3, "rate": 0.25}
    assert metrics["english_wer"] == {"errors": 1, "reference_units": 4, "hypothesis_units": 4, "rate": 0.25}
    assert bench.quality_metrics("只有中文", "English")["english_wer"]["rate"] is None


def test_queue_estimate_accounts_for_backlog_and_initial_silence():
    estimate = bench.queue_estimate([
        {"index": 1, "end_ms": 2000, "call_wall_ms": 11000, "text": ""},
        {"index": 2, "end_ms": 10000, "call_wall_ms": 3000, "text": "hello"},
        {"index": 3, "end_ms": 18000, "call_wall_ms": 500, "text": "next"},
    ])
    assert [row["queue_wait_ms"] for row in estimate["chunks"]] == [0, 3000, 0]
    assert estimate["first_text_at_ms"] == 16000
    assert estimate["finish_ms"] == 18500
    assert "not_ui_measurement" in estimate["kind"]


def test_model_override_isolated_and_keeps_live_timestamp_vad_settings(tmp_path):
    inherited = {"INSIGHTKIT_QWEN_MLX_MODEL_PATH": "/baseline", "INSIGHTKIT_QWEN_LANGUAGE": "Chinese",
                 "INSIGHTKIT_QWEN_MAX_NEW_TOKENS": "256", "INSIGHTKIT_QWEN_RETURN_TIMESTAMPS": "0"}
    config = {"modelDir": str(tmp_path), "vadEnabled": False, "diarizationEnabled": True}
    env = bench.model_environment(config, tmp_path / "candidate", inherited)
    assert inherited["INSIGHTKIT_QWEN_MLX_MODEL_PATH"] == "/baseline"
    assert all(env[key] == str(tmp_path / "candidate") for key in bench.MODEL_KEYS)
    assert env["INSIGHTKIT_QWEN_MLX_MODEL_PATH"] == str(tmp_path / "candidate")
    assert env["INSIGHTKIT_QWEN_RETURN_TIMESTAMPS"] == "1"
    assert env["INSIGHTKIT_VAD_ENABLED"] == "0"
    assert env["INSIGHTKIT_DIARIZATION_ENABLED"] == "1"
    assert env["INSIGHTKIT_QWEN_LANGUAGE"] == "Chinese"
    assert env["INSIGHTKIT_QWEN_MAX_NEW_TOKENS"] == "256"
    assert env["HF_HUB_OFFLINE"] == env["TRANSFORMERS_OFFLINE"] == "1"


def test_repo_resolution_is_offline_and_does_not_guess_by_basename(tmp_path, monkeypatch):
    cached = model_dir(tmp_path / "exact-owner-repo")
    calls = []

    def snapshot(**kwargs):
        calls.append(kwargs)
        return str(cached)

    monkeypatch.setitem(sys.modules, "huggingface_hub", SimpleNamespace(snapshot_download=snapshot))
    assert bench.resolve_model("owner/repo") == cached
    assert calls == [{"repo_id": "owner/repo", "local_files_only": True}]
    assert bench.resolve_model(str(cached)) == cached
    with pytest.raises(ValueError, match="absolute"):
        bench.resolve_model("short-alias")
    with pytest.raises(ValueError, match="missing"):
        bench.resolve_model(str(tmp_path / "missing"))


def test_config_reads_only_asr_selection_and_validates_boolean(tmp_path):
    config = tmp_path / "config.json"
    config.write_text(json.dumps({"asr": {"engine": "qwen-mlx", "vadEnabled": False}, "analysis": {"key": "unused"}}))
    assert bench.read_asr_config(config) == {"engine": "qwen-mlx", "vadEnabled": False}
    config.write_text('{"asr": {"vadEnabled": "false"}}')
    with pytest.raises(ValueError, match="boolean"):
        bench.read_asr_config(config)


def test_protocol_initializes_once_and_retains_one_failure_without_retry(tmp_path):
    audio, reference = make_input(tmp_path)
    receipt, chunks = bench.prepare_input(audio, reference, tmp_path)
    calls, initialized = [], []

    def transcribe(path, **kwargs):
        calls.append((path, kwargs))
        if len(calls) == 2:
            raise RuntimeError("deliberate chunk failure")
        return [{"start_ms": kwargs["offset_ms"], "end_ms": kwargs["offset_ms"] + 1000, "text": "你好 same"}]

    transcriber = SimpleNamespace(_load_qwen_mlx_session=lambda: initialized.append(True), transcribe_audio_chunk=transcribe)
    report = {"status": "running", "passes": [], "input": receipt}
    output = tmp_path / "result.json"
    bench.run_measurements(report, chunks, transcriber, FAKE_TIMING, bench.LibraryProbe(tmp_path, tmp_path), output)
    assert initialized == [True]
    assert len(calls) == 16
    assert calls[:8] == calls[8:]
    assert all(options["attach_diarization"] is False and options["preserve_words"] is True for _, options in calls)
    saved = json.loads(output.read_text())
    assert saved["status"] == "failed"
    assert saved["passes"][0]["chunks"][1]["error"]["message"] == "deliberate chunk failure"
    assert [item["failed_chunks"] for item in saved["passes"]] == [1, 0]
    assert saved["passes"][1]["quality"]["chinese_cer"]["reference_units"] == 4
    assert output.stat().st_mode & 0o777 == 0o600


def test_initialization_failure_stops_before_any_chunk_and_remains_in_output(tmp_path):
    def fail():
        raise RuntimeError("weights incompatible")

    transcriber = SimpleNamespace(_load_qwen_mlx_session=fail)
    report = {"status": "running", "passes": []}
    output = tmp_path / "result.json"
    bench.run_measurements(report, [], transcriber, FAKE_TIMING, bench.LibraryProbe(tmp_path, tmp_path), output)
    assert report["status"] == "failed"
    assert report["initialization"]["error"]["message"] == "weights incompatible"
    assert json.loads(output.read_text())["passes"] == []


def fake_library(tmp_path):
    clock = SimpleNamespace(now=0)
    loaded = set()

    def load(path_or_hf_repo, dtype=None):
        clock.now += 5
        loaded.add(path_or_hf_repo)
        return "original load result"

    load_module = SimpleNamespace(_load_model_with_resolved_path=load)
    model, aligner_path = tmp_path / "model", tmp_path / "aligner"

    class Backend:
        def align(self, audio, text, language):
            clock.now += 7
            if text == "align failure":
                raise RuntimeError("alignment failed")
            return ["original aligned result"]

    class Aligner:
        def _ensure_loaded(self):
            clock.now += 1
            if str(aligner_path) not in loaded:
                load_module._load_model_with_resolved_path(str(aligner_path), dtype="original dtype")

        def align(self, audio, text, language):
            self._ensure_loaded()
            return Backend().align(audio, text, language)

    class Session:
        def transcribe(self, audio, *, on_progress=None, **kwargs):
            on_progress({"event": "chunk_started"})
            clock.now += 11
            if audio == "decode failure":
                raise RuntimeError("decode failed")
            assert Aligner().align(audio, audio, "English") == ["original aligned result"]
            on_progress({"event": "chunk_completed"})
            return SimpleNamespace(chunks=[{"text": "kept", "truncated": True, "finish_reason": "length", "generated_tokens": 12}])

    return clock, model, aligner_path, Session, Aligner, Backend, load_module


def test_probe_separates_recognition_alignment_and_actual_cached_model_load(tmp_path):
    clock, model, aligner, session, aligner_type, backend, loader = fake_library(tmp_path)
    original = session.transcribe
    probe = bench.LibraryProbe(model, aligner, clock_ns=lambda: clock.now)
    probe.install(session, aligner_type, backend, loader)
    events = []
    try:
        with probe.measure() as initialization:
            assert loader._load_model_with_resolved_path(str(model), dtype="dtype") == "original load result"
        with probe.measure() as first:
            result = session().transcribe("speech", return_timestamps=True, diarize=False, on_progress=events.append)
        with probe.measure() as repeat:
            session().transcribe("speech", return_timestamps=True, diarize=False)
        first_spans = {item["phase"]: item for item in first["spans"]}
        assert first_spans["asr_features_generation_parse"]["duration_ns"] == 11
        assert first_spans["forced_alignment_inference"]["duration_ns"] == 7
        assert first_spans["forced_aligner_model_load"]["duration_ns"] == 5
        assert first_spans["forced_alignment_total"]["duration_ns"] == 13
        assert initialization["spans"][0]["phase"] == "asr_model_load"
        assert "forced_aligner_model_load" not in [item["phase"] for item in repeat["spans"]]
        assert result.chunks[0]["truncated"] is True
        assert first["generation_chunks"][0]["truncated"] is True
        assert len(events) == 2
        assert first["session_options"][0]["return_timestamps"] is True
        assert all(item["outcome"] == "completed" for item in first["spans"])
        assert "origin_ns" not in first
    finally:
        probe.restore()
    assert session.transcribe is original


@pytest.mark.parametrize("audio,phase,message", [
    ("decode failure", "asr_features_generation_parse", "decode failed"),
    ("align failure", "forced_alignment_total", "alignment failed"),
])
def test_probe_preserves_exceptions_and_marks_failed_phase(tmp_path, audio, phase, message):
    clock, model, aligner, session, aligner_type, backend, loader = fake_library(tmp_path)
    probe = bench.LibraryProbe(model, aligner, clock_ns=lambda: clock.now)
    probe.install(session, aligner_type, backend, loader)
    try:
        with probe.measure() as result:
            with pytest.raises(RuntimeError, match=message):
                session().transcribe(audio)
        spans = {item["phase"]: item for item in result["spans"]}
        assert spans[phase]["outcome"] == "failed"
    finally:
        probe.restore()


def test_worker_sets_candidate_before_runtime_import_and_keeps_sources_read_only(tmp_path, monkeypatch):
    audio, reference = make_input(tmp_path)
    model = model_dir(tmp_path / "candidate")
    aligner = model_dir(tmp_path / "models/qwen3-asr/Qwen3-ForcedAligner-0.6B")
    config = tmp_path / "asr.json"
    config.write_text(json.dumps({"asr": {"engine": "qwen-mlx", "modelDir": str(tmp_path / "models"), "vadEnabled": False}}))
    runtime = tmp_path / "runtime"
    for relative in ("scripts/transcriber.py", "insightkit/phase_timing.py"):
        source = runtime / relative
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_text("# Never executed by this fake test.\n")
    transcriber = SimpleNamespace(
        __file__=str(runtime / "scripts/transcriber.py"),
        _resolve_qwen_mlx_source=lambda: bench.os.environ["INSIGHTKIT_QWEN_MLX_MODEL_PATH"],
        _resolve_qwen_forced_aligner_source=lambda: str(aligner),
        _load_qwen_mlx_session=lambda: None, transcribe_audio_chunk=lambda *args, **kwargs: [],
    )
    timing = SimpleNamespace(__file__=str(runtime / "insightkit/phase_timing.py"), **vars(FAKE_TIMING))
    modules = {"scripts.transcriber": transcriber, "insightkit.phase_timing": timing,
               "mlx_qwen3_asr.session": SimpleNamespace(Session=None),
               "mlx_qwen3_asr.forced_aligner": SimpleNamespace(ForcedAligner=None, _MLXForcedAlignerBackend=None),
               "mlx_qwen3_asr.load_models": None}

    def import_module(name):
        assert all(bench.os.environ[key] == str(model) for key in bench.MODEL_KEYS)
        assert bench.os.environ["INSIGHTKIT_QWEN_MLX_MODEL_PATH"] == str(model)
        assert bench.os.environ["HF_HUB_OFFLINE"] == "1"
        return modules[name]

    monkeypatch.setattr(bench.os, "environ", dict(bench.os.environ, INSIGHTKIT_QWEN_MLX_MODEL_PATH="/baseline"))
    monkeypatch.setattr(bench.importlib, "import_module", import_module)
    monkeypatch.setattr(bench.importlib.metadata, "version", lambda name: "fake")
    monkeypatch.setattr(bench.platform, "platform", lambda: "fake-platform")
    monkeypatch.setattr(bench.subprocess, "run", lambda *args, **kwargs: SimpleNamespace(stdout="accepted-head\n", returncode=0))
    monkeypatch.setattr(bench.LibraryProbe, "install", lambda *args: None)
    monkeypatch.setattr(sys, "path", list(sys.path))
    output = tmp_path / "worker.json"
    config_before = config.read_bytes()
    args = SimpleNamespace(runtime_root=runtime, model=str(model), input=audio, reference=reference, runtime_config=config, output=output)
    assert bench.worker(args) == 0
    saved = json.loads(output.read_text())
    assert saved["runtime"]["asr_model_path"] == str(model)
    assert saved["runtime"]["runtime_git_revision"] == "accepted-head"
    assert saved["runtime"]["environment"]["INSIGHTKIT_VAD_ENABLED"] == "0"
    assert config.read_bytes() == config_before
    assert len(saved["passes"]) == 2


def test_driver_retains_partial_json_and_logs_on_timeout_without_retry(tmp_path, monkeypatch):
    output = tmp_path / "result.json"
    args = SimpleNamespace(runtime_root=tmp_path, model="owner/model", input=tmp_path / "audio.wav",
                           reference=tmp_path / "ref.json", runtime_config=None, output=output, timeout_seconds=10)
    calls = []

    def timeout(command, **kwargs):
        calls.append(command)
        assert command[0] == sys.executable
        assert "--worker" in command
        assert kwargs["env"]["HF_HUB_OFFLINE"] == "1"
        bench.write_report(output, {"status": "running", "passes": [{"chunks": [{"text": "retained"}]}]})
        kwargs["stderr"].write("failure evidence\n")
        raise subprocess.TimeoutExpired(command, kwargs["timeout"])

    monkeypatch.setattr(bench.subprocess, "run", timeout)
    assert bench.driver(args) == 1
    saved = json.loads(output.read_text())
    assert saved["status"] == "failed"
    assert saved["passes"][0]["chunks"][0]["text"] == "retained"
    assert saved["process"]["timed_out"] is True
    assert Path(saved["process"]["stderr_path"]).read_text() == "failure evidence\n"
    assert len(calls) == 1
    with pytest.raises(ValueError, match="overwrite"):
        bench.driver(args)
