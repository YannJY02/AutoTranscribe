"""Deterministic protocol and lifecycle checks; no model libraries or children."""

from contextlib import redirect_stderr, redirect_stdout
import io
import json
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest import mock
import wave


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import compare_streaming_asr as cli
from streaming_asr_experiment.common import (
    Audio, EventJournal, StreamSession, load_audio, load_reference, quality_metrics,
)


class FakeClock:
    def __init__(self):
        self.now = 0.0
        self.lock = threading.Lock()

    def __call__(self):
        with self.lock:
            return self.now

    def advance(self, seconds):
        with self.lock:
            self.now += seconds


def write_wav(path, *, frames=1600, channels=1, width=2, rate=16000):
    with wave.open(str(path), "wb") as stream:
        stream.setnchannels(channels)
        stream.setsampwidth(width)
        stream.setframerate(rate)
        stream.writeframes(b"\0" * frames * channels * width)


class CommonProtocolTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def journal(self):
        journal = EventJournal(self.root / "events.jsonl")
        self.addCleanup(journal.close)
        return journal

    def test_pace_sleep_does_not_block_text_from_another_thread(self):
        clock = FakeClock()
        sleeping, release, emitted = threading.Event(), threading.Event(), threading.Event()
        failures = []

        def sleep(seconds):
            sleeping.set()
            if not release.wait(2):
                raise RuntimeError("test did not release the fake audio clock")
            clock.advance(seconds)

        session = StreamSession(Audio(16000, 3200, b"\0" * 6400), self.journal(), 1,
                                clock=clock, sleep=sleep)
        clock.advance(0.05)
        session.pace_to(800)

        def pace():
            try:
                session.pace_to(1600)
            except BaseException as error:
                failures.append(error)

        def publish():
            try:
                session.emit_text("earlier audio", semantics="delta", audio_end_frame=800)
                emitted.set()
            except BaseException as error:
                failures.append(error)

        producer = threading.Thread(target=pace, daemon=True)
        publisher = threading.Thread(target=publish, daemon=True)
        producer.start()
        try:
            self.assertTrue(sleeping.wait(1), "producer never entered pace sleep")
            publisher.start()
            self.assertTrue(emitted.wait(1), "pace sleep blocked publication from another thread")
        finally:
            release.set()
            producer.join(2)
            if publisher.ident is not None:
                publisher.join(2)
        self.assertFalse(producer.is_alive())
        self.assertFalse(publisher.is_alive())
        self.assertEqual(failures, [])
        self.assertEqual(session.summary()["released_frames"], 1600)
        events = [json.loads(line) for line in (self.root / "events.jsonl").read_text().splitlines()]
        ordered = [(row["kind"], row.get("audio_end_frame")) for row in events
                   if row["kind"] in {"audio_released", "text"}]
        self.assertEqual(ordered, [("audio_released", 800), ("text", 800), ("audio_released", 1600)])

    def test_source_and_text_frontiers_stay_within_released_finite_audio(self):
        session = StreamSession(Audio(16000, 1600, b"\0" * 3200), self.journal(), 1,
                                pacing="accelerated")
        session.pace_to(800)
        for frame in (-1, 799, 1601, True, 800.0):
            with self.subTest(source_frame=frame), self.assertRaises(ValueError):
                session.pace_to(frame)
        for frame in (-1, 801, 1601, False, 2.5):
            with self.subTest(text_frame=frame), self.assertRaises(ValueError):
                session.emit_text("future audio", semantics="delta", audio_end_frame=frame)
        session.emit_text("", semantics="delta")
        session.emit_text(" \n", semantics="delta")
        self.assertIsNone(session.summary()["first_text_ms"])
        session.pace_to(1600)
        session.emit_text("finished", semantics="final")
        self.assertEqual(session.summary()["released_frames"], 1600)
        self.assertEqual(session.summary()["text_events"], 1)

    def test_wav_format_duration_and_truncated_pcm_are_checked_before_loading(self):
        path = self.root / "input.wav"
        write_wav(path, frames=16000)
        audio = load_audio(path, max_seconds=1)
        self.assertEqual((audio.sample_rate, audio.frames, len(audio.pcm16)), (16000, 16000, 32000))
        for settings in ({"frames": 0}, {"frames": 16001}, {"channels": 2},
                         {"width": 1}, {"rate": 8000}):
            with self.subTest(settings=settings):
                write_wav(path, **settings)
                with self.assertRaises(ValueError):
                    load_audio(path, max_seconds=1)
        write_wav(path)
        path.write_bytes(path.read_bytes()[:-2])
        with self.assertRaisesRegex(ValueError, "claims more PCM"):
            load_audio(path)

    def test_reference_is_sorted_and_rejects_out_of_audio_or_invalid_segments(self):
        path = self.root / "reference.json"
        path.write_text(json.dumps({"segments": [
            {"start_ms": 50, "end_ms": 100, "text": "AI"},
            {"start_ms": 0, "end_ms": 40, "text": "你好"},
        ]}))
        text, segments = load_reference(path, duration_ms=100)
        self.assertEqual(text, "你好 AI")
        self.assertEqual([segment["start_ms"] for segment in segments], [0, 50])
        for override in ({"start_ms": -1}, {"start_ms": True}, {"start_ms": float("nan")},
                         {"end_ms": 0}, {"end_ms": 101}, {"end_ms": float("inf")},
                         {"end_ms": False}, {"text": " \n"}):
            with self.subTest(override=override):
                segment = {"start_ms": 0, "end_ms": 100, "text": "valid"} | override
                path.write_text(json.dumps({"segments": [segment]}))
                with self.assertRaises(ValueError):
                    load_reference(path, duration_ms=100)

    def test_mixed_language_scores_keep_yan76_normalization_and_metric_limits(self):
        result = quality_metrics("你好世界，ＡＩ API ２ don’t", "你号世界 AI SDK 2 don't")
        self.assertEqual(result["chinese_cer"],
                         {"errors": 1, "reference_units": 4, "hypothesis_units": 4, "rate": 0.25})
        self.assertEqual(result["english_wer"],
                         {"errors": 1, "reference_units": 4, "hypothesis_units": 4, "rate": 0.25})
        # The two filtered metrics cannot detect cross-language reordering.
        reordered = quality_metrics("你好 AI 世界", "AI 你好世界")
        self.assertEqual([value["errors"] for value in reordered.values()], [0, 0])
        absent = quality_metrics("你好", "你好 hallucination")["english_wer"]
        self.assertEqual(absent, {"errors": 1, "reference_units": 0, "hypothesis_units": 1, "rate": None})


class WorkerLifecycleTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        audio, reference = self.root / "input.wav", self.root / "reference.json"
        write_wav(audio)
        reference.write_text(json.dumps({"segments": [{"start_ms": 0, "end_ms": 100, "text": "你好 AI"}]}))
        self.args = SimpleNamespace(input=audio, reference=reference, output=self.root / "report.json",
                                    model="voxtral", pacing="accelerated", passes=2,
                                    max_audio_seconds=1, max_tokens=32, latency_ms=480,
                                    chunk_ms=80, language="auto", seed=0, max_rss_mib=8192)
        self.model = object()

    def invoke(self, run):
        adapter = SimpleNamespace(__file__=__file__, load=mock.Mock(return_value=(self.model, {"fake": True})),
                                  run=mock.Mock(side_effect=run), close=mock.Mock())
        with mock.patch.object(cli.importlib, "import_module", return_value=adapter), \
                redirect_stderr(io.StringIO()):
            code = cli.worker(self.args)
        report = json.loads(self.args.output.read_text())
        events = [json.loads(line) for line in Path(str(self.args.output) + ".events.jsonl").read_text().splitlines()]
        adapter.load.assert_called_once()
        adapter.close.assert_called_once_with(self.model)
        return code, report, events, adapter

    def test_second_pass_failure_preserves_first_pass_and_partial_text_journal(self):
        self.args.passes = 3
        calls = []

        def run(model, audio, session, args):
            self.assertIs(model, self.model)
            calls.append(session)
            session.pace_to(audio.frames if len(calls) == 1 else audio.frames // 2)
            session.emit_text("你好 AI" if len(calls) == 1 else "partial text", semantics="delta")
            if len(calls) == 2:
                raise RuntimeError("fake decoder stopped")
            return {"text": "你好 AI", "completed": True}

        code, report, events, adapter = self.invoke(run)
        self.assertEqual(code, 1)
        self.assertEqual(report["status"], "failed")
        self.assertEqual([row["status"] for row in report["passes"]], ["completed", "failed"])
        self.assertEqual(report["passes"][0]["quality"]["chinese_cer"]["errors"], 0)
        self.assertEqual(report["passes"][1]["stream"]["released_frames"], 800)
        self.assertEqual(report["passes"][1]["error"]["message"], "fake decoder stopped")
        self.assertEqual([row["text"] for row in events if row["kind"] == "text"], ["你好 AI", "partial text"])
        self.assertEqual(adapter.run.call_count, 2)

    def test_incomplete_results_keep_raw_output_and_fail_without_quality_scores(self):
        cases = [("truncated", {"truncated": True}, 1600),
                 ("not-completed", {"completed": False}, 1600),
                 ("failed-status", {"status": "failed"}, 1600),
                 ("partial-input", {"completed": True}, 800)]
        for name, flags, frontier in cases:
            with self.subTest(case=name):
                self.args.output = self.root / (name + ".json")
                result = {"text": "partial native output", **flags}

                def run(model, audio, session, args):
                    session.pace_to(frontier)
                    session.emit_text(result["text"], semantics="delta")
                    return result

                code, report, events, adapter = self.invoke(run)
                self.assertEqual(code, 1)
                self.assertEqual(report["status"], "failed")
                row = report["passes"][0]
                self.assertEqual(row["adapter_result"], result)
                self.assertEqual(row["status"], "failed")
                self.assertNotIn("quality", row)
                self.assertIn("worker_failed", [event["kind"] for event in events])
                self.assertEqual(adapter.run.call_count, 1)

    def test_stream_clock_excludes_initial_report_io_and_freezes_before_scoring(self):
        self.args.passes = 1
        clock, starts = FakeClock(), []
        real_write, real_quality = cli.write_report, cli.quality_metrics

        def slow_write(path, report):
            clock.advance(10)
            real_write(path, report)

        def slow_score(reference, text):
            clock.advance(5)
            return real_quality(reference, text)

        def session_factory(*args, **kwargs):
            return StreamSession(*args, **kwargs, clock=clock, sleep=clock.advance)

        def run(model, audio, session, args):
            starts.append(session.elapsed_ms())
            session.pace_to(audio.frames)
            clock.advance(0.1)
            session.emit_text("你好 AI", semantics="delta")
            clock.advance(0.03)
            return {"text": "你好 AI"}

        with mock.patch.object(cli, "write_report", side_effect=slow_write), \
                mock.patch.object(cli, "quality_metrics", side_effect=slow_score), \
                mock.patch.object(cli, "StreamSession", side_effect=session_factory):
            code, report, events, adapter = self.invoke(run)
        self.assertEqual(code, 0)
        self.assertEqual(starts, [0.0])
        row = report["passes"][0]
        self.assertAlmostEqual(row["final_text_available_ms"], 130)
        self.assertAlmostEqual(row["stream"]["stream_wall_ms"], 130)
        self.assertAlmostEqual(row["stream"]["first_text_ms"], 100)


class FakeProcess:
    pid = 987654

    def __init__(self, waits=None, returncode=None):
        self.returncode = returncode
        self.waits = list(waits or [-signal.SIGTERM])
        self.wait_calls = []

    def poll(self):
        return self.returncode

    def wait(self, timeout=None):
        self.wait_calls.append(timeout)
        value = self.waits.pop(0)
        if isinstance(value, BaseException):
            raise value
        self.returncode = value
        return value


class ParentProcessTests(unittest.TestCase):
    def test_stop_handles_already_exited_and_process_group_exit_races(self):
        exited = FakeProcess(returncode=0)
        with mock.patch.object(cli.os, "killpg") as kill:
            cli.stop_owned_process(exited)
        kill.assert_not_called()
        self.assertEqual(exited.wait_calls, [])
        raced = FakeProcess()
        with mock.patch.object(cli.os, "killpg", side_effect=ProcessLookupError) as kill:
            cli.stop_owned_process(raced)
        kill.assert_called_once_with(raced.pid, signal.SIGTERM)
        self.assertEqual(raced.wait_calls, [5])

    def test_stop_escalates_after_timeout_even_when_kill_target_disappears(self):
        process = FakeProcess([subprocess.TimeoutExpired("fake worker", 5), -signal.SIGKILL])
        with mock.patch.object(cli.os, "killpg", side_effect=[None, ProcessLookupError]) as kill:
            cli.stop_owned_process(process)
        self.assertEqual(kill.call_args_list, [mock.call(process.pid, signal.SIGTERM),
                                              mock.call(process.pid, signal.SIGKILL)])
        self.assertEqual(process.wait_calls, [5, 5])
        self.assertEqual(process.returncode, -signal.SIGKILL)

    def test_parent_limits_and_interruptions_stop_child_and_retain_partial_evidence(self):
        for interruption in ("timeout", "sigterm", "rss-limit", "keyboard-interrupt"):
            with self.subTest(interruption=interruption), tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / "report.json"
                args = SimpleNamespace(output=output, model="voxtral", timeout_seconds=1,
                                       max_rss_mib=8192)
                process = FakeProcess()
                partial = {"schema_version": 1, "model": "voxtral", "status": "running",
                           "passes": [{"pass": 1, "status": "running", "note": "partial evidence"}]}
                event_path = Path(str(output) + ".events.jsonl")

                def launch(*command, **options):
                    output.write_text(json.dumps(partial))
                    event_path.write_text('{"kind":"text","text":"partial transcript"}\n')
                    options["stdout"].write("partial native stdout\n")
                    options["stderr"].write("partial native stderr\n")
                    return process

                with mock.patch.object(cli.subprocess, "Popen", side_effect=launch) as popen, \
                        mock.patch.object(cli.os, "killpg") as kill, \
                        mock.patch.object(cli.signal, "getsignal", return_value=mock.sentinel.previous_handler), \
                        mock.patch.object(cli.signal, "signal") as install_handler, \
                        mock.patch.object(cli.time, "monotonic", side_effect=[0.0, 2.0, 2.1]
                                          if interruption == "timeout" else [0.0, 0.1, 0.2]), \
                        mock.patch.object(cli, "rss_sample") as sample, redirect_stdout(io.StringIO()):
                    if interruption == "sigterm":
                        def signal_during_sample(pid):
                            handler = install_handler.call_args_list[0].args[1]
                            handler(signal.SIGTERM, None)
                        sample.side_effect = signal_during_sample
                    elif interruption == "rss-limit":
                        sample.return_value = {"available": True, "rss_kib": 8192 * 1024 + 1,
                                               "cpu_pct": 12.5}
                    elif interruption == "keyboard-interrupt":
                        sample.side_effect = KeyboardInterrupt("fake user cancellation")
                    code = cli.driver(args, ["--model", "voxtral"])
                self.assertEqual(code, 130 if interruption == "keyboard-interrupt" else 1)
                kill.assert_called_once_with(process.pid, signal.SIGTERM)
                self.assertTrue(popen.call_args.kwargs["start_new_session"])
                self.assertEqual(install_handler.call_args_list[-1],
                                 mock.call(signal.SIGTERM, mock.sentinel.previous_handler))
                report = json.loads(output.read_text())
                self.assertEqual(report["status"], "failed")
                self.assertEqual(report["passes"], partial["passes"])
                self.assertEqual(event_path.read_text(), '{"kind":"text","text":"partial transcript"}\n')
                self.assertEqual(Path(str(output) + ".stdout.log").read_text(), "partial native stdout\n")
                self.assertEqual(Path(str(output) + ".stderr.log").read_text(), "partial native stderr\n")
                resources = json.loads(Path(str(output) + ".resources.json").read_text())
                self.assertEqual(resources["returncode"], -signal.SIGTERM)
                if interruption == "timeout":
                    self.assertTrue(resources["timed_out"])
                    sample.assert_not_called()
                elif interruption == "sigterm":
                    self.assertEqual(resources["error"]["type"], "InterruptedError")
                elif interruption == "keyboard-interrupt":
                    self.assertEqual(resources["error"]["type"], "KeyboardInterrupt")
                    self.assertTrue(report["process"]["interrupted"])
                    self.assertEqual(report["process"]["error"]["type"], "KeyboardInterrupt")
                    self.assertEqual(report["process"]["resources_path"], str(output) + ".resources.json")
                else:
                    self.assertEqual(resources["error"]["type"], "MemoryError")
                    self.assertEqual(resources["samples"][0]["rss_kib"], 8192 * 1024 + 1)


if __name__ == "__main__":
    unittest.main()
