"""Exercise the finite-source/native-loop boundary without model dependencies."""

from pathlib import Path
import json
import sys
import tempfile
import threading
import time
from types import ModuleType, SimpleNamespace
import unittest


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from streaming_asr_experiment import voxtral
from streaming_asr_experiment.common import EventJournal, StreamSession


class FakePCM:
    def __init__(self, values):
        self.values = list(values)

    def __len__(self):
        return len(self.values)

    def __getitem__(self, index):
        return FakePCM(self.values[index])

    def reshape(self, *shape):
        return [[value] for value in self.values]


class FakeSession:
    def __init__(self, fail_source=False):
        self.events, self.released = [], []
        self.fail_source = fail_source
        self.start = time.monotonic()
        self.lock = threading.Lock()

    def elapsed_ms(self):
        return (time.monotonic() - self.start) * 1000

    def record(self, kind, **fields):
        with self.lock:
            self.events.append({"kind": kind, **fields})

    def pace_to(self, end_frame):
        if self.fail_source:
            raise ValueError("fake source failed")
        self.released.append(end_frame)

    def emit_text(self, text, **fields):
        if fields["audio_end_frame"] > (self.released[-1] if self.released else 0):
            raise AssertionError("text observed audio that was not released")
        self.record("text", text=text, **fields)


NATIVE_LOOP = '''
def stream_transcribe(model_path, temperature):
    model, sp, config = load_model(model_path)
    model["instances"].append(model)
    lock = threading.Lock()
    audio_buf, pending_audio = [], []
    cache = y = None
    prefilled = False
    n_audio_samples_fed = n_total_decoded = 0

    def callback(indata, frames, time_info, status):
        with lock:
            audio_buf.extend(indata)

    print("Listening... initialization", flush=True)
    stream = sd.InputStream(samplerate=16000, channels=1, dtype="float32",
                            blocksize=1280, callback=callback)
    stream.start()
    try:
        if mode == "unexpected_interrupt":
            raise KeyboardInterrupt()
        while True:
            with lock:
                count = len(audio_buf)
                audio_buf.clear()
            if count:
                n_audio_samples_fed += count
                if not prefilled:
                    cache, y, prefilled = [], object(), True
                    model["cache_scopes"].append(cache)
                    for token in (1, 2, 3):
                        print(sp.decode([token]), end="", flush=True)
                        n_total_decoded += 1
                    print(flush=True)
                if mode == "loop_error":
                    raise ValueError("fake native loop failed")
            time.sleep(0.0001)
    except KeyboardInterrupt:
        pass
    finally:
        stream.stop()
        stream.close()
        if mode == "flush_error":
            raise RuntimeError("fake native flush failed")
        if cache is not None and y is not None:
            print(sp.decode([4]), end="", flush=True)
        print()
'''


class VoxtralAdapterTests(unittest.TestCase):
    def setUp(self):
        module = ModuleType("fake_native_voxmlx_stream")
        module.threading = threading
        module.time = time
        module.sd = object()
        module.load_model = object()
        module.mode = "normal"
        exec(NATIVE_LOOP, module.__dict__)
        self.originals = {name: getattr(module, name) for name in ("time", "sd", "load_model")}
        tokenizer = SimpleNamespace(decode=lambda ids, **kwargs: {1: "你", 2: "", 3: "\ufffd", 4: "好"}[ids[0]])
        self.state = voxtral._State(module, {"cache_scopes": [], "instances": []}, tokenizer,
                                    {}, Path("/fake/local-model"))
        self.audio = SimpleNamespace(sample_rate=16000, frames=1503, duration_ms=1503 / 16,
                                     as_float32=lambda: FakePCM(range(1503)))
        self.args = SimpleNamespace(latency_ms=480, language="auto", chunk_ms=320,
                                    max_tokens=4096, pacing="accelerated")

    def assert_restored(self):
        for name, original in self.originals.items():
            self.assertIs(getattr(self.state.module, name), original)
        self.assertNotIn("print", self.state.module.__dict__)
        self.assertFalse(self.state.run_lock.locked())

    def test_finite_eof_flushes_exact_token_deltas_and_resets_stream_state(self):
        for _ in range(2):
            session = FakeSession()
            result = voxtral.run(self.state, self.audio, session, self.args)
            self.assertEqual(session.released, [1280, 1503])
            self.assertEqual(result["text"], "你\ufffd好")
            self.assertEqual(result["decoded_tokens"], 4)
            self.assertEqual(result["native_eos_count"], 1)
            self.assertTrue(result["native_flush_completed"])
            self.assertTrue(result["native_flush_snapshot"]["tail_flush_eligible"])
            text = [event for event in session.events if event["kind"] == "text"]
            self.assertEqual([event["text"] for event in text], ["你", "", "\ufffd", "好"])
            self.assertFalse(text[0]["raw"]["during_flush"])
            self.assertTrue(text[-1]["raw"]["during_flush"])
            kinds = [event["kind"] for event in session.events]
            self.assertLess(kinds.index("native_eof_requested"), kinds.index("native_flush_started"))
            self.assertLess(kinds.index("native_flush_started"), kinds.index("native_flush_completed"))
            self.assert_restored()
        self.assertIs(self.state.model["instances"][0], self.state.model["instances"][1])
        self.assertIsNot(self.state.model["cache_scopes"][0], self.state.model["cache_scopes"][1])

    def test_source_and_native_errors_propagate_without_success(self):
        for mode, source_failure, exception, message in (
            ("normal", True, ValueError, "fake source failed"),
            ("loop_error", False, ValueError, "fake native loop failed"),
            ("flush_error", False, RuntimeError, "fake native flush failed"),
            ("unexpected_interrupt", False, RuntimeError, "without completing"),
        ):
            with self.subTest(mode=mode, source_failure=source_failure):
                self.state.module.mode = mode
                session = FakeSession(fail_source=source_failure)
                with self.assertRaisesRegex(exception, message):
                    voxtral.run(self.state, self.audio, session, self.args)
                self.assertIn("native_stream_failed", [event["kind"] for event in session.events])
                self.assertNotIn("native_flush_completed", [event["kind"] for event in session.events])
                self.assert_restored()

    def test_native_token_limit_is_a_failure(self):
        self.args.max_tokens = 2
        session = FakeSession()
        with self.assertRaisesRegex(RuntimeError, "token limit"):
            voxtral.run(self.state, self.audio, session, self.args)
        self.assertNotIn("native_flush_completed", [event["kind"] for event in session.events])
        self.assert_restored()

    def test_native_events_use_the_common_thread_safe_journal(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "events.ndjson"
            journal = EventJournal(path)
            try:
                session = StreamSession(self.audio, journal, 0, pacing="accelerated")
                result = voxtral.run(self.state, self.audio, session, self.args)
                self.assertEqual(session.summary()["released_frames"], self.audio.frames)
                self.assertEqual(session.summary()["text_events"], 3)
                self.assertEqual(result["text"], "你\ufffd好")
            finally:
                journal.close()
            events = [json.loads(line) for line in path.read_text().splitlines()]
            self.assertEqual([event["sequence"] for event in events], list(range(len(events))))
            self.assertEqual([event["audio_end_frame"] for event in events
                              if event["kind"] == "audio_released"], [1280, 1503])

    def test_eof_waits_for_pcm_arriving_after_an_empty_native_drain(self):
        session = FakeSession()
        source = voxtral._FiniteInput(FakePCM([0]), 1, session)
        source.done.set()
        source.complete = True
        source.delivered_frames = 1
        native_clock = voxtral._NativeClock(source)

        def native_checkpoint():
            audio_buf = [0]
            prefilled = False
            native_clock.sleep(0)
            self.assertFalse(source.eof_requested)
            audio_buf.clear()
            prefilled = True
            with self.assertRaises(voxtral._EndOfInput):
                native_clock.sleep(0)

        native_checkpoint()
        self.assertTrue(source.eof_requested)

    def test_model_session_cannot_overlap_or_change_native_delay(self):
        self.state.run_lock.acquire()
        try:
            with self.assertRaisesRegex(RuntimeError, "concurrent"):
                voxtral.run(self.state, self.audio, FakeSession(), self.args)
        finally:
            self.state.run_lock.release()
        self.args.latency_ms = 320
        with self.assertRaisesRegex(ValueError, "480 ms"):
            voxtral.run(self.state, self.audio, FakeSession(), self.args)


if __name__ == "__main__":
    unittest.main()
