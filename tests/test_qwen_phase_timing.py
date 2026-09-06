"""Qwen timing boundaries with fake sessions, controlled clocks and real workers."""

import json
import threading
from pathlib import Path
from types import SimpleNamespace

import pytest

from insightkit.phase_timing import Phase, TimingRecorder, current_timing, timing_context
from scripts import transcriber


class ManualClock:
    def __init__(self):
        self._now = 1_000
        self._lock = threading.Lock()

    def __call__(self):
        with self._lock:
            return self._now

    def advance(self, duration):
        with self._lock:
            self._now += duration


@pytest.fixture
def clock(monkeypatch):
    transcriber._reset_runtime_state_for_tests()
    clock = ManualClock()
    monkeypatch.setattr(transcriber.time, "monotonic_ns", clock)
    monkeypatch.setattr(transcriber, "ASR_ENGINE", "qwen-mlx")
    monkeypatch.setattr(transcriber, "DIARIZATION_ENABLED", False)
    monkeypatch.setattr(transcriber, "QWEN_MLX_RETURN_TIMESTAMPS", False)
    monkeypatch.setattr(transcriber, "_resolve_qwen_mlx_source", lambda: "/private/model-source")
    monkeypatch.setattr(transcriber, "_speech_exists", lambda _path: True)
    monkeypatch.setattr(transcriber, "_mark_warm_ready", lambda: None)
    yield clock
    workers = list(transcriber._models.values())
    transcriber._reset_runtime_state_for_tests()
    for worker in workers:
        worker._thread.join(timeout=3)
        assert not worker._thread.is_alive(), "owned fake Qwen worker did not stop"


def result(text="private-transcript", speaker=""):
    return SimpleNamespace(
        language="en", speaker_segments=[], chunks=[],
        segments=[{"start": 0.0, "end": 1.0, "text": text, "speaker": speaker}],
        text=text,
    )


def spans(recorder):
    rows = recorder.snapshot()["spans"]
    assert len({row["phase"] for row in rows}) == len(rows)
    assert all(row["end_offset_ns"] is not None for row in rows)
    return {row["phase"]: row for row in rows}


def start_call(recorder, operation):
    values, errors = [], []

    def call():
        try:
            with timing_context(recorder):
                values.append(operation())
        except BaseException as exc:
            errors.append(exc)

    thread = threading.Thread(target=call, daemon=True)
    thread.start()
    return thread, values, errors


def join_call(thread):
    thread.join(timeout=3)
    assert not thread.is_alive(), "fake Qwen request did not finish"


def install_session(monkeypatch, clock, transcribe=None):
    class FakeSession:
        def __init__(self, _source):
            self.owner = threading.get_ident()
            clock.advance(7)

        def transcribe(self, **kwargs):
            assert threading.get_ident() == self.owner
            assert current_timing() is None, "worker must receive request timing explicitly"
            assert not {"recorder", "timing", "on_phase", "job_id"}.intersection(kwargs)
            if transcribe is not None:
                return transcribe(kwargs)
            clock.advance(11)
            return result()

    monkeypatch.setattr(transcriber, "_create_qwen_mlx_session", FakeSession)


def install_audio(monkeypatch, clock, tmp_path):
    prepared = tmp_path / "prepared-private.wav"
    prepared.write_bytes(b"fake audio; no decoder is used")

    def extract(_path):
        clock.advance(3)
        return prepared

    def duration(_path):
        clock.advance(5)
        return 1.0

    def speech(_path):
        clock.advance(2)
        return True

    monkeypatch.setattr(transcriber, "extract_audio", extract)
    monkeypatch.setattr(transcriber, "_get_audio_duration", duration)
    monkeypatch.setattr(transcriber, "_speech_exists", speech)
    return prepared


def test_import_qwen_phase_boundaries_and_timing_privacy(monkeypatch, clock, tmp_path):
    install_session(monkeypatch, clock)
    prepared = install_audio(monkeypatch, clock, tmp_path)
    private_path = tmp_path / "private-meeting.m4a"
    recorder = TimingRecorder("job-import", clock_ns=clock)
    with timing_context(recorder):
        payload = transcriber.transcribe(private_path)

    assert payload["duration"] == 1.0
    assert payload["segments"][0]["text"] == "private-transcript"
    assert not prepared.exists()
    measured = spans(recorder)
    assert {name: row["duration_ns"] for name, row in measured.items()} == {
        "audio_preparation": 8,
        "speech_detection": 2,
        "qwen_session_ready": 7,
        "qwen_session_initialize": 7,
        "qwen_worker_wait": 0,
        "qwen_session_transcribe": 11,
        "segment_conversion": 0,
        "speaker_attachment": 0,
    }
    assert measured["speaker_attachment"]["outcome"] == "skipped"
    assert all(row["outcome"] == "completed" for name, row in measured.items() if name != "speaker_attachment")
    snapshot = recorder.snapshot()
    assert set(snapshot) == {"schema_version", "job_id", "clock", "sampled_offset_ns", "spans"}
    assert all(set(row) == {
        "phase", "start_offset_ns", "end_offset_ns", "duration_ns", "outcome",
    } for row in snapshot["spans"])
    serialized = json.dumps(snapshot)
    for private_value in (str(private_path), str(prepared), "/private/model-source", "private-transcript"):
        assert private_value not in serialized


def test_initialization_failure_keeps_receipt_and_original_exception(monkeypatch, clock):
    initialized = threading.Event()
    queued = threading.Event()
    release = threading.Event()
    failure = RuntimeError("private initialization detail")
    original_queue = transcriber.queue.Queue

    class ObservedQueue(original_queue):
        def put(self, item, *args, **kwargs):
            super().put(item, *args, **kwargs)
            if item is not None and item[0] == "warm":
                queued.set()

    def fail_initialization(_source):
        initialized.set()
        assert release.wait(timeout=3)
        clock.advance(13)
        raise failure

    monkeypatch.setattr(transcriber.queue, "Queue", ObservedQueue)
    monkeypatch.setattr(transcriber, "_create_qwen_mlx_session", fail_initialization)
    recorder = TimingRecorder("job-failed-init", clock_ns=clock)
    thread, values, errors = start_call(recorder, transcriber._load_qwen_mlx_session)
    try:
        assert initialized.wait(timeout=3)
        assert queued.wait(timeout=3)
    finally:
        release.set()
        join_call(thread)

    assert values == []
    assert errors == [failure]
    measured = spans(recorder)
    assert set(measured) == {"qwen_session_ready", "qwen_session_initialize"}
    assert all(row["outcome"] == "failed" and row["duration_ns"] == 13 for row in measured.values())
    assert "private initialization detail" not in json.dumps(recorder.snapshot())


def test_prewarmed_session_has_ready_wait_without_reassigned_initialization(monkeypatch, clock):
    install_session(monkeypatch, clock)
    worker = transcriber._load_qwen_mlx_session()
    clock.advance(19)
    recorder = TimingRecorder("job-reuse", clock_ns=clock)
    with timing_context(recorder):
        assert transcriber._load_qwen_mlx_session() is worker
        assert transcriber._transcribe_qwen_mlx(Path("/private/audio.wav"))[1]

    rows = recorder.snapshot()["spans"]
    assert not any(row["phase"] == "qwen_session_initialize" for row in rows)
    assert sum(row["phase"] == "qwen_session_ready" for row in rows) == 2
    assert sum(row["phase"] == "qwen_worker_wait" for row in rows) == 1
    assert sum(row["phase"] == "qwen_session_transcribe" for row in rows) == 1
    assert all(row["start_offset_ns"] >= 0 and row["end_offset_ns"] is not None for row in rows)


def test_transcribe_failure_closes_actual_call_without_masking_exception(monkeypatch, clock):
    failure = ValueError("private model output and token")

    def fail(_kwargs):
        clock.advance(17)
        raise failure

    install_session(monkeypatch, clock, transcribe=fail)
    recorder = TimingRecorder("job-failed-call", clock_ns=clock)
    with timing_context(recorder), pytest.raises(ValueError) as raised:
        transcriber._transcribe_qwen_mlx(Path("/private/audio.wav"))

    assert raised.value is failure
    measured = spans(recorder)
    assert measured["qwen_session_initialize"]["outcome"] == "completed"
    assert measured["qwen_worker_wait"]["outcome"] == "completed"
    assert measured["qwen_session_transcribe"]["outcome"] == "failed"
    assert measured["qwen_session_transcribe"]["duration_ns"] == 17
    assert "segment_conversion" not in measured
    assert "speaker_attachment" not in measured
    assert str(failure) not in json.dumps(recorder.snapshot())


def test_parallel_requests_keep_worker_wait_and_call_timings_with_each_job(monkeypatch, clock):
    first_started = threading.Event()
    second_queued = threading.Event()
    release = threading.Event()

    def transcribe(kwargs):
        assert set(kwargs) == {"audio"}
        if kwargs["audio"] == "private-a":
            first_started.set()
            assert release.wait(timeout=3)
            clock.advance(30)
        else:
            assert kwargs["audio"] == "private-b"
            clock.advance(40)
        return kwargs["audio"]

    install_session(monkeypatch, clock, transcribe=transcribe)
    worker = transcriber._load_qwen_mlx_session()
    original_put = worker._requests.put

    def observe_put(item, *args, **kwargs):
        original_put(item, *args, **kwargs)
        if item is not None and item[1].get("audio") == "private-b":
            second_queued.set()

    monkeypatch.setattr(worker._requests, "put", observe_put)
    first = TimingRecorder("job-a", clock_ns=clock)
    second = TimingRecorder("job-b", clock_ns=clock)
    call_a = start_call(first, lambda: worker.transcribe(audio="private-a"))
    call_b = None
    try:
        assert first_started.wait(timeout=3)
        clock.advance(10)
        call_b = start_call(second, lambda: worker.transcribe(audio="private-b"))
        assert second_queued.wait(timeout=3)
        clock.advance(20)
        assert first.snapshot()["spans"][-1]["outcome"] == "running"
        assert second.snapshot()["spans"][-1]["phase"] == "qwen_worker_wait"
    finally:
        release.set()
        join_call(call_a[0])
        if call_b is not None:
            join_call(call_b[0])

    assert call_a[1:] == (["private-a"], [])
    assert call_b[1:] == (["private-b"], [])
    a, b = spans(first), spans(second)
    assert a["qwen_worker_wait"]["duration_ns"] == 0
    assert a["qwen_session_transcribe"]["duration_ns"] == 60
    assert b["qwen_worker_wait"]["duration_ns"] == 50
    assert b["qwen_session_transcribe"]["duration_ns"] == 40
    assert set(a) == set(b) == {"qwen_worker_wait", "qwen_session_transcribe"}
    assert first.snapshot()["job_id"] == "job-a"
    assert second.snapshot()["job_id"] == "job-b"


def test_legacy_call_without_diagnostics_keeps_result_and_skip_behavior(monkeypatch, clock, tmp_path):
    install_session(monkeypatch, clock)
    install_audio(monkeypatch, clock, tmp_path)
    assert current_timing() is None
    payload = transcriber.transcribe(tmp_path / "legacy.m4a")
    assert payload == {
        "lang": "en",
        "duration": 1.0,
        "segments": [{
            "start": 0, "end": 1000, "text": "private-transcript", "speaker": "", "confidence": 0.0,
        }],
    }


@pytest.mark.parametrize("mode", ["disabled", "empty", "labelled", "attached", "failed"])
def test_speaker_attachment_reports_attempt_or_skip(monkeypatch, clock, mode):
    monkeypatch.setattr(transcriber, "DIARIZATION_ENABLED", mode != "disabled")
    segments = [] if mode == "empty" else [{
        "start": 0, "end": 1000, "text": "private", "speaker": "known" if mode == "labelled" else "",
    }]
    failure = RuntimeError("private speaker detail")

    def diarize(_path):
        assert mode in {"attached", "failed"}
        clock.advance(23)
        if mode == "failed":
            raise failure
        return [(0, 1000, "SPEAKER_00")]

    monkeypatch.setattr(transcriber, "_diarize", diarize)
    recorder = TimingRecorder("job-speakers", clock_ns=clock)
    with timing_context(recorder):
        if mode == "failed":
            with pytest.raises(RuntimeError) as raised:
                transcriber._attach_diarization_labels(Path("/private/audio.wav"), segments)
            assert raised.value is failure
        else:
            attached = transcriber._attach_diarization_labels(Path("/private/audio.wav"), segments)
            if mode == "attached":
                assert attached[0]["speaker"] == "SPEAKER_00"
            else:
                assert attached is segments

    measured = spans(recorder)[Phase.SPEAKER_ATTACHMENT.value]
    expected = "failed" if mode == "failed" else "completed" if mode == "attached" else "skipped"
    assert measured["outcome"] == expected
    assert measured["duration_ns"] == (23 if mode in {"attached", "failed"} else 0)
    assert "private" not in json.dumps(recorder.snapshot())


def test_audio_probe_failure_keeps_elapsed_and_existing_cleanup(monkeypatch, clock, tmp_path):
    prepared = install_audio(monkeypatch, clock, tmp_path)
    failure = RuntimeError("private ffprobe detail")

    def fail_duration(_path):
        clock.advance(29)
        raise failure

    monkeypatch.setattr(transcriber, "_get_audio_duration", fail_duration)
    recorder = TimingRecorder("job-audio-failure", clock_ns=clock)
    with timing_context(recorder), pytest.raises(RuntimeError) as raised:
        transcriber.transcribe(tmp_path / "private.m4a")

    assert raised.value is failure
    assert not prepared.exists()
    measured = spans(recorder)
    assert set(measured) == {"audio_preparation"}
    assert measured["audio_preparation"]["duration_ns"] == 32
    assert measured["audio_preparation"]["outcome"] == "failed"
