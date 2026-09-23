import threading
import wave
from pathlib import Path

import pytest

from insightkit.data.store import InsightStore
from insightkit.ipc.live_diarization import LiveDiarizationSessions, split_speaker_segments


def segment(text="hello there", speaker="", start=0, end=1000):
    return dict(start_ms=start, end_ms=end, text=text, speaker=speaker, source="mixed", confidence=0.0)


WORDS = [dict(start_ms=0, end_ms=400, text="hello"), dict(start_ms=500, end_ms=1000, text="there")]
SPANS = [dict(start_ms=0, end_ms=450, speaker="SPEAKER_00"),
         dict(start_ms=450, end_ms=1100, speaker="SPEAKER_01")]


def test_word_timestamps_split_a_sentence_at_a_speaker_change():
    updated = split_speaker_segments([segment()], WORDS, SPANS, finalized_until_ms=1000)
    assert [(s["text"], s["speaker"]) for s in updated] == [("hello", "SPEAKER_00"), ("there", "SPEAKER_01")]
    assert [(s["start_ms"], s["end_ms"]) for s in updated] == [(0, 400), (500, 1000)]


def test_unfinalized_speech_does_not_borrow_an_earlier_speaker_label():
    updated = split_speaker_segments([segment()], WORDS, SPANS, finalized_until_ms=450)
    assert [(s["text"], s["speaker"]) for s in updated] == [("hello", "SPEAKER_00"), ("there", "")]


@pytest.fixture
def setup_live(tmp_path):
    store = InsightStore(tmp_path / "live.db")
    store.init_schema()
    store.upsert_meeting("one", "test", "mixed", "recording")
    audio = tmp_path / "chunk.wav"
    with wave.open(str(audio), "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(16000)
        f.writeframes(b"\0\0" * 16000)
    yield store, audio
    store.close()


class Worker:
    def __init__(self):
        self.calls = []
        self.closed = False

    def start(self):
        pass

    def feed(self, path, offset_ms):
        assert path.exists()
        self.calls.append(offset_ms)
        return dict(spans=SPANS, finalized_until_ms=1100, received_until_ms=1100)

    def close(self):
        self.closed = True


def test_worker_is_reused_and_patches_only_matching_saved_rows(setup_live):
    store, audio = setup_live
    worker = Worker()
    live = LiveDiarizationSessions(store, worker_factory=lambda _: worker)
    live.start("one")
    ticket = live.capture("one", "a", audio, 0, "mixed")
    live.recognized(ticket, [{**segment(), "_words": WORDS}])
    store.insert_segment("one", 0, 1000, "", "hello there", source="mixed")
    result = live.enrich("one", "a")
    assert result["status"] == "updated"
    assert result["updates"][0]["original_segments"] == [segment()]
    assert [s["speaker"] for s in store.list_segments("one")] == ["SPEAKER_00", "SPEAKER_01"]
    ticket = live.capture("one", "b", audio, 1000, "mixed")
    live.recognized(ticket, [])
    live.enrich("one", "b")
    assert worker.calls == [0, 1000]
    live.stop("one")
    assert worker.closed


def test_late_model_completion_cannot_overwrite_final_transcript(setup_live):
    store, audio = setup_live
    entered, release = threading.Event(), threading.Event()

    class SlowWorker(Worker):
        def feed(self, path, offset_ms):
            entered.set()
            assert release.wait(2)
            return super().feed(path, offset_ms) if path.exists() else dict(spans=SPANS, finalized_until_ms=1100)

    worker = SlowWorker()
    live = LiveDiarizationSessions(store, worker_factory=lambda _: worker)
    live.start("one")
    ticket = live.capture("one", "a", audio, 0, "mixed")
    live.recognized(ticket, [{**segment(), "_words": WORDS}])
    store.insert_segment("one", 0, 1000, "", "hello there", source="mixed")
    results = []
    thread = threading.Thread(target=lambda: results.append(live.enrich("one", "a")))
    thread.start()
    assert entered.wait(1)
    live.stop("one")
    store.replace_segments("one", [segment("final result", "FINAL")])
    release.set()
    thread.join(2)
    assert not thread.is_alive()
    assert results[0]["status"] == "stopped"
    assert store.list_segments("one")[0]["text"] == "final result"


def test_exact_replacement_refuses_partial_matches(setup_live):
    store, _ = setup_live
    store.insert_segment("one", 0, 1000, "", "owner correction", source="mixed")
    assert not store.replace_exact_segments("one", [segment()], [segment("replacement")])
    assert store.list_segments("one")[0]["text"] == "owner correction"


def test_foreground_asr_preserves_words_privately_and_never_loads_speaker_model(setup_live, monkeypatch):
    from insightkit.ipc import asr_dispatcher
    store, audio = setup_live
    dispatcher = asr_dispatcher.ASRDispatcher(store)
    dispatcher.live_speakers.start("one")
    calls = []

    def transcribe(path, **kwargs):
        calls.append(kwargs)
        return [{**segment(), "_words": WORDS}]

    monkeypatch.setattr(asr_dispatcher, "transcribe_audio_chunk", transcribe)
    dispatcher.live_speakers._factory = lambda _: pytest.fail("speaker model must not run on foreground ASR")
    result = dispatcher.asr_transcribe_live_chunk(dict(meeting_id="one", chunk_id="0", wav_path=str(audio)))
    assert result == {"segments": [segment()]}
    assert calls == [dict(offset_ms=0, attach_diarization=False, preserve_words=True)]
    dispatcher.live_speakers.close()


def test_cache_is_bounded_and_stale_asr_is_rejected_after_session_restart(setup_live):
    store, audio = setup_live
    live = LiveDiarizationSessions(store)
    live.start("one")
    first = live.capture("one", "0", audio, 0, "mixed")
    for index in range(1, live.MAX_PENDING_CHUNKS):
        assert live.capture("one", str(index), audio, index * 1000, "mixed")[1] is not None
    assert live.capture("one", "overflow", audio, 15000, "mixed")[1] is None
    old_dir = Path(first[0].directory.name)
    live.start("one")
    assert not old_dir.exists()
    with pytest.raises(RuntimeError, match="live_session_stopped"):
        live.recognized(first, [segment()])
    live.close()


def test_cache_failure_preserves_foreground_recognition(setup_live, monkeypatch):
    from insightkit.ipc import live_diarization
    store, audio = setup_live
    live = LiveDiarizationSessions(store)
    live.start("one")

    def fail_copy(*args):
        raise OSError("disk unavailable")

    monkeypatch.setattr(live_diarization.shutil, "copyfile", fail_copy)
    ticket = live.capture("one", "0", audio, 0, "mixed")
    assert ticket[1] is None
    live.recognized(ticket, [segment()])
    assert live.enrich("one", "0")["error"] == "speaker_cache_unavailable: OSError"
    live.close()


def test_stop_cancels_worker_during_model_startup(setup_live):
    store, audio = setup_live
    entered, release = threading.Event(), threading.Event()

    class StartingWorker(Worker):
        def start(self):
            entered.set()
            assert release.wait(2)
            if self.closed:
                raise RuntimeError("stopped")

        def close(self):
            super().close()
            release.set()

    worker = StartingWorker()
    live = LiveDiarizationSessions(store, worker_factory=lambda _: worker)
    live.start("one")
    ticket = live.capture("one", "0", audio, 0, "mixed")
    live.recognized(ticket, [segment()])
    results = []
    thread = threading.Thread(target=lambda: results.append(live.enrich("one", "0")))
    thread.start()
    assert entered.wait(1)
    live.stop("one")
    assert worker.closed
    thread.join(1)
    assert not thread.is_alive()
    assert results[0]["status"] == "stopped"


def test_stop_and_restart_keep_runtime_and_speaker_session_consistent(setup_live, monkeypatch):
    from insightkit.ipc.server import InsightRPCServer
    store, _ = setup_live
    server = InsightRPCServer(store=store)
    server._session_start(dict(meeting_id="one"))
    entered, release, starting = threading.Event(), threading.Event(), threading.Event()
    original_stop = server._session_handler.session_stop

    def pause_after_marking_stopped(params):
        result = original_stop(params)
        entered.set()
        assert release.wait(2)
        return result

    monkeypatch.setattr(server._session_handler, "session_stop", pause_after_marking_stopped)
    stopped = threading.Thread(target=lambda: server._session_stop(dict(meeting_id="one")))
    stopped.start()
    assert entered.wait(1)

    def restart():
        starting.set()
        server._session_start(dict(meeting_id="one"))

    restarted = threading.Thread(target=restart)
    restarted.start()
    assert starting.wait(1)
    release.set()
    stopped.join(2)
    restarted.join(2)
    assert not stopped.is_alive() and not restarted.is_alive()
    assert store.get_meeting("one")["status"] == "recording"
    assert server._session_handler.live_session_status(dict(meeting_id="one"))["state"] == "running"
    assert "one" in server._asr_dispatcher.live_speakers._sessions
    server._asr_dispatcher.live_speakers.close()
    server._job_queue.shutdown()


def test_deduplicated_row_does_not_block_speaker_updates_to_other_rows(setup_live):
    store, audio = setup_live
    live = LiveDiarizationSessions(store, worker_factory=lambda _: Worker())
    live.start("one")
    first = segment("Yes.", start=0, end=200)
    duplicate = segment("Yes.", start=300, end=450)
    last = segment("Next point.", start=500, end=1000)
    ticket = live.capture("one", "0", audio, 0, "mixed")
    live.recognized(ticket, [first, duplicate, last])
    for row in [first, last]:
        store.insert_segment("one", row["start_ms"], row["end_ms"], "", row["text"], source="mixed")
    result = live.enrich("one", "0")
    assert len(result["updates"]) == 2
    assert [s["speaker"] for s in store.list_segments("one")] == ["SPEAKER_00", "SPEAKER_01"]
    live.close()


def test_transcript_recovery_invalidates_live_speaker_results(setup_live, monkeypatch):
    from insightkit.ipc.server import InsightRPCServer
    store, _ = setup_live
    server = InsightRPCServer(store=store)
    server._session_start(dict(meeting_id="one"))
    monkeypatch.setattr(server, "_asr_transcribe_media", lambda _: {"segments": [segment("recovered", "FINAL")]})
    result = server._transcript_recover_action(dict(meeting_id="one", media_path="fixture.wav"))
    assert result["replaced"] == 1
    assert server._asr_dispatcher.live_speakers.enrich("one", "0")["status"] == "stopped"
    assert store.list_segments("one")[0]["speaker"] == "FINAL"
    server._job_queue.shutdown()
