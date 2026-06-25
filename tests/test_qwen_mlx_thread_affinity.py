import json
import os
import socket
import sys
import threading
import time
from pathlib import Path
from types import SimpleNamespace

from insightkit.data.store import InsightStore
from insightkit.ipc.asr_dispatcher import ASRDispatcher
from insightkit.ipc.server import InsightRPCServer
from scripts import transcriber


def _wait_for_warm_state(expected: str, timeout: float = 2.0) -> dict:
    deadline = time.time() + timeout
    while time.time() < deadline:
        status = transcriber.runtime_warm_status()
        if status.get("state") == expected:
            return status
        time.sleep(0.02)
    raise AssertionError(f"warm state never reached {expected}: {transcriber.runtime_warm_status()}")


def _wait_for_socket(socket_path, timeout: float = 2.0) -> None:
    deadline = time.time() + timeout
    last_error: BaseException | None = None
    while time.time() < deadline:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(0.2)
        try:
            conn.connect(str(socket_path))
            return
        except BaseException as exc:  # noqa: BLE001 - keep last startup error for assertion.
            last_error = exc
            time.sleep(0.02)
        finally:
            conn.close()
    raise AssertionError(f"server did not become ready at {socket_path}: {last_error}")


def _legacy_rpc_call(socket_path, method: str, params: dict, request_id: int = 1) -> dict:
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.settimeout(5)
    try:
        conn.connect(str(socket_path))
        payload = json.dumps(
            {"id": request_id, "method": method, "params": params},
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
        conn.sendall(payload)
        conn.shutdown(socket.SHUT_WR)
        data = b""
        while True:
            chunk = conn.recv(4096)
            if not chunk:
                break
            data += chunk
        return json.loads(data.decode("utf-8"))
    finally:
        conn.close()


def test_qwen_mlx_prewarm_does_not_reuse_thread_owned_session_for_live_chunk(monkeypatch, tmp_path):
    transcriber._reset_runtime_state_for_tests()  # noqa: SLF001
    created_on_threads: list[int] = []

    class FakeQwenSession:
        def __init__(self, model: str):
            self.model = model
            self.owner_thread = threading.get_ident()
            created_on_threads.append(self.owner_thread)

        def transcribe(self, **_kwargs):
            if threading.get_ident() != self.owner_thread:
                raise RuntimeError("There is no Stream(gpu, 1) in current thread.")
            return SimpleNamespace(
                language="en",
                speaker_segments=[],
                chunks=[],
                segments=[{"start": 0.0, "end": 1.0, "text": "hello"}],
                text="hello",
            )

    try:
        monkeypatch.setitem(sys.modules, "mlx_qwen3_asr", SimpleNamespace(Session=FakeQwenSession))
        monkeypatch.setattr(transcriber, "ASR_ENGINE", "qwen-mlx")
        monkeypatch.setattr(transcriber, "DIARIZATION_ENABLED", False)
        monkeypatch.setattr(transcriber, "QWEN_MLX_RETURN_TIMESTAMPS", False)
        monkeypatch.setattr(transcriber, "_resolve_qwen_mlx_source", lambda: "fake-qwen-model")
        monkeypatch.setattr(transcriber, "_speech_exists", lambda _path: True)

        dispatcher = ASRDispatcher()
        dispatcher.asr_prewarm({"engine": "qwen-mlx", "model": "fake-qwen-model", "timeout_sec": 3})
        warm = _wait_for_warm_state("ready")
        assert warm["ready"] is True
        assert created_on_threads
        assert created_on_threads[0] != threading.get_ident()

        wav = tmp_path / "chunk.wav"
        wav.write_bytes(b"RIFF----WAVE")

        payload = dispatcher.asr_transcribe_chunk(
            {"wav_path": str(wav), "offset_ms": 2400, "source": "mic"}
        )

        assert payload["segments"] == [
            {
                "start_ms": 2400,
                "end_ms": 3400,
                "speaker": "",
                "text": "hello",
                "confidence": 0.0,
                "source": "mic",
            }
        ]
    finally:
        transcriber._reset_runtime_state_for_tests()  # noqa: SLF001


def test_qwen_mlx_live_chunks_do_not_create_unbounded_thread_sessions(monkeypatch, tmp_path):
    transcriber._reset_runtime_state_for_tests()  # noqa: SLF001
    created_on_threads: list[int] = []
    worker_count = 4
    start_barrier = threading.Barrier(worker_count)
    finish_barrier = threading.Barrier(worker_count)

    class FakeQwenSession:
        def __init__(self, model: str):
            self.model = model
            self.owner_thread = threading.get_ident()
            created_on_threads.append(self.owner_thread)

        def transcribe(self, **_kwargs):
            if threading.get_ident() != self.owner_thread:
                raise RuntimeError("There is no Stream(gpu, 2) in current thread.")
            return SimpleNamespace(
                language="en",
                speaker_segments=[],
                chunks=[],
                segments=[{"start": 0.0, "end": 1.0, "text": "hello"}],
                text="hello",
            )

    try:
        monkeypatch.setitem(sys.modules, "mlx_qwen3_asr", SimpleNamespace(Session=FakeQwenSession))
        monkeypatch.setattr(transcriber, "ASR_ENGINE", "qwen-mlx")
        monkeypatch.setattr(transcriber, "DIARIZATION_ENABLED", False)
        monkeypatch.setattr(transcriber, "QWEN_MLX_RETURN_TIMESTAMPS", False)
        monkeypatch.setattr(transcriber, "_resolve_qwen_mlx_source", lambda: "fake-qwen-model")
        monkeypatch.setattr(transcriber, "_speech_exists", lambda _path: True)

        wav = tmp_path / "chunk.wav"
        wav.write_bytes(b"RIFF----WAVE")
        dispatcher = ASRDispatcher()
        results: list[dict] = []
        errors: list[BaseException] = []

        def worker(index: int) -> None:
            try:
                start_barrier.wait(timeout=2)
                results.append(
                    dispatcher.asr_transcribe_chunk(
                        {"wav_path": str(wav), "offset_ms": index * 1000, "source": "mic"}
                    )
                )
                finish_barrier.wait(timeout=2)
            except BaseException as exc:  # noqa: BLE001 - preserve thread failure for assertion.
                errors.append(exc)

        threads = [
            threading.Thread(target=worker, args=(index,), daemon=True)
            for index in range(worker_count)
        ]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=3)

        assert errors == []
        assert len(results) == worker_count
        qwen_cache_keys = [
            key
            for key in transcriber._models  # noqa: SLF001
            if key == transcriber.QWEN_MLX_ENGINE
            or (
                isinstance(key, tuple)
                and len(key) >= 1
                and key[0] == transcriber.QWEN_MLX_ENGINE
            )
        ]
        assert len(qwen_cache_keys) <= 1, (
            "Qwen MLX live chunks must not retain one heavyweight session per "
            f"Sidecar caller thread; created={len(created_on_threads)} cache_keys={qwen_cache_keys!r}"
        )
    finally:
        transcriber._reset_runtime_state_for_tests()  # noqa: SLF001


def test_qwen_mlx_concurrent_live_chunks_do_not_expose_gpu_stream_error(monkeypatch, tmp_path):
    transcriber._reset_runtime_state_for_tests()  # noqa: SLF001
    worker_count = 4
    start_barrier = threading.Barrier(worker_count)
    stream_owner_thread: list[int] = []

    class FakeQwenSession:
        def __init__(self, model: str):
            self.model = model
            self.owner_thread = threading.get_ident()
            if not stream_owner_thread:
                stream_owner_thread.append(self.owner_thread)

        def transcribe(self, **_kwargs):
            if threading.get_ident() != stream_owner_thread[0]:
                raise RuntimeError("There is no Stream(gpu, 2) in current thread.")
            return SimpleNamespace(
                language="en",
                speaker_segments=[],
                chunks=[],
                segments=[{"start": 0.0, "end": 1.0, "text": "hello"}],
                text="hello",
            )

    try:
        monkeypatch.setitem(sys.modules, "mlx_qwen3_asr", SimpleNamespace(Session=FakeQwenSession))
        monkeypatch.setattr(transcriber, "ASR_ENGINE", "qwen-mlx")
        monkeypatch.setattr(transcriber, "DIARIZATION_ENABLED", False)
        monkeypatch.setattr(transcriber, "QWEN_MLX_RETURN_TIMESTAMPS", False)
        monkeypatch.setattr(transcriber, "_resolve_qwen_mlx_source", lambda: "fake-qwen-model")
        monkeypatch.setattr(transcriber, "_speech_exists", lambda _path: True)

        wav = tmp_path / "chunk.wav"
        wav.write_bytes(b"RIFF----WAVE")
        dispatcher = ASRDispatcher()
        errors: list[BaseException] = []

        def worker(index: int) -> None:
            try:
                start_barrier.wait(timeout=2)
                payload = dispatcher.asr_transcribe_chunk(
                    {"wav_path": str(wav), "offset_ms": index * 1000, "source": "mic"}
                )
                assert payload["segments"][0]["text"] == "hello"
            except BaseException as exc:  # noqa: BLE001 - preserve thread failure for assertion.
                errors.append(exc)

        threads = [
            threading.Thread(target=worker, args=(index,), daemon=True)
            for index in range(worker_count)
        ]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=3)

        assert errors == []
    finally:
        transcriber._reset_runtime_state_for_tests()  # noqa: SLF001


def test_qwen_mlx_rpc_live_chunks_do_not_return_gpu_stream_sidecar_error(monkeypatch, tmp_path):
    transcriber._reset_runtime_state_for_tests()  # noqa: SLF001
    worker_count = 4
    start_barrier = threading.Barrier(worker_count)
    stream_owner_thread: list[int] = []

    class FakeQwenSession:
        def __init__(self, model: str):
            self.model = model
            self.owner_thread = threading.get_ident()
            if not stream_owner_thread:
                stream_owner_thread.append(self.owner_thread)

        def transcribe(self, **_kwargs):
            if threading.get_ident() != stream_owner_thread[0]:
                raise RuntimeError("There is no Stream(gpu, 2) in current thread.")
            return SimpleNamespace(
                language="en",
                speaker_segments=[],
                chunks=[],
                segments=[{"start": 0.0, "end": 1.0, "text": "hello"}],
                text="hello",
            )

    socket_path = Path("/private/tmp") / f"ik-qwen-{os.getpid()}-{time.time_ns()}.sock"
    server = InsightRPCServer(
        socket_path=socket_path,
        store=InsightStore(tmp_path / "insightkit.db"),
    )
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)

    try:
        monkeypatch.setitem(sys.modules, "mlx_qwen3_asr", SimpleNamespace(Session=FakeQwenSession))
        monkeypatch.setattr(transcriber, "ASR_ENGINE", "qwen-mlx")
        monkeypatch.setattr(transcriber, "DIARIZATION_ENABLED", False)
        monkeypatch.setattr(transcriber, "QWEN_MLX_RETURN_TIMESTAMPS", False)
        monkeypatch.setattr(transcriber, "_resolve_qwen_mlx_source", lambda: "fake-qwen-model")
        monkeypatch.setattr(transcriber, "_speech_exists", lambda _path: True)

        server_thread.start()
        _wait_for_socket(server.socket_path)

        prewarm = _legacy_rpc_call(
            server.socket_path,
            "asr.prewarm",
            {"engine": "qwen-mlx", "model": "fake-qwen-model", "timeout_sec": 3},
            request_id=10,
        )
        assert "error" not in prewarm
        warm = _wait_for_warm_state("ready")
        assert warm["ready"] is True
        assert stream_owner_thread

        wav = tmp_path / "chunk.wav"
        wav.write_bytes(b"RIFF----WAVE")
        responses: list[dict] = []
        errors: list[BaseException] = []

        def worker(index: int) -> None:
            try:
                start_barrier.wait(timeout=2)
                responses.append(
                    _legacy_rpc_call(
                        server.socket_path,
                        "asr.transcribe_chunk",
                        {"wav_path": str(wav), "offset_ms": index * 1000, "source": "mic"},
                        request_id=100 + index,
                    )
                )
            except BaseException as exc:  # noqa: BLE001 - preserve thread failure for assertion.
                errors.append(exc)

        threads = [
            threading.Thread(target=worker, args=(index,), daemon=True)
            for index in range(worker_count)
        ]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=3)

        assert errors == []
        assert len(responses) == worker_count
        for response in responses:
            assert "error" not in response, response
            assert response["result"]["segments"][0]["text"] == "hello"
    finally:
        server.shutdown()
        server_thread.join(timeout=2)
        transcriber._reset_runtime_state_for_tests()  # noqa: SLF001
