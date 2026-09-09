"""VibeVoice protocol and resampling checks without a real model or MLX."""

import json
from types import SimpleNamespace

import pytest

from scripts.streaming_asr_experiment import vibevoice as driver


def arguments(**overrides):
    return SimpleNamespace(seed=0, max_tokens=4096, **overrides)


class FakeSession:
    def __init__(self, frames):
        self.frames = frames
        self.frontier = 0
        self.rows = []
        self.clock = 0.0

    def elapsed_ms(self):
        self.clock += 1
        return self.clock

    def record(self, kind, **fields):
        self.rows.append({"kind": kind, **fields})

    def pace_to(self, frame):
        assert isinstance(frame, int)
        assert self.frontier <= frame <= self.frames
        self.frontier = frame
        self.record("released", frame=frame)

    def emit_text(self, text, *, semantics, audio_end_frame, **details):
        assert 0 <= audio_end_frame <= self.frontier
        self.record("text", text=text, semantics=semantics, **details)


class FakeModel:
    def __init__(self, outputs, counts=None, failure=None):
        self.outputs = outputs
        self.counts = counts or [2] * len(outputs)
        self.failure = failure
        self.states = []
        self.observed_ids = []
        self.encoded = []

    def init_streaming_state(self):
        state = {"cache": object(), "cursor": 0, "generation_tokens": 0, "prompt_tokens": 4}
        self.states.append(state)
        return state

    def encode_speech(self, window, **kwargs):
        self.encoded.append(window)
        return window

    def streaming_generate_step(self, features, state, *, max_new_tokens, **kwargs):
        if self.failure:
            raise self.failure
        self.observed_ids.append(id(state))
        cursor = state["cursor"]
        state["cursor"] += 1
        state["generation_tokens"] += min(self.counts[cursor], max_new_tokens)
        return self.outputs[cursor], state


def fake_run_setup(monkeypatch, outputs, counts=None, failure=None, frames=112000):
    model = FakeModel(outputs, counts, failure)
    mx = SimpleNamespace(random=SimpleNamespace(seed=lambda value: None), clear_cache=lambda: None)
    state = driver.ModelState(model, mx, None, 66, {})
    audio = SimpleNamespace(sample_rate=16000, frames=frames, as_float32=lambda: "fake samples")
    session = FakeSession(frames)

    def prepare(runtime, samples, window, rate):
        assert runtime is state and rate == 16000
        assert session.frontier >= window.source_end_frame
        return window

    monkeypatch.setattr(driver, "_audio_window", prepare)
    return state, audio, session


@pytest.mark.parametrize("frames,count", [(1, 1), (46933, 1), (46934, 2), (928000, 20)])
def test_window_geometry_and_eof(frames, count):
    plan = list(driver.windows(frames, 16000, 66))
    assert len(plan) == count
    assert [window.model_start_sample for window in plan] == [i * 70400 for i in range(count)]
    assert all(window.source_start_frame % 2 == 0 for window in plan)
    assert [window.source_end_frame for window in plan] == sorted(window.source_end_frame for window in plan)
    assert all(0 < window.source_end_frame <= frames for window in plan)
    assert plan[-1].source_end_frame == frames
    assert plan[-1].consumed_end_frame == frames
    assert plan[-1].final
    assert not any(window.final for window in plan[:-1])
    if frames == 928000:
        assert plan[0].source_end_frame == 55533  # Native window + 66-frame FIR halo.
        assert driver.WINDOW_SAMPLES - plan[-1].real_model_samples == 28800


def test_split_speaker_and_special_tokens_do_not_publish_as_recognition():
    parser = driver.SpeakerParser()
    assert not parser.feed(" \n Sp")["text"]
    assert not parser.feed("eaker 0:")["text"]
    assert parser.feed("Hello ")["text"] == "Hello "
    assert parser.feed("world.\n Spea")["text"] == "Hello world.\n"
    assert parser.feed("ker 1:你好")["text"] == "Hello world.\n你好"
    assert parser.feed("世界<")["text"] == "Hello world.\n你好世界"
    assert parser.feed("|text_chunk_end|>")["text"] == "Hello world.\n你好世界"
    final = parser.feed("", final=True)
    assert final["warnings"] == []
    assert [event["speaker_id"] for event in parser.events] == [0, 1]
    assert "<|text_chunk_end|>" in parser.raw
    assert parser.events[1]["text_offset"] == len("Hello world.\n")


def test_parser_eof_releases_ordinary_partial_word_but_reports_unfinished_control():
    parser = driver.SpeakerParser()
    assert parser.feed("Sp")["text"] == ""
    assert parser.feed("", final=True)["text"] == "Sp"
    broken = driver.SpeakerParser()
    broken.feed("\n Speaker 2")
    assert broken.feed("", final=True)["warnings"] == ["incomplete_speaker_label"]


def test_label_indentation_can_arrive_in_the_previous_chunk():
    parser = driver.SpeakerParser()
    assert parser.feed("hello\n ")["text"] == "hello\n"
    assert parser.feed("Speaker 1:world")["text"] == "hello\nworld"


def test_native_state_reopens_without_text_speaker_or_kv_leak(monkeypatch):
    state, audio, session = fake_run_setup(monkeypatch, ["\n Speaker 0:", "hello ", "again."])
    first = driver.run(state, audio, session, arguments())
    second_session = FakeSession(audio.frames)
    monkeypatch.setattr(driver, "_audio_window", lambda runtime, samples, window, rate: window)
    second = driver.run(state, audio, second_session, arguments())
    assert first["text"] == second["text"] == "hello again."
    assert first["raw_chunks"] == second["raw_chunks"]
    assert first["completed"] and not first["truncated"]
    assert len(state.model.states) == 2
    assert state.model.states == [{}, {}]  # finally releases each request's KV state.
    assert len(set(state.model.observed_ids)) == 2
    assert len(state.model.encoded) == 6
    text_rows = [row for row in session.rows if row["kind"] == "text"]
    assert text_rows[0]["chunk_index"] == 1
    assert all("Speaker" not in row["text"] for row in text_rows)
    assert len(first["speaker_events"]) == len(second["speaker_events"]) == 1
    assert [row["eof_flush"] for row in session.rows if row["kind"] == "stream_step_start"] == [False, False, True]


@pytest.mark.parametrize("budget,counts,reason", [
    (4096, [256], "per_chunk_token_limit_reached"),
    (3, [3], "total_token_limit_reached"),
])
def test_token_caps_are_truncation_not_success(monkeypatch, budget, counts, reason):
    state, audio, session = fake_run_setup(monkeypatch, ["\n Speaker 0:partial"], counts)
    args = arguments()
    args.max_tokens = budget
    result = driver.run(state, audio, session, args)
    assert result["truncated"] and not result["completed"]
    assert result["truncation_reasons"] == [reason]
    assert result["processed_chunks"] == 1 < result["expected_chunks"]
    assert any(row["kind"] == "truncation" for row in session.rows)
    assert state.model.states == [{}]


def test_native_error_releases_kv_without_success_event(monkeypatch):
    state, audio, session = fake_run_setup(monkeypatch, [], failure=RuntimeError("native failure"))
    with pytest.raises(RuntimeError, match="native failure"):
        driver.run(state, audio, session, arguments())
    assert state.model.states == [{}]
    assert not any(row["kind"] == "stream_end" for row in session.rows)


@pytest.mark.parametrize("frames", [0, 480 * 16000 + 1])
def test_empty_or_unsupported_length_fails_before_state_init(monkeypatch, frames):
    state, audio, session = fake_run_setup(monkeypatch, [], frames=frames)
    with pytest.raises(ValueError, match="eight minutes"):
        driver.run(state, audio, session, arguments())
    assert not state.model.states


@pytest.mark.parametrize("frames", [1, 46934, 7 * 16000 + 17])
def test_resampled_windows_equal_full_fir_and_only_pad_eof(frames):
    np = pytest.importorskip("numpy")
    signal = pytest.importorskip("scipy.signal")
    # The pinned mlx_audio.resample FIR: same phase/support as full resample_poly.
    fir = signal.firwin(385, 0.9475937167399596 / 3, window=("kaiser", 14.769656459379492))

    def resample(values, orig_rate, target_rate, axis):
        assert (orig_rate, target_rate, axis) == (16000, 24000, 0)
        return signal.resample_poly(values, 3, 2, axis=axis, window=fir, padtype="edge").astype(np.float32)

    mx = SimpleNamespace(array=np.array, float32=np.float32, pad=np.pad)
    state = driver.ModelState(None, mx, resample, 66, {})
    samples = np.random.default_rng(13).uniform(-1, 1, frames).astype(np.float32)
    full = resample(samples, 16000, 24000, 0)
    for window in driver.windows(frames, 16000, 66):
        tensor = driver._audio_window(state, samples, window, 16000)
        assert tensor.shape == (1, driver.WINDOW_SAMPLES)
        end = window.model_start_sample + window.real_model_samples
        np.testing.assert_allclose(tensor[0, :window.real_model_samples], full[window.model_start_sample:end], atol=1e-7, rtol=1e-7)
        np.testing.assert_array_equal(tensor[0, window.real_model_samples:], 0)


def test_actual_weight_headers_override_stale_config_dtype(tmp_path):
    header = {
        "language_model.model.embed_tokens.weight": {"dtype": "U32", "shape": [2, 2], "data_offsets": [0, 16]},
        "acoustic_tokenizer.encoder.weight": {"dtype": "BF16", "shape": [2], "data_offsets": [16, 20]},
    }
    path = tmp_path / "model.safetensors"

    def write_header():
        raw = json.dumps(header).encode()
        path.write_bytes(len(raw).to_bytes(8, "little") + raw + b"\0" * 20)

    write_header()
    assert driver._weight_summary(tmp_path)["non_language_model_bytes"] == 4
    header["acoustic_tokenizer.encoder.weight"]["dtype"] = "F32"
    write_header()
    with pytest.raises(ValueError, match="actual BF16"):
        driver._weight_summary(tmp_path)


def test_duplicate_tied_head_is_removed_only_after_full_equality_check():
    embedding = SimpleNamespace(shape=(2, 3), value="embedding")
    head = SimpleNamespace(shape=(2, 3), value="head")
    weights = {"language_model.model.embed_tokens.weight": embedding,
               "language_model.lm_head.weight": head}
    calls = []

    def equal(left, right):
        calls.append((left, right))
        return True

    cleaned = driver.drop_verified_tied_lm_head(weights, tied_embeddings=True, arrays_equal=equal)
    assert calls == [(head, embedding)]
    assert list(cleaned) == ["language_model.model.embed_tokens.weight"]
    assert "language_model.lm_head.weight" in weights  # Do not mutate the source map.
    with pytest.raises(ValueError, match="cannot discard"):
        driver.drop_verified_tied_lm_head(weights, tied_embeddings=True, arrays_equal=lambda *values: False)
    assert driver.drop_verified_tied_lm_head(weights, tied_embeddings=False, arrays_equal=equal) is weights
