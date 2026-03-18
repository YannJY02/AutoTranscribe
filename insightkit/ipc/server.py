"""Unix domain socket JSON-RPC sidecar for InsightKit."""

from __future__ import annotations

import json
import logging
import os
import socket
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from insightkit.data.store import InsightStore
from insightkit.insights.service import InsightService
from insightkit.ipc.asr_dispatcher import ASRDispatcher
from insightkit.ipc.insight_coord import InsightCoordinator
from insightkit.ipc.job_queue import JobQueue
from insightkit.ipc.provider_probe import ProviderProbe
from insightkit.ipc.push_broker import PushBroker
from insightkit.ipc.session_handler import SessionHandler
from insightkit.ipc.watch_bridge import WatchBridge

logger = logging.getLogger(__name__)

DEFAULT_SOCKET = Path("/tmp/insightkit.sock")


class InsightRPCServer:
    def __init__(
        self,
        socket_path: Path = DEFAULT_SOCKET,
        store: InsightStore | None = None,
        insight_service: InsightService | None = None,
    ):
        self.socket_path = socket_path
        self.store = store or InsightStore()
        self.store.init_schema()
        self.insight_service = insight_service or InsightService()
        self._server_socket: socket.socket | None = None
        self._active = False
        self._started_at = datetime.now(timezone.utc)
        self._build = os.getenv("INSIGHTKIT_BUILD", datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S"))
        self._version = os.getenv("INSIGHTKIT_VERSION", "0.1.0")
        self._last_error_code = ""
        self._last_latency_ms = 0

        # Delegate modules.
        self._push_broker = PushBroker()
        self._session_handler = SessionHandler(store=self.store)
        self._insight_coord = InsightCoordinator(store=self.store, insight_service=self.insight_service)
        self._asr_dispatcher = ASRDispatcher()
        self._provider_probe = ProviderProbe(insight_service=self.insight_service)
        self._watch_bridge = WatchBridge()
        self._job_queue = JobQueue(
            store=self.store,
            insight_service=self.insight_service,
            watch_bridge=self._watch_bridge,
            push_broker=self._push_broker,
        )

    def serve_forever(self) -> None:
        if self.socket_path.exists():
            self.socket_path.unlink()

        self._server_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._server_socket.bind(str(self.socket_path))
        self._server_socket.listen(5)
        self._active = True
        logger.info("InsightKit sidecar listening on %s", self.socket_path)

        while self._active:
            try:
                conn, _ = self._server_socket.accept()
            except OSError:
                if not self._active:
                    break
                continue
            threading.Thread(target=self._handle_conn, args=(conn,), daemon=True).start()

    def shutdown(self) -> None:
        self._active = False
        self._job_queue.shutdown()
        if self._server_socket is not None:
            self._server_socket.close()
        if self.socket_path.exists():
            self.socket_path.unlink()
        self.store.close()

    def _handle_conn(self, conn: socket.socket) -> None:
        with conn:
            try:
                reader = conn.makefile("rb")
                first_line = reader.readline()
                if not first_line:
                    return
                first_msg = json.loads(first_line.decode("utf-8"))

                if "insightkit" in first_msg:
                    self._handle_persistent(conn, reader, first_msg)
                else:
                    self._handle_legacy(conn, first_msg)
            except Exception as exc:
                logger.debug("connection handler error: %s", exc)

    def _handle_legacy(self, conn: socket.socket, first_msg: dict[str, Any]) -> None:
        try:
            response = self._dispatch(first_msg)
        except Exception as exc:
            self._last_error_code = "bad_request"
            response = {"id": None, "error": {"code": -32000, "message": str(exc)}}
        try:
            conn.sendall(json.dumps(response, ensure_ascii=False).encode("utf-8"))
        except (BrokenPipeError, ConnectionResetError, OSError):
            logger.debug("legacy client disconnected before response send")

    def _handle_persistent(self, conn: socket.socket, reader: Any, handshake: dict[str, Any]) -> None:
        # Send handshake confirmation
        ack = json.dumps(
            {"insightkit": handshake.get("insightkit", "1.0"), "push": True},
            ensure_ascii=False, separators=(",", ":"),
        ) + "\n"
        conn.sendall(ack.encode("utf-8"))

        self._push_broker.register(conn)
        try:
            while self._active:
                line = reader.readline()
                if not line:
                    break
                try:
                    req = json.loads(line.decode("utf-8"))
                except (json.JSONDecodeError, UnicodeDecodeError) as exc:
                    err_resp = json.dumps(
                        {"id": None, "error": {"code": -32700, "message": str(exc)}},
                        ensure_ascii=False, separators=(",", ":"),
                    ) + "\n"
                    conn.sendall(err_resp.encode("utf-8"))
                    continue
                response = self._dispatch(req)
                resp_line = json.dumps(
                    response, ensure_ascii=False, separators=(",", ":"),
                ) + "\n"
                conn.sendall(resp_line.encode("utf-8"))
        except (BrokenPipeError, ConnectionResetError, OSError):
            logger.debug("persistent client disconnected")
        finally:
            self._push_broker.unregister(conn)

    def _dispatch(self, req: dict[str, Any]) -> dict[str, Any]:
        started_at = time.perf_counter()
        method = req.get("method", "")
        params = req.get("params", {})
        req_id = req.get("id")

        handlers = {
            "session.start": self._session_start,
            "session.stop": self._session_stop,
            "stream.push_audio": self._stream_push_audio,
            "transcript.delta": self._transcript_delta,
            "transcript.list": self._transcript_list,
            "insight.refresh_live": self._insight_refresh_live,
            "insight.build_final": self._insight_build_final,
            "document.export": self._document_export,
            "sidecar.status": self._sidecar_status,
            "sidecar.version": self._sidecar_version,
            "sidecar.shutdown": self._sidecar_shutdown,
            "sidecar.ensure_ready": self._sidecar_ensure_ready,
            "asr.runtime.status": self._asr_runtime_status,
            "asr.runtime.bootstrap": self._asr_runtime_bootstrap,
            "asr.prewarm": self._asr_prewarm,
            "asr.transcribe_chunk": self._asr_transcribe_chunk,
            "analysis.providers.status": self._analysis_providers_status,
            "analysis.provider.probe": self._analysis_provider_probe,
            "diagnostics.quick_check": self._diagnostics_quick_check,
            "live.session.start": self._live_session_start,
            "live.session.stop": self._live_session_stop,
            "live.session.status": self._live_session_status,
            "transcription.import_file": self._transcription_import_file,
            "transcription.watch.start": self._transcription_watch_start,
            "transcription.watch.stop": self._transcription_watch_stop,
            "transcription.status": self._transcription_status,
            "transcription.cancel_job": self._transcription_cancel_job,
            "module.capabilities": self._module_capabilities,
            "module.run": self._module_run,
            "records.save": self._records_save,
        }
        if method not in handlers:
            self._last_error_code = "method_not_found"
            self._last_latency_ms = int((time.perf_counter() - started_at) * 1000)
            return {"id": req_id, "error": {"code": -32601, "message": f"method not found: {method}"}}

        try:
            result = handlers[method](params)
            self._last_error_code = ""
            self._last_latency_ms = int((time.perf_counter() - started_at) * 1000)
            return {"id": req_id, "result": result}
        except Exception as exc:
            self._last_error_code = "handler_exception"
            self._last_latency_ms = int((time.perf_counter() - started_at) * 1000)
            return {"id": req_id, "error": {"code": -32010, "message": str(exc)}}

    # ── SessionHandler delegates ──────────────────────────────────────

    def _session_start(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._session_handler.session_start(params)

    def _session_stop(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._session_handler.session_stop(params)

    def _stream_push_audio(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._session_handler.stream_push_audio(params)

    def _transcript_delta(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._session_handler.transcript_delta(params)

    def _transcript_list(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._session_handler.transcript_list(params)

    def _live_session_start(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._session_handler.live_session_start(params)

    def _live_session_stop(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._session_handler.live_session_stop(params)

    def _live_session_status(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._session_handler.live_session_status(params)

    # ── InsightCoordinator delegates ──────────────────────────────────

    def _insight_refresh_live(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._insight_coord.insight_refresh_live(params)

    def _insight_build_final(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._insight_coord.insight_build_final(params)

    def _document_export(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._insight_coord.document_export(params)

    # ── ASRDispatcher delegates ───────────────────────────────────────

    def _asr_runtime_status(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._asr_dispatcher.asr_runtime_status(params)

    def _asr_runtime_bootstrap(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._asr_dispatcher.asr_runtime_bootstrap(params)

    def _asr_prewarm(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._asr_dispatcher.asr_prewarm(params)

    def _asr_transcribe_chunk(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._asr_dispatcher.asr_transcribe_chunk(params)

    # ── ProviderProbe delegates ───────────────────────────────────────

    def _analysis_providers_status(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._provider_probe.analysis_providers_status(params)

    def _analysis_provider_probe(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._provider_probe.analysis_provider_probe(params)

    def _diagnostics_quick_check(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._provider_probe.diagnostics_quick_check(
            params, sidecar_status_fn=lambda: self._sidecar_status({}),
        )

    # ── JobQueue delegates ────────────────────────────────────────────

    def _transcription_import_file(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._job_queue.transcription_import_file(params)

    def _transcription_watch_start(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._job_queue.transcription_watch_start(params)

    def _transcription_watch_stop(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._job_queue.transcription_watch_stop(params)

    def _transcription_status(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._job_queue.transcription_status(params)

    def _transcription_cancel_job(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._job_queue.transcription_cancel_job(params)

    # ── Sidecar self-status (kept in server) ──────────────────────────

    def _sidecar_status(self, params: dict[str, Any]) -> dict[str, Any]:
        _ = params
        return {
            "running": self._active,
            "pid": os.getpid(),
            "version": self._version,
            "build": self._build,
            "socket_path": str(self.socket_path),
            "uptime_sec": int((datetime.now(timezone.utc) - self._started_at).total_seconds()),
            "live_sessions": len([s for s in self._session_handler._live_sessions.values() if s.get("state") == "running"]),
            "ready": self._active and self._server_socket is not None,
            "python_executable": sys.executable,
            "python_version": sys.version.split()[0],
            "last_error_code": self._last_error_code,
            "last_latency_ms": self._last_latency_ms,
        }

    def _sidecar_version(self, params: dict[str, Any]) -> dict[str, Any]:
        _ = params
        return {
            "version": self._version,
            "build": self._build,
            "capabilities": self._module_capabilities({}).get("actions", []),
        }

    def _sidecar_shutdown(self, params: dict[str, Any]) -> dict[str, Any]:
        _ = params
        threading.Thread(target=self._shutdown_async, daemon=True).start()
        return {"ok": True, "shutting_down": True}

    def _shutdown_async(self) -> None:
        time.sleep(0.1)
        self.shutdown()

    def _sidecar_ensure_ready(self, params: dict[str, Any]) -> dict[str, Any]:
        timeout_sec = max(1, int(params.get("timeout_sec", 6)))
        deadline = time.time() + timeout_sec
        while time.time() <= deadline:
            status = self._sidecar_status({})
            if status.get("ready"):
                return {"ready": True, "status": status}
            time.sleep(0.1)
        raise RuntimeError(f"sidecar not ready within {timeout_sec}s")

    # ── Module bridge (kept in server) ────────────────────────────────

    @staticmethod
    def _module_capabilities(params: dict[str, Any]) -> dict[str, Any]:
        _ = params
        return {
            "module_id": "insightkit.meeting.module",
            "version": "0.1.0",
            "actions": [
                "session.start",
                "session.stop",
                "transcript.delta",
                "transcript.list",
                "insight.refresh_live",
                "insight.build_final",
                "document.export",
                "sidecar.status",
                "sidecar.version",
                "sidecar.shutdown",
                "sidecar.ensure_ready",
                "asr.runtime.status",
                "asr.runtime.bootstrap",
                "asr.prewarm",
                "asr.transcribe_chunk",
                "analysis.providers.status",
                "analysis.provider.probe",
                "diagnostics.quick_check",
                "live.session.start",
                "live.session.stop",
                "live.session.status",
                "transcription.import_file",
                "transcription.watch.start",
                "transcription.watch.stop",
                "transcription.status",
                "transcription.cancel_job",
                "records.save",
            ],
            "transport": "unix_socket_jsonrpc",
        }

    def _records_save(self, params: dict[str, Any]) -> dict[str, Any]:
        from insightkit.records.record_writer import RecordWriter, detect_media_type, detect_duration
        import os
        meeting_id = str(params.get("meeting_id", "") or "").strip()
        if not meeting_id:
            raise ValueError("meeting_id is required")
        title = str(params.get("title", "") or meeting_id)
        source_path = str(params.get("source_path", "") or "")
        segments = params.get("segments") or []
        insight_package = params.get("insight_package") or None
        media_type = str(params.get("media_type", "") or "") or detect_media_type(source_path)
        record_source = str(params.get("record_source", "") or "live")
        duration_sec = float(params.get("duration_sec") or detect_duration(segs=segments))
        notes_md = str(params.get("notes_md", "") or "")
        records_root = os.getenv("INSIGHTKIT_RECORDS_ROOT", str(
            __import__("pathlib").Path.home() / "Documents" / "InsightKit" / "Records"
        ))
        record_path = RecordWriter().write_record(
            root_dir=records_root,
            meeting_id=meeting_id,
            title=title,
            source_path=source_path,
            segments=segments,
            insight_package=insight_package,
            media_type=media_type,
            record_source=record_source,
            duration_sec=duration_sec,
            notes_md=notes_md,
        )
        return {"ok": True, "record_path": str(record_path)}

    def _module_run(self, params: dict[str, Any]) -> dict[str, Any]:
        action = params.get("action", "insight.build_final")
        meeting_id = params.get("meeting_id", "")
        payload = params.get("payload", {}) or {}

        if action == "session.start":
            return self._session_start({
                "meeting_id": meeting_id,
                "title": payload.get("title", "Module Session"),
                "source": payload.get("source", "file"),
            })
        if action == "session.stop":
            return self._session_stop({"meeting_id": meeting_id})
        if action == "transcript.delta":
            return self._transcript_delta({
                "meeting_id": meeting_id,
                "segments": payload.get("segments", []),
            })
        if action == "transcript.list":
            return self._transcript_list({
                "meeting_id": meeting_id,
                "limit": int(payload.get("limit", 1000)),
            })
        if action == "insight.refresh_live":
            return self._insight_refresh_live({
                "meeting_id": meeting_id,
                "window_sec": int(payload.get("window_sec", 120)),
                "provider_vendor": payload.get("provider_vendor", ""),
                "provider_model": payload.get("provider_model", ""),
                "strict_mode": payload.get("strict_mode"),
            })
        if action == "insight.build_final":
            return self._insight_build_final({
                "meeting_id": meeting_id,
                "provider_vendor": payload.get("provider_vendor", ""),
                "provider_model": payload.get("provider_model", ""),
                "strict_mode": payload.get("strict_mode"),
            })
        if action == "document.export":
            return self._document_export({
                "meeting_id": meeting_id,
                "format": payload.get("format", "markdown"),
                "output_dir": payload.get("output_dir", "txt"),
            })
        if action == "sidecar.status":
            return self._sidecar_status({})
        if action == "sidecar.version":
            return self._sidecar_version({})
        if action == "sidecar.shutdown":
            return self._sidecar_shutdown({})
        if action == "sidecar.ensure_ready":
            return self._sidecar_ensure_ready({
                "timeout_sec": int(payload.get("timeout_sec", 6)),
            })
        if action == "asr.runtime.status":
            return self._asr_runtime_status({
                "engine": payload.get("engine", ""),
            })
        if action == "asr.runtime.bootstrap":
            return self._asr_runtime_bootstrap({
                "model": payload.get("model", ""),
                "engine": payload.get("engine", ""),
            })
        if action == "asr.prewarm":
            return self._asr_prewarm({
                "model": payload.get("model", ""),
                "engine": payload.get("engine", ""),
                "timeout_sec": int(payload.get("timeout_sec", 20)),
            })
        if action == "asr.transcribe_chunk":
            return self._asr_transcribe_chunk({
                "wav_path": payload.get("wav_path", ""),
                "offset_ms": int(payload.get("offset_ms", 0)),
                "source": payload.get("source", ""),
            })
        if action == "analysis.providers.status":
            return self._analysis_providers_status({
                "probe_active": bool(payload.get("probe_active", False)),
                "probe_timeout_sec": int(payload.get("probe_timeout_sec", 6)),
            })
        if action == "analysis.provider.probe":
            return self._analysis_provider_probe({
                "provider_vendor": payload.get("provider_vendor", ""),
                "provider_model": payload.get("provider_model", ""),
                "base_url": payload.get("base_url", ""),
                "force_refresh": payload.get("force_refresh", True),
                "probe_timeout_sec": int(payload.get("probe_timeout_sec", 12)),
            })
        if action == "diagnostics.quick_check":
            return self._diagnostics_quick_check({
                "probe_timeout_sec": int(payload.get("probe_timeout_sec", 6)),
            })
        if action == "live.session.start":
            return self._live_session_start({
                "meeting_id": meeting_id,
                "title": payload.get("title", "Live Session"),
                "source": payload.get("source", "mixed"),
            })
        if action == "live.session.stop":
            return self._live_session_stop({"meeting_id": meeting_id})
        if action == "live.session.status":
            return self._live_session_status({"meeting_id": meeting_id})
        if action == "transcription.import_file":
            return self._transcription_import_file({
                "file_path": payload.get("file_path", ""),
                "title": payload.get("title", ""),
                "meeting_id": meeting_id or payload.get("meeting_id", ""),
            })
        if action == "transcription.watch.start":
            return self._transcription_watch_start({
                "dirs": payload.get("dirs", []),
            })
        if action == "transcription.watch.stop":
            return self._transcription_watch_stop({})
        if action == "transcription.status":
            return self._transcription_status({})
        if action == "transcription.cancel_job":
            return self._transcription_cancel_job({
                "job_id": payload.get("job_id", ""),
                "reason": payload.get("reason", ""),
            })
        raise ValueError(f"unsupported module action: {action}")


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
    socket_path = Path(os.getenv("INSIGHTKIT_SOCKET", str(DEFAULT_SOCKET)))
    server = InsightRPCServer(socket_path=socket_path)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.shutdown()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
