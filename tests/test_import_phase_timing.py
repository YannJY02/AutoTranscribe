"""Deterministic import timing contracts; no models, network, or native app."""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import json
import sqlite3
import threading
from types import SimpleNamespace
from unittest import mock

import pytest

from insightkit import phase_timing as timing
from insightkit.ipc import job_queue
from insightkit.phase_timing import Phase, TimingRecorder, current_timing, phase, timing_context
from scripts import transcription_runner as runner

pytestmark = pytest.mark.unit


class ManualClock:
    def __init__(self, value: int = 1_000_000):
        self.value = value
        self.lock = threading.Lock()

    def __call__(self) -> int:
        with self.lock:
            return self.value

    def advance(self, nanoseconds: int) -> None:
        with self.lock:
            self.value += nanoseconds


def span_named(snapshot: dict, name: Phase) -> dict:
    matches = [span for span in snapshot["spans"] if span["phase"] == name.value]
    assert len(matches) == 1, snapshot
    return matches[0]


def assert_snapshot_consistent(snapshot: dict) -> None:
    assert set(snapshot) == {"schema_version", "job_id", "clock", "sampled_offset_ns", "spans"}
    assert snapshot["clock"] == "monotonic_ns"
    for span in snapshot["spans"]:
        assert set(span) == {"phase", "start_offset_ns", "end_offset_ns", "duration_ns", "outcome"}
        assert span["phase"] in {name.value for name in Phase}
        end = span["end_offset_ns"]
        if end is None:
            assert span["outcome"] == "running"
            end = snapshot["sampled_offset_ns"]
        else:
            assert span["outcome"] in {"completed", "failed", "cancelled", "skipped"}
        assert 0 <= span["start_offset_ns"] <= end <= snapshot["sampled_offset_ns"]
        assert span["duration_ns"] == end - span["start_offset_ns"]


@pytest.fixture
def runner_env(tmp_path, monkeypatch):
    media = tmp_path / "PRIVATE_FILENAME_SENTINEL.wav"
    media.write_bytes(b"synthetic input; never decoded")
    records_root = tmp_path / "Records"
    monkeypatch.setenv("INSIGHTKIT_RECORDS_ROOT", str(records_root))
    package = {
        "session_overview": {"title": "Synthetic", "overview": "Synthetic", "topics": []},
        "highlight_insights": [], "speaker_perspectives": [], "decision_ledger": [],
        "action_tracks": [], "timeline_beats": [], "provenance_links": [],
    }
    asr_result = {"segments": [{
        "start": 0, "end": 1000, "speaker": "SPEAKER_00", "text": "PRIVATE_BODY_SENTINEL",
    }]}
    transcribe = mock.Mock(return_value=asr_result)
    monkeypatch.setattr(runner, "transcribe", transcribe)
    writer = mock.Mock()
    writer.write_record.return_value = records_root / "synthetic-record"
    monkeypatch.setattr(runner, "RecordWriter", lambda: writer)
    service = mock.Mock()
    service.build_final.return_value = package
    service.build_local_extractive.return_value = package
    service.last_call_meta = {"vendor": "synthetic", "model": "PRIVATE_MODEL_SENTINEL", "strict_mode": False}
    return SimpleNamespace(
        media=media, store=mock.Mock(), service=service, writer=writer,
        transcribe=transcribe, asr_result=asr_result, package=package, clock=ManualClock(),
    )


@pytest.fixture
def queue_env(runner_env, monkeypatch):
    watch = mock.Mock()
    watch.status.return_value = {"state": "stopped"}
    queue = job_queue.JobQueue(
        store=runner_env.store, insight_service=runner_env.service, watch_bridge=watch,
    )
    monkeypatch.setattr(queue, "_ensure_worker_locked", lambda: None)
    monkeypatch.setattr(
        job_queue, "TimingRecorder", lambda job_id: TimingRecorder(job_id, clock_ns=runner_env.clock),
    )

    def unexpected_idle(_seconds):
        raise AssertionError("synchronous test queue reached idle before its runner stopped it")

    monkeypatch.setattr(job_queue, "time", SimpleNamespace(**{**vars(job_queue.time), "sleep": unexpected_idle}))
    runner_env.queue = queue
    try:
        yield runner_env
    finally:
        queue.shutdown()


def enqueue(env, **params):
    return env.queue.transcription_import_file({"file_path": str(env.media), **params})["job_id"]


def view_of(queue, job_id):
    return next(row for row in queue.transcription_status({})["jobs"] if row["id"] == job_id)


def run_direct(env, **kwargs):
    return runner.run_transcription_job(
        file_path=str(env.media), meeting_id="synthetic-meeting",
        store=env.store, insight_service=env.service, **kwargs,
    )


def run_one_queued_job(env, monkeypatch):
    # Exercise the real runner/context, while stopping the synchronous queue
    # loop after this job, including exception paths. No polling or sleep.
    def invoke(**kwargs):
        try:
            return runner.run_transcription_job(**kwargs)
        finally:
            env.queue._worker_stop.set()

    monkeypatch.setattr(job_queue, "run_transcription_job", invoke)
    env.queue._worker_loop()


def test_default_clock_and_finished_durations_are_monotonic(monkeypatch):
    clock = ManualClock()
    wall_clock = mock.Mock(side_effect=[1000.0, -1000.0])
    # Replace this module's clock namespace, not the shared time module used
    # by threading, so a failed assertion cannot disrupt unrelated tests.
    monkeypatch.setattr(timing, "time", SimpleNamespace(monotonic_ns=clock, time=wall_clock))
    recorder = TimingRecorder("job-clock")
    clock.advance(7)
    span = recorder.start(Phase.TRANSCRIPTION)
    assert wall_clock() == 1000.0
    clock.advance(11)
    running = recorder.snapshot()
    assert wall_clock() == -1000.0
    assert running["spans"][0]["duration_ns"] == 11
    clock.advance(13)
    span.finish()
    clock.advance(100)
    span.finish("failed")  # Terminal spans are immutable, including outcome.
    final = recorder.snapshot()
    assert final["spans"] == [{
        "phase": "transcription", "start_offset_ns": 7, "end_offset_ns": 31,
        "duration_ns": 24, "outcome": "completed",
    }]
    assert_snapshot_consistent(final)


def test_snapshot_is_detached_and_running_duration_freezes_on_finish():
    clock = ManualClock()
    recorder = TimingRecorder("job-copy", clock_ns=clock)
    span = recorder.start(Phase.RECORD_WRITE)
    clock.advance(5)
    original = recorder.snapshot()
    altered = recorder.snapshot()
    altered["spans"][0]["phase"] = "private mutation"
    altered["spans"].append({"unexpected": "entry"})
    altered["job_id"] = "different-job"
    clock.advance(7)
    span.finish("cancelled")
    assert original["spans"][0]["end_offset_ns"] is None
    assert original["spans"][0]["duration_ns"] == 5
    final = recorder.snapshot()
    assert final["job_id"] == "job-copy"
    assert final["spans"][0]["phase"] == "record_write"
    assert final["spans"][0]["duration_ns"] == 12
    assert len(final["spans"]) == 1
    assert_snapshot_consistent(final)


def test_context_restores_after_nested_failure_and_without_recorder():
    first = TimingRecorder("first", clock_ns=ManualClock())
    second = TimingRecorder("second", clock_ns=ManualClock())
    assert current_timing() is None
    with timing_context(first):
        with pytest.raises(ValueError, match="synthetic failure"):
            with timing_context(second), phase(Phase.TRANSCRIPTION):
                raise ValueError("synthetic failure")
        assert current_timing() is first
        with timing_context(None), phase(Phase.RECORD_WRITE):
            assert current_timing() is None
        with phase(Phase.PERSIST_FINAL):
            pass
    assert current_timing() is None
    assert [s["phase"] for s in first.snapshot()["spans"]] == ["persist_final"]
    assert span_named(second.snapshot(), Phase.TRANSCRIPTION)["outcome"] == "failed"


def test_invalid_vocabulary_and_foreign_intervals_do_not_enter_snapshot():
    clock = ManualClock()
    recorder = TimingRecorder("fixed-vocabulary", clock_ns=clock)
    with pytest.raises(ValueError):
        recorder.start("PRIVATE_PATH_SENTINEL")
    with pytest.raises(ValueError):
        recorder.record_interval(Phase.TRANSCRIPTION, 999_999, 1_000_010, "completed")
    with pytest.raises(ValueError):
        recorder.record_interval(Phase.TRANSCRIPTION, 1_000_010, 1_000_009, "completed")
    with pytest.raises(ValueError):
        recorder.record_interval(Phase.TRANSCRIPTION, 1_000_000, 1_000_010, "PRIVATE_ERROR_SENTINEL")
    assert recorder.snapshot()["spans"] == []
    clock.advance(20)
    recorder.record_interval(Phase.QWEN_SESSION_INITIALIZE, 1_000_002, 1_000_009, "completed")
    assert recorder.snapshot()["spans"][0]["duration_ns"] == 7


def test_snapshots_remain_consistent_while_another_thread_finishes_spans():
    clock = ManualClock()
    recorder = TimingRecorder("parallel-snapshots", clock_ns=clock)
    opened = threading.Barrier(2, timeout=3)
    release = threading.Barrier(2, timeout=3)
    snapshots = []

    def write_spans():
        for _ in range(12):
            span = recorder.start(Phase.TRANSCRIPTION)
            clock.advance(2)
            opened.wait()
            release.wait()
            clock.advance(3)
            span.finish()

    with ThreadPoolExecutor(max_workers=1) as executor:
        future = executor.submit(write_spans)
        try:
            for _ in range(12):
                opened.wait()
                snapshots.append(recorder.snapshot())
                assert snapshots[-1]["spans"][-1]["outcome"] == "running"
                release.wait()
                # This read may overlap finish/start on the writer thread.
                snapshots.append(recorder.snapshot())
        except BaseException:
            # A failing main-thread assertion must not strand the writer.
            opened.abort()
            release.abort()
            raise
        future.result(timeout=3)
    for snapshot in snapshots:
        assert_snapshot_consistent(snapshot)
    final = recorder.snapshot()
    assert len(final["spans"]) == 12
    assert all(s["outcome"] == "completed" and s["duration_ns"] == 5 for s in final["spans"])


def test_runner_records_actual_stage_work_and_preserves_legacy_result(runner_env):
    env = runner_env
    recorder = TimingRecorder("direct", clock_ns=env.clock)

    def timed_result(duration, value):
        def call(*_args, **_kwargs):
            env.clock.advance(duration)
            return value
        return call

    env.transcribe.side_effect = timed_result(11, env.asr_result)
    env.store.insert_segment.side_effect = timed_result(13, None)
    env.service.build_final.side_effect = timed_result(17, env.package)
    env.store.upsert_insight_package.side_effect = timed_result(19, None)
    env.writer.write_record.side_effect = timed_result(23, env.writer.write_record.return_value)
    progress = []
    with timing_context(recorder):
        result = run_direct(env, on_progress=lambda value, stage: progress.append((value, stage)))
    assert set(result) == {"meeting_id", "title", "source_path", "segments_count", "insight_package", "record_path"}
    assert result["segments_count"] == 1
    assert result["source_path"] == str(env.media.resolve())
    assert progress == [(5, "starting"), (25, "transcribing"), (60, "persisting"), (82, "building_final"), (100, "completed")]
    assert [(s["phase"], s["duration_ns"], s["outcome"]) for s in recorder.snapshot()["spans"]] == [
        ("transcription", 11, "completed"), ("persist_segments", 13, "completed"),
        ("final_generation", 17, "completed"), ("persist_final", 19, "completed"),
        ("record_write", 23, "completed"),
    ]
    saved = recorder.snapshot()
    uninstrumented = run_direct(env)  # No new argument or timing context required.
    assert set(uninstrumented) == set(result)
    assert recorder.snapshot()["spans"] == saved["spans"]
    assert current_timing() is None


def test_failed_final_generation_is_retained_when_fallback_succeeds(runner_env):
    env = runner_env
    env.service.build_final.side_effect = RuntimeError("synthetic provider unavailable")
    recorder = TimingRecorder("fallback", clock_ns=env.clock)
    with timing_context(recorder):
        result = run_direct(env)
    assert result["record_path"]
    snapshot = recorder.snapshot()
    assert span_named(snapshot, Phase.FINAL_GENERATION)["outcome"] == "failed"
    assert span_named(snapshot, Phase.FINAL_GENERATION_FALLBACK)["outcome"] == "completed"
    assert span_named(snapshot, Phase.RECORD_WRITE)["outcome"] == "completed"
    env.service.build_local_extractive.assert_called_once()


@pytest.mark.parametrize("failure_stage", ["transcription", "record_write"])
def test_job_failure_keeps_completed_and_failed_spans(queue_env, monkeypatch, failure_stage):
    env = queue_env
    failing_call = env.transcribe if failure_stage == "transcription" else env.writer.write_record
    failing_call.side_effect = RuntimeError("synthetic failure")
    job_id = enqueue(env)
    run_one_queued_job(env, monkeypatch)
    row = view_of(env.queue, job_id)
    assert row["state"] == "failed"
    assert row["error"] == "synthetic failure"
    snapshot = row["phase_timings"]
    assert span_named(snapshot, Phase.JOB_EXECUTION)["outcome"] == "failed"
    assert span_named(snapshot, Phase(failure_stage))["outcome"] == "failed"
    assert span_named(snapshot, Phase.QUEUE_WAIT)["outcome"] == "completed"
    assert all(s["end_offset_ns"] is not None for s in snapshot["spans"])
    if failure_stage == "transcription":
        env.service.build_final.assert_not_called()
        env.writer.write_record.assert_not_called()
    else:
        assert span_named(snapshot, Phase.TRANSCRIPTION)["outcome"] == "completed"
        assert span_named(snapshot, Phase.PERSIST_FINAL)["outcome"] == "completed"
    assert current_timing() is None


def test_initial_worker_persistence_failure_closes_execution_before_reraising(queue_env, monkeypatch):
    env = queue_env
    job_id = enqueue(env)
    env.clock.advance(5)
    failure = sqlite3.OperationalError("synthetic database write failure")

    def fail_running_state_write(_job):
        env.clock.advance(11)
        raise failure

    persist = mock.Mock(side_effect=fail_running_state_write)
    invoke_runner = mock.Mock()
    monkeypatch.setattr(env.queue, "_persist_job_locked", persist)
    monkeypatch.setattr(job_queue, "run_transcription_job", invoke_runner)

    with pytest.raises(sqlite3.OperationalError) as raised:
        env.queue._worker_loop()
    assert raised.value is failure
    persist.assert_called_once()
    invoke_runner.assert_not_called()

    recorder = env.queue._jobs[job_id]["_phase_timing"]
    first = recorder.snapshot()
    assert span_named(first, Phase.QUEUE_WAIT) == {
        "phase": "queue_wait", "start_offset_ns": 0, "end_offset_ns": 5,
        "duration_ns": 5, "outcome": "completed",
    }
    assert span_named(first, Phase.JOB_EXECUTION) == {
        "phase": "job_execution", "start_offset_ns": 5, "end_offset_ns": 16,
        "duration_ns": 11, "outcome": "failed",
    }
    for elapsed in (100, 200):
        env.clock.advance(elapsed)
        later = recorder.snapshot()
        assert later["spans"] == first["spans"]
        assert_snapshot_consistent(later)


def test_queued_cancellation_closes_wait_without_inventing_execution(queue_env):
    env = queue_env
    job_id = enqueue(env)
    env.clock.advance(29)
    assert env.queue.transcription_cancel_job({"job_id": job_id})["state"] == "cancelled"
    row = view_of(env.queue, job_id)
    assert row["state"] == "cancelled"
    assert row["phase_timings"]["spans"] == [{
        "phase": "queue_wait", "start_offset_ns": 0, "end_offset_ns": 29,
        "duration_ns": 29, "outcome": "cancelled",
    }]
    assert env.queue.transcription_status({})["queue"] == []
    env.transcribe.assert_not_called()


@pytest.mark.parametrize("reason, expected_state", [("", "cancelled"), ("preempted_by_live", "paused_by_live")])
def test_cancel_request_does_not_close_running_work_before_it_returns(queue_env, monkeypatch, reason, expected_state):
    env = queue_env
    job_id = enqueue(env)
    at_request = []

    def finish_asr_after_cancel(_path):
        env.clock.advance(5)
        env.queue.transcription_cancel_job({"job_id": job_id, "reason": reason})
        at_request.append(view_of(env.queue, job_id))
        env.clock.advance(11)
        return env.asr_result

    env.transcribe.side_effect = finish_asr_after_cancel
    run_one_queued_job(env, monkeypatch)
    pending = at_request[0]
    assert pending["state"] == expected_state
    assert span_named(pending["phase_timings"], Phase.JOB_EXECUTION)["outcome"] == "running"
    final = view_of(env.queue, job_id)
    assert final["state"] == expected_state
    execution = span_named(final["phase_timings"], Phase.JOB_EXECUTION)
    assert execution["outcome"] == "cancelled"
    assert execution["end_offset_ns"] > pending["phase_timings"]["sampled_offset_ns"]
    assert span_named(final["phase_timings"], Phase.TRANSCRIPTION)["outcome"] == "completed"
    assert span_named(final["phase_timings"], Phase.TRANSCRIPTION)["duration_ns"] == 16
    assert all(s["end_offset_ns"] is not None for s in final["phase_timings"]["spans"])
    env.store.insert_segment.assert_not_called()
    env.service.build_final.assert_not_called()
    env.writer.write_record.assert_not_called()


def test_two_jobs_are_isolated_and_last_completed_has_finished_timings(queue_env, monkeypatch):
    env = queue_env
    first = enqueue(env, meeting_id="same-meeting")
    env.clock.advance(2)
    second = enqueue(env, meeting_id="same-meeting")
    observed = []
    calls = 0

    def fake_runner(*, file_path, meeting_id, store, insight_service, cancel_event, on_progress,
                    provider_vendor, provider_model, strict_mode):
        # An explicit legacy signature fails if queue adds a timing kwarg.
        nonlocal calls
        calls += 1
        if calls == 2:
            env.queue._worker_stop.set()
        recorder = current_timing()
        assert recorder is not None
        observed.append(recorder.snapshot()["job_id"])
        with phase(Phase.TRANSCRIPTION):
            env.clock.advance(7 if len(observed) == 1 else 13)
            if len(observed) == 1:
                raise RuntimeError("first job failed")
        on_progress(100, "completed")
        return {"meeting_id": meeting_id, "segments_count": 1, "record_path": "synthetic-record"}

    monkeypatch.setattr(job_queue, "run_transcription_job", fake_runner)
    env.queue._worker_loop()
    assert observed == [first, second]
    first_row, second_row = view_of(env.queue, first), view_of(env.queue, second)
    assert (first_row["state"], second_row["state"]) == ("failed", "completed")
    assert first_row["phase_timings"]["job_id"] == first
    assert second_row["phase_timings"]["job_id"] == second
    assert span_named(first_row["phase_timings"], Phase.TRANSCRIPTION)["duration_ns"] == 7
    assert span_named(second_row["phase_timings"], Phase.TRANSCRIPTION)["duration_ns"] == 13
    assert span_named(second_row["phase_timings"], Phase.JOB_EXECUTION)["outcome"] == "completed"
    status = env.queue.transcription_status({})
    assert status["active_job"] is None and status["queue"] == []
    assert span_named(status["last_completed"]["job"]["phase_timings"], Phase.JOB_EXECUTION)["outcome"] == "completed"
    json.dumps(status)
    assert current_timing() is None


def test_legacy_job_view_omits_timing_objects_and_status_remains_serializable(queue_env):
    queue = queue_env.queue
    legacy = {
        "id": "legacy", "meeting_id": "legacy-meeting", "source_path": "/synthetic/old.wav",
        "title": "old", "state": "queued", "progress": 0, "stage": "queued",
        "error": "", "reason": "", "started_at": "2026-01-01T00:00:00Z", "ended_at": "",
    }
    queue._jobs["legacy"] = legacy
    queue._queue.append("legacy")
    assert queue._job_view(legacy) == legacy
    new_id = enqueue(queue_env)
    status = json.loads(json.dumps(queue.transcription_status({})))
    assert set(status) == {"watcher", "queue", "active_job", "last_completed", "jobs"}
    old_view = next(row for row in status["jobs"] if row["id"] == "legacy")
    assert old_view == legacy
    new_view = next(row for row in status["jobs"] if row["id"] == new_id)
    assert "phase_timings" in new_view
    assert not any(key.startswith("_") for key in new_view)
    assert_snapshot_consistent(new_view["phase_timings"])


def test_timing_data_excludes_paths_content_provider_and_exception_messages(queue_env, monkeypatch):
    env = queue_env
    private_values = [str(env.media), "PRIVATE_FILENAME_SENTINEL", "PRIVATE_BODY_SENTINEL",
                      "PRIVATE_TITLE_SENTINEL", "PRIVATE_MEETING_SENTINEL", "PRIVATE_MODEL_SENTINEL",
                      "PRIVATE_ERROR_SENTINEL"]
    env.transcribe.side_effect = RuntimeError(f"{env.media}: PRIVATE_BODY_SENTINEL PRIVATE_ERROR_SENTINEL")
    job_id = enqueue(env, title="PRIVATE_TITLE_SENTINEL", meeting_id="PRIVATE_MEETING_SENTINEL",
                     provider_model="PRIVATE_MODEL_SENTINEL")
    run_one_queued_job(env, monkeypatch)
    row = view_of(env.queue, job_id)
    # Legacy status still reports the source/error. Only the new telemetry
    # contract is content-free; this change does not redefine existing APIs.
    assert row["source_path"] == str(env.media.resolve())
    assert "PRIVATE_ERROR_SENTINEL" in row["error"]
    snapshot = row["phase_timings"]
    assert_snapshot_consistent(snapshot)
    encoded = json.dumps(snapshot)
    assert all(value not in encoded for value in private_values)
    assert snapshot["job_id"] == job_id
