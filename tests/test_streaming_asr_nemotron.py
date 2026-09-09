"""Native streaming lifecycle and output semantics without loading ASR weights."""

import ctypes as C
from types import SimpleNamespace

import numpy as np
import pytest

from scripts.streaming_asr_experiment import nemotron
from scripts.streaming_asr_experiment.common import Audio


def result(text, *, final=False):
    return {"text": text, "is_final": final, "audio_processed_seconds": 0.32,
            "confidence": 0.0, "alternatives": 1, "words": [], "languages": ["en-US"]}


class Session:
    def __init__(self):
        self.events = []
        self.frontier = 0

    def pace_to(self, end_frame):
        self.frontier = end_frame
        self.events.append(("pace", end_frame))

    def emit_text(self, text, **fields):
        assert fields["audio_end_frame"] <= self.frontier
        self.events.append(("text", {"text": text, **fields}))

    def record(self, kind, **fields):
        self.events.append((kind, fields))


class FakeAPI:
    def __init__(self, session, *, fail=None, final=True):
        self.session = session
        self.fail, self.has_final = fail, final
        self.recognizers, self.opened, self.closed, self.destroyed = [], [], [], []
        self.pending = []
        self.pushed_frames = 0

    def open_stream(self, recognizer, language):
        assert language == "auto"
        stream = len(self.opened) + 1
        self.recognizers.append(recognizer)
        self.opened.append(stream)
        self.pushed_frames = 0
        return stream

    def push(self, stream, samples):
        self.pushed_frames += len(samples)
        assert self.session.frontier == self.pushed_frames, "audio must be paced before push"
        assert samples.dtype == np.float32 and samples.flags.c_contiguous
        if self.fail == "push":
            raise RuntimeError("fake native push failure")
        text = "hello" if self.pushed_frames == 5120 else "hello world"
        self.pending.append(result(text))

    def pull(self, stream):
        if self.fail == "pull":
            raise RuntimeError("fake native pull failure")
        return self.pending.pop(0) if self.pending else None

    def finish(self, stream):
        if self.fail == "finish":
            raise RuntimeError("fake native finish failure")
        if self.has_final:
            self.pending.append(result("hello world!", final=True))

    def stream_close(self, stream):
        self.closed.append(stream)

    def destroy(self, recognizer):
        self.destroyed.append(recognizer)


def setup_run(*, fail=None, final=True):
    session = Session()
    api = FakeAPI(session, fail=fail, final=final)
    state = nemotron._State(api, C.c_void_p(42), "auto", 320)
    audio = Audio(16000, 10240, b"\x00\x00" * 10240)
    args = SimpleNamespace(latency_ms=320, language="auto", chunk_ms=320)
    return state, audio, session, args


def test_paces_audio_and_replaces_cumulative_partials_with_flushed_final():
    state, audio, session, args = setup_run()
    output = nemotron.run(state, audio, session, args)

    assert output["text"] == "hello world!"
    assert output["native_final_received"] is True
    assert output["native_result_count"] == 3
    texts = [row for kind, row in session.events if kind == "text"]
    assert [row["text"] for row in texts] == ["hello", "hello world", "hello world!"]
    assert all(row["semantics"] == "cumulative" for row in texts)
    assert texts[-1]["is_final"] and texts[-1]["after_finish"]
    assert [row for kind, row in session.events if kind == "pace"] == [5120, 10240]
    kinds = [kind for kind, _row in session.events]
    assert kinds.index("nemotron_finish_started") < kinds.index("nemotron_finish_returned")
    assert state.api.closed == [1]
    assert not state.running


def test_repeat_reuses_model_but_creates_and_closes_new_stream():
    state, audio, session, args = setup_run()
    recognizer = state.recognizer
    nemotron.run(state, audio, session, args)
    second_session = Session()
    state.api.session = second_session
    output = nemotron.run(state, audio, second_session, args)

    assert output["text"] == "hello world!"
    assert state.api.recognizers == [recognizer, recognizer]
    assert state.api.opened == state.api.closed == [1, 2]
    nemotron.close(state)
    nemotron.close(state)
    assert state.api.destroyed == [recognizer]
    with pytest.raises(RuntimeError, match="closed"):
        nemotron.run(state, audio, Session(), args)


@pytest.mark.parametrize("operation", ["push", "pull", "finish"])
def test_native_failure_propagates_and_stream_is_closed(operation):
    state, audio, session, args = setup_run(fail=operation)
    with pytest.raises(RuntimeError, match=f"fake native {operation} failure"):
        nemotron.run(state, audio, session, args)
    assert state.api.closed == [1]
    assert not state.running


def test_missing_flush_final_is_an_error_instead_of_partial_success():
    state, audio, session, args = setup_run(final=False)
    with pytest.raises(RuntimeError, match="without a final result"):
        nemotron.run(state, audio, session, args)
    assert state.api.closed == [1]


def test_synchronous_finish_time_is_included_in_decode_total(monkeypatch):
    state, audio, session, args = setup_run()
    now = [0]
    monkeypatch.setattr(nemotron.time, "monotonic_ns", lambda: now[0])
    finish = state.api.finish

    def delayed_finish(stream):
        now[0] += 17_000_000
        finish(stream)

    state.api.finish = delayed_finish
    output = nemotron.run(state, audio, session, args)
    assert output["native_finish_ms"] == 17
    assert output["native_decode_and_finish_ms"] == 17
    assert output["native_next_ms"] == 0
    receipt = [row for kind, row in session.events if kind == "nemotron_finish_returned"]
    assert receipt == [{"duration_ms": 17, "audio_end_frame": 10240, "outcome": "ok"}]


def test_unsupported_native_latency_fails_before_loading_library(monkeypatch):
    monkeypatch.setattr(nemotron, "_Bindings", lambda *_: pytest.fail("must not load native code"))
    with pytest.raises(ValueError, match="latency_ms"):
        nemotron.load(SimpleNamespace(latency_ms=480, language="auto"), Session())


def test_c_error_is_copied_before_any_cleanup_call():
    bindings = object.__new__(nemotron._Bindings)
    calls = []
    bindings.last_error = lambda: calls.append("last_error") or b"native decoder failed"
    with pytest.raises(RuntimeError, match="stream_next failed with status 3: native decoder failed"):
        bindings.check(3, "stream_next")
    assert calls == ["last_error"]


def test_result_owner_is_released_even_when_result_readback_fails():
    bindings = object.__new__(nemotron._Bindings)
    destroyed = []

    def next_result(_stream, output):
        output._obj.value = 81
        return 0

    bindings.stream_next = next_result
    bindings.result_alternative_count = lambda _result: 1
    bindings.result_word_count = lambda _result, _alt: 0
    bindings.result_language_count = lambda _result, _alt: 0
    bindings.result_transcript = lambda _result, _alt: b"\xff"
    bindings.result_destroy = lambda handle: destroyed.append(handle.value)
    with pytest.raises(UnicodeDecodeError):
        bindings.pull(C.c_void_p(1))
    assert destroyed == [81]
