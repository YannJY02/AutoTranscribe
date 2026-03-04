"""Unix domain socket JSON-RPC sidecar for InsightKit."""

from __future__ import annotations

import json
import logging
import os
import socket
import sys
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from insightkit.data.store import InsightStore
from insightkit.insights.provider import providers_status
from insightkit.insights.render import render_insight_markdown
from insightkit.insights.service import InsightService
from insightkit.ipc.watch_bridge import WatchBridge
from scripts.asr_runtime_bootstrap import bootstrap_runtime, runtime_status
from scripts.transcriber import transcribe_audio_chunk
from scripts.transcription_runner import JobCancelled, run_transcription_job

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
        self._live_sessions: dict[str, dict[str, Any]] = {}

        # Transcription pipeline runtime.
        self._tx_lock = threading.RLock()
        self._tx_queue: list[str] = []
        self._tx_jobs: dict[str, dict[str, Any]] = {}
        self._tx_cancel_events: dict[str, threading.Event] = {}
        self._tx_active_job_id: str | None = None
        self._tx_last_completed: dict[str, Any] | None = None
        self._tx_worker: threading.Thread | None = None
        self._tx_worker_stop = threading.Event()
        self._watch_bridge = WatchBridge()
        self._provider_probe_cache: dict[str, dict[str, Any]] = {}
        self._provider_probe_lock = threading.Lock()
        self._provider_probe_ttl_sec = max(5, int(os.getenv("INSIGHTKIT_PROVIDER_PROBE_TTL_SEC", "30")))
        self._last_error_code = ""
        self._last_latency_ms = 0

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
        self._watch_bridge.stop()
        self._tx_worker_stop.set()
        if self._tx_worker is not None and self._tx_worker.is_alive():
            self._tx_worker.join(timeout=2.0)
        if self._server_socket is not None:
            self._server_socket.close()
        if self.socket_path.exists():
            self.socket_path.unlink()
        self.store.close()

    def _handle_conn(self, conn: socket.socket) -> None:
        with conn:
            try:
                data = conn.recv(4 * 1024 * 1024)
                if not data:
                    return
                req = json.loads(data.decode("utf-8"))
                response = self._dispatch(req)
            except Exception as exc:
                self._last_error_code = "bad_request"
                response = {"id": None, "error": {"code": -32000, "message": str(exc)}}
            try:
                conn.sendall(json.dumps(response, ensure_ascii=False).encode("utf-8"))
            except (BrokenPipeError, ConnectionResetError):
                logger.debug("client disconnected before response send")
            except OSError as exc:
                logger.debug("socket send failed: %s", exc)

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

    def _session_start(self, params: dict[str, Any]) -> dict[str, Any]:
        meeting_id = params.get("meeting_id") or str(uuid.uuid4())
        title = params.get("title") or "未命名会话"
        source = params.get("source") or "file"
        self.store.upsert_meeting(meeting_id, title, source, status="recording")
        self._live_sessions[meeting_id] = {
            "meeting_id": meeting_id,
            "title": title,
            "source": source,
            "state": "running",
            "started_at": datetime.now(timezone.utc).isoformat(),
        }
        return {"meeting_id": meeting_id, "status": "recording"}

    def _session_stop(self, params: dict[str, Any]) -> dict[str, Any]:
        meeting_id = params["meeting_id"]
        stopped_at = datetime.now(timezone.utc).isoformat()
        if meeting_id in self._live_sessions:
            self._live_sessions[meeting_id]["state"] = "stopped"
            self._live_sessions[meeting_id]["stopped_at"] = stopped_at
        self.store.update_meeting_status(meeting_id, "stopped")
        return {"meeting_id": meeting_id, "status": "stopped", "stopped_at": stopped_at}

    def _stream_push_audio(self, params: dict[str, Any]) -> dict[str, Any]:
        # V1: transport-only placeholder. ASR ingestion remains in Python transcribe pipeline.
        _ = params
        return {"accepted": True}

    def _transcript_delta(self, params: dict[str, Any]) -> dict[str, Any]:
        meeting_id = params["meeting_id"]
        segments = params.get("segments", [])
        ingested = 0
        for seg in segments:
            text = str(seg.get("text", "")).strip()
            if not text:
                continue
            self.store.insert_segment(
                meeting_id=meeting_id,
                start_ms=int(seg.get("start_ms", 0)),
                end_ms=int(seg.get("end_ms", 0)),
                speaker=str(seg.get("speaker", "")),
                source=str(seg.get("source", "")),
                text=text,
                confidence=float(seg.get("confidence", 0.0)),
            )
            ingested += 1
        return {"ingested": ingested}

    def _transcript_list(self, params: dict[str, Any]) -> dict[str, Any]:
        meeting_id = params["meeting_id"]
        limit = int(params.get("limit", 1000))
        rows = self.store.list_segments(meeting_id)
        if limit > 0 and len(rows) > limit:
            rows = rows[-limit:]
        return {"meeting_id": meeting_id, "segments": rows}

    def _insight_refresh_live(self, params: dict[str, Any]) -> dict[str, Any]:
        meeting_id = params["meeting_id"]
        window_sec = int(params.get("window_sec", 120))
        window_ms = window_sec * 1000
        provider_vendor = str(params.get("provider_vendor", "") or "").strip() or None
        provider_model = str(params.get("provider_model", "") or "").strip() or None
        strict_mode_raw = params.get("strict_mode")
        strict_mode = None if strict_mode_raw is None else bool(strict_mode_raw)

        segments = self.store.list_segments(meeting_id)
        if segments:
            end = segments[-1]["end_ms"]
            start = max(0, end - window_ms)
            segments = [s for s in segments if s["end_ms"] >= start]

        package = self.insight_service.build_live(
            segments,
            provider_vendor=provider_vendor,
            provider_model=provider_model,
            strict_mode=strict_mode,
        )
        call_meta = self.insight_service.last_call_meta
        return {
            "meeting_id": meeting_id,
            "mode": "live",
            "insight_package": package,
            "provider": str(call_meta.get("vendor", "")),
            "provider_vendor": str(call_meta.get("vendor", "")),
            "provider_model": str(call_meta.get("model", "")),
            "strict_mode": bool(call_meta.get("strict_mode", False)),
            "needs_review_count": self._count_needs_review(package),
            "updated_at": datetime.now(timezone.utc).isoformat(),
        }

    def _insight_build_final(self, params: dict[str, Any]) -> dict[str, Any]:
        meeting_id = params["meeting_id"]
        provider_vendor = str(params.get("provider_vendor", "") or "").strip() or None
        provider_model = str(params.get("provider_model", "") or "").strip() or None
        strict_mode_raw = params.get("strict_mode")
        strict_mode = None if strict_mode_raw is None else bool(strict_mode_raw)
        segments = self.store.list_segments(meeting_id)
        package = self.insight_service.build_final(
            segments,
            provider_vendor=provider_vendor,
            provider_model=provider_model,
            strict_mode=strict_mode,
        )
        call_meta = self.insight_service.last_call_meta
        return {
            "meeting_id": meeting_id,
            "mode": "final",
            "insight_package": package,
            "provider": str(call_meta.get("vendor", "")),
            "provider_vendor": str(call_meta.get("vendor", "")),
            "provider_model": str(call_meta.get("model", "")),
            "strict_mode": bool(call_meta.get("strict_mode", False)),
            "needs_review_count": self._count_needs_review(package),
            "updated_at": datetime.now(timezone.utc).isoformat(),
        }

    def _document_export(self, params: dict[str, Any]) -> dict[str, Any]:
        meeting_id = params["meeting_id"]
        export_format = params.get("format", "markdown")
        output_dir = Path(params.get("output_dir", "txt"))
        output_dir.mkdir(parents=True, exist_ok=True)
        meeting = self.store.get_meeting(meeting_id) or {}
        title = str(meeting.get("title", "未命名会话") or "未命名会话")
        segments = self.store.list_segments(meeting_id)
        package = self.insight_service.build_final(segments)
        rendered = render_insight_markdown(package, title=title)

        ts = int(time.time())
        if export_format == "json":
            out = output_dir / f"{meeting_id}_{ts}.json"
            out.write_text(json.dumps(package, ensure_ascii=False, indent=2), encoding="utf-8")
        elif export_format == "txt":
            out = output_dir / f"{meeting_id}_{ts}.txt"
            out.write_text(rendered, encoding="utf-8")
        else:
            out = output_dir / f"{meeting_id}_{ts}.md"
            out.write_text(rendered, encoding="utf-8")
        return {
            "path": str(out),
            "format": export_format,
            "meeting_id": meeting_id,
            "mode": "final",
        }

    def _sidecar_status(self, params: dict[str, Any]) -> dict[str, Any]:
        _ = params
        return {
            "running": self._active,
            "pid": os.getpid(),
            "version": self._version,
            "build": self._build,
            "socket_path": str(self.socket_path),
            "uptime_sec": int((datetime.now(timezone.utc) - self._started_at).total_seconds()),
            "live_sessions": len([s for s in self._live_sessions.values() if s.get("state") == "running"]),
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

    def _asr_runtime_status(self, params: dict[str, Any]) -> dict[str, Any]:
        engine = str(params.get("engine", "") or "").strip() or None
        return runtime_status(engine=engine)

    def _asr_runtime_bootstrap(self, params: dict[str, Any]) -> dict[str, Any]:
        model = str(params.get("model", "") or "").strip() or None
        engine = str(params.get("engine", "") or "").strip() or None
        return bootstrap_runtime(model_name=model, engine=engine)

    def _asr_transcribe_chunk(self, params: dict[str, Any]) -> dict[str, Any]:
        wav_path = str(params.get("wav_path", "") or "").strip()
        if not wav_path:
            raise ValueError("wav_path is required")
        offset_ms = int(params.get("offset_ms", 0))
        source = str(params.get("source", "") or "").strip() or "mixed"
        segments = transcribe_audio_chunk(Path(wav_path).expanduser().resolve(), offset_ms=offset_ms)
        for seg in segments:
            seg["source"] = source
        return {"segments": segments}

    def _analysis_providers_status(self, params: dict[str, Any]) -> dict[str, Any]:
        probe_active = bool(params.get("probe_active", False))
        try:
            probe_timeout_sec = max(1, min(30, int(params.get("probe_timeout_sec", 6))))
        except Exception:
            probe_timeout_sec = 6
        status = providers_status(probe_active=False)
        status["active_probe_ok"] = None
        status["active_probe_error_code"] = ""
        status["active_probe_message"] = ""

        if not probe_active:
            return status

        active_vendor = str(status.get("selected_vendor", "openai"))
        vendors = status.get("vendors", {})
        active = vendors.get(active_vendor, {})
        if not bool(active.get("configured", False)):
            status["active_probe_ok"] = False
            status["active_probe_error_code"] = "missing_configuration"
            status["active_probe_message"] = "当前服务缺少 API Key 或模型名称。"
            return status

        probe, timed_out = self._probe_provider_with_timeout(
            vendor=active_vendor,
            model=str(active.get("model_id", "")),
            base_url=str(active.get("base_url", "")),
            force_refresh=False,
            timeout_sec=probe_timeout_sec,
        )
        if timed_out:
            status["active_probe_ok"] = False
            status["active_probe_error_code"] = "probe_timeout"
            status["active_probe_message"] = "智能分析探测超时，请稍后重试。"
            return status

        status["active_probe_ok"] = bool(probe.get("ok", False))
        status["active_probe_error_code"] = str(probe.get("code", ""))
        status["active_probe_message"] = str(probe.get("message", ""))
        return status

    def _analysis_provider_probe(self, params: dict[str, Any]) -> dict[str, Any]:
        vendor = str(params.get("provider_vendor", "") or "").strip()
        model = str(params.get("provider_model", "") or "").strip()
        base_url = str(params.get("base_url", "") or "").strip()
        force_refresh = bool(params.get("force_refresh", True))
        try:
            probe_timeout_sec = max(1, min(30, int(params.get("probe_timeout_sec", 12))))
        except Exception:
            probe_timeout_sec = 12

        if not vendor:
            vendor = os.getenv("INSIGHTKIT_PROVIDER_VENDOR", "openai").strip().lower() or "openai"
        if not model:
            model = os.getenv("INSIGHTKIT_PROVIDER_MODEL", "").strip()

        probe, _ = self._probe_provider_with_timeout(
            vendor=vendor,
            model=model,
            base_url=base_url,
            force_refresh=force_refresh,
            timeout_sec=probe_timeout_sec,
        )
        return probe

    def _probe_provider_cached(
        self,
        vendor: str,
        model: str,
        base_url: str,
        force_refresh: bool,
    ) -> dict[str, Any]:
        key = f"{vendor}|{model}|{base_url}".lower()
        now = time.time()
        if not force_refresh:
            with self._provider_probe_lock:
                cached = self._provider_probe_cache.get(key)
                if cached is not None and (now - float(cached.get("_ts", 0.0))) <= self._provider_probe_ttl_sec:
                    return {k: v for k, v in cached.items() if k != "_ts"}

        probe = self.insight_service.probe_provider(
            provider_vendor=vendor,
            provider_model=model,
            base_url=base_url or None,
        )
        with self._provider_probe_lock:
            self._provider_probe_cache[key] = {**probe, "_ts": now}
        return probe

    def _probe_provider_with_timeout(
        self,
        vendor: str,
        model: str,
        base_url: str,
        force_refresh: bool,
        timeout_sec: int,
    ) -> tuple[dict[str, Any], bool]:
        result_holder: dict[str, Any] = {}
        error_holder: dict[str, Exception] = {}

        def worker() -> None:
            try:
                result_holder["probe"] = self._probe_provider_cached(
                    vendor=vendor,
                    model=model,
                    base_url=base_url,
                    force_refresh=force_refresh,
                )
            except Exception as exc:  # noqa: BLE001
                error_holder["error"] = exc

        thread = threading.Thread(target=worker, daemon=True)
        thread.start()
        thread.join(timeout=max(1, timeout_sec))
        if thread.is_alive():
            return {
                "ok": False,
                "code": "probe_timeout",
                "message": "智能分析探测超时，请稍后重试。",
                "hint": "网络较慢时可先开始转写，稍后重试分析服务探测。",
            }, True
        if "error" in error_holder:
            raise error_holder["error"]
        return result_holder.get("probe", {
            "ok": False,
            "code": "unknown",
            "message": "智能分析探测失败。",
            "hint": "请检查服务地址与模型名称。",
        }), False

    def _diagnostics_quick_check(self, params: dict[str, Any]) -> dict[str, Any]:
        try:
            probe_timeout_sec = max(1, min(30, int(params.get("probe_timeout_sec", 6))))
        except Exception:
            probe_timeout_sec = 6
        checks: list[dict[str, Any]] = []

        sidecar = self._sidecar_status({})
        checks.append({
            "id": "sidecar",
            "title": "侧车服务",
            "status": "pass" if sidecar.get("ready") else "fail",
            "action_hint": "重启侧车服务",
            "details": f"pid={sidecar.get('pid')} ready={sidecar.get('ready')}",
            "timed_out": False,
        })

        asr = runtime_status()
        checks.append({
            "id": "asr_runtime",
            "title": "本地语音识别",
            "status": "pass" if asr.get("ready") else "fail",
            "action_hint": "执行一键修复语音识别",
            "details": f"engine={asr.get('engine')} model={asr.get('model', {}).get('name', '')}",
            "timed_out": False,
        })

        providers = providers_status(probe_active=False)
        active_vendor = providers.get("selected_vendor", "openai")
        checks.append({
            "id": "analysis_provider",
            "title": "智能分析服务",
            "status": "pass" if providers.get("active_ready") else "fail",
            "action_hint": "检查模型名称和 API Key",
            "details": f"vendor={active_vendor} ready={providers.get('active_ready')}",
            "timed_out": False,
        })

        active_vendor_payload = providers.get("vendors", {}).get(active_vendor, {})
        if bool(active_vendor_payload.get("configured", False)):
            probe, timed_out = self._probe_provider_with_timeout(
                vendor=str(active_vendor),
                model=str(active_vendor_payload.get("model_id", "")),
                base_url=str(active_vendor_payload.get("base_url", "")),
                force_refresh=False,
                timeout_sec=probe_timeout_sec,
            )
            checks.append({
                "id": "analysis_provider_probe",
                "title": "智能分析鉴权探测",
                "status": "warn" if timed_out else ("pass" if probe.get("ok") else "fail"),
                "action_hint": "网络较慢，可先开始转写，稍后重试探测。" if timed_out else (str(probe.get("hint", "")) or "检查 API Key 与模型名称"),
                "details": f"vendor={active_vendor} code={probe.get('code', '')} message={probe.get('message', '')}",
                "timed_out": timed_out,
            })
        else:
            checks.append({
                "id": "analysis_provider_probe",
                "title": "智能分析鉴权探测",
                "status": "fail",
                "action_hint": "请先在设置中填写 API Key 与模型名称",
                "details": f"vendor={active_vendor} code=missing_configuration",
                "timed_out": False,
            })

        overall = "pass"
        if any(item["status"] == "fail" for item in checks):
            overall = "fail"
        elif any(item["status"] == "warn" for item in checks):
            overall = "warn"
        return {"overall": overall, "checks": checks}

    def _live_session_start(self, params: dict[str, Any]) -> dict[str, Any]:
        meeting_id = params.get("meeting_id") or str(uuid.uuid4())
        title = params.get("title") or "直播会话"
        source = params.get("source") or "mixed"
        self.store.upsert_meeting(meeting_id, title, source, status="recording")
        self._live_sessions[meeting_id] = {
            "meeting_id": meeting_id,
            "title": title,
            "source": source,
            "state": "running",
            "started_at": datetime.now(timezone.utc).isoformat(),
        }
        return {"meeting_id": meeting_id, "state": "running"}

    def _live_session_stop(self, params: dict[str, Any]) -> dict[str, Any]:
        stopped = self._session_stop(params)
        return {"meeting_id": stopped["meeting_id"], "state": "stopped", "stopped_at": stopped["stopped_at"]}

    def _live_session_status(self, params: dict[str, Any]) -> dict[str, Any]:
        meeting_id = params["meeting_id"]
        session = self._live_sessions.get(meeting_id)
        if session is None:
            meeting = self.store.get_meeting(meeting_id)
            if not meeting:
                return {"meeting_id": meeting_id, "state": "not_found", "segments": 0}
            session = {
                "meeting_id": meeting_id,
                "title": meeting.get("title", ""),
                "source": meeting.get("source", ""),
                "state": meeting.get("status", "unknown"),
            }
        return {
            "meeting_id": meeting_id,
            "state": session.get("state", "unknown"),
            "segments": self.store.count_segments(meeting_id),
            "source": session.get("source", ""),
            "title": session.get("title", ""),
            "started_at": session.get("started_at"),
            "stopped_at": session.get("stopped_at"),
            "updated_at": datetime.now(timezone.utc).isoformat(),
            "error_code": "",
        }

    def _transcription_import_file(self, params: dict[str, Any]) -> dict[str, Any]:
        file_path = str(params.get("file_path", "") or "").strip()
        if not file_path:
            raise ValueError("file_path is required")
        resolved = Path(file_path).expanduser().resolve()
        if not resolved.exists() or not resolved.is_file():
            raise FileNotFoundError(str(resolved))

        meeting_id = str(params.get("meeting_id") or f"file-{uuid.uuid4()}")
        title = str(params.get("title") or resolved.stem)
        job_id = str(uuid.uuid4())
        now = datetime.now(timezone.utc).isoformat()

        job = {
            "id": job_id,
            "meeting_id": meeting_id,
            "source_path": str(resolved),
            "title": title,
            "state": "queued",
            "progress": 0,
            "stage": "queued",
            "error": "",
            "reason": "",
            "started_at": now,
            "ended_at": "",
        }

        with self._tx_lock:
            self._tx_jobs[job_id] = job
            self._tx_cancel_events[job_id] = threading.Event()
            self._tx_queue.append(job_id)
            self.store.upsert_transcription_job(
                job_id=job_id,
                meeting_id=meeting_id,
                source_path=str(resolved),
                state="queued",
                progress=0,
                stage="queued",
                started_at=now,
            )
            self._ensure_transcription_worker_locked()

        return {"job_id": job_id, "meeting_id": meeting_id, "state": "queued"}

    def _transcription_watch_start(self, params: dict[str, Any]) -> dict[str, Any]:
        dirs = params.get("dirs") or []
        if not isinstance(dirs, list):
            raise ValueError("dirs must be array")
        if not dirs:
            dirs = [str(Path.home() / "Desktop"), str(Path.home() / "Downloads")]

        return self._watch_bridge.start(
            [str(Path(d).expanduser()) for d in dirs],
            on_file=self._enqueue_watch_file,
        )

    def _transcription_watch_stop(self, params: dict[str, Any]) -> dict[str, Any]:
        _ = params
        return self._watch_bridge.stop()

    def _transcription_status(self, params: dict[str, Any]) -> dict[str, Any]:
        raw_limit = params.get("limit", 100)
        try:
            limit = int(raw_limit)
        except (TypeError, ValueError):
            limit = 100
        limit = max(1, min(1000, limit))
        with self._tx_lock:
            jobs = [self._job_view(x) for x in self._tx_jobs.values()]
            jobs.sort(key=lambda x: x.get("started_at", ""), reverse=True)
            queue_views = [self._job_view(self._tx_jobs[x]) for x in self._tx_queue if x in self._tx_jobs]
            active = self._job_view(self._tx_jobs[self._tx_active_job_id]) if self._tx_active_job_id in self._tx_jobs else None
            last_completed = self._tx_last_completed

        return {
            "watcher": self._watch_bridge.status(),
            "queue": queue_views[:limit],
            "active_job": active,
            "last_completed": last_completed,
            "jobs": jobs[:limit],
        }

    def _transcription_cancel_job(self, params: dict[str, Any]) -> dict[str, Any]:
        job_id = str(params.get("job_id", "") or "").strip()
        if not job_id:
            raise ValueError("job_id is required")
        reason = str(params.get("reason", "") or "").strip()
        target_state = "paused_by_live" if reason == "preempted_by_live" else "cancelled"

        with self._tx_lock:
            job = self._tx_jobs.get(job_id)
            if job is None:
                raise ValueError(f"job not found: {job_id}")

            if job["state"] in {"completed", "failed", "cancelled", "paused_by_live"}:
                return {"job_id": job_id, "state": job["state"]}

            cancel_event = self._tx_cancel_events.get(job_id)
            if cancel_event is not None:
                cancel_event.set()

            job["reason"] = reason
            job["state"] = target_state
            job["stage"] = "cancelled"
            job["ended_at"] = datetime.now(timezone.utc).isoformat()
            if job_id in self._tx_queue:
                self._tx_queue.remove(job_id)

            self.store.upsert_transcription_job(
                job_id=job["id"],
                meeting_id=job["meeting_id"],
                source_path=job["source_path"],
                state=job["state"],
                progress=int(job["progress"]),
                stage=job["stage"],
                started_at=job["started_at"],
                error=job["error"],
                reason=job["reason"],
                ended_at=job["ended_at"],
            )

        return {"job_id": job_id, "state": target_state}

    def _enqueue_watch_file(self, file_path: str) -> None:
        try:
            self._transcription_import_file({
                "file_path": file_path,
                "title": Path(file_path).stem,
            })
        except Exception as exc:
            logger.warning("watch enqueue failed for %s: %s", file_path, exc)

    def _ensure_transcription_worker_locked(self) -> None:
        if self._tx_worker is not None and self._tx_worker.is_alive():
            return
        self._tx_worker_stop.clear()
        self._tx_worker = threading.Thread(target=self._transcription_worker_loop, name="InsightKitTxWorker", daemon=True)
        self._tx_worker.start()

    def _transcription_worker_loop(self) -> None:
        while not self._tx_worker_stop.is_set():
            job: dict[str, Any] | None = None
            cancel_event: threading.Event | None = None

            with self._tx_lock:
                next_id = None
                while self._tx_queue and next_id is None:
                    candidate = self._tx_queue.pop(0)
                    candidate_job = self._tx_jobs.get(candidate)
                    if candidate_job is None:
                        continue
                    if candidate_job.get("state") != "queued":
                        continue
                    next_id = candidate

                if next_id is None:
                    pass
                else:
                    job = self._tx_jobs[next_id]
                    cancel_event = self._tx_cancel_events.get(next_id)
                    self._tx_active_job_id = next_id
                    job["state"] = "running"
                    job["stage"] = "running"
                    job["progress"] = max(int(job.get("progress", 0)), 5)
                    self._persist_job_locked(job)

            if job is None:
                time.sleep(0.2)
                continue

            try:
                result = run_transcription_job(
                    file_path=job["source_path"],
                    meeting_id=job["meeting_id"],
                    store=self.store,
                    insight_service=self.insight_service,
                    cancel_event=cancel_event,
                    on_progress=lambda p, s, jid=job["id"]: self._update_job_progress(jid, p, s),
                )

                with self._tx_lock:
                    j = self._tx_jobs.get(job["id"], job)
                    if j.get("state") in {"cancelled", "paused_by_live"}:
                        self._persist_job_locked(j)
                    else:
                        j["state"] = "completed"
                        j["progress"] = 100
                        j["stage"] = "completed"
                        j["error"] = ""
                        j["ended_at"] = datetime.now(timezone.utc).isoformat()
                        self._persist_job_locked(j)
                        self._tx_last_completed = {
                            "job": self._job_view(j),
                            "meeting_id": result.get("meeting_id", j.get("meeting_id", "")),
                            "segments_count": int(result.get("segments_count", 0)),
                            "updated_at": datetime.now(timezone.utc).isoformat(),
                        }

            except JobCancelled:
                with self._tx_lock:
                    j = self._tx_jobs.get(job["id"], job)
                    if j.get("state") not in {"paused_by_live", "cancelled"}:
                        reason = j.get("reason", "")
                        j["state"] = "paused_by_live" if reason == "preempted_by_live" else "cancelled"
                    j["stage"] = "cancelled"
                    j["ended_at"] = datetime.now(timezone.utc).isoformat()
                    self._persist_job_locked(j)
            except Exception as exc:
                with self._tx_lock:
                    j = self._tx_jobs.get(job["id"], job)
                    j["state"] = "failed"
                    j["stage"] = "failed"
                    j["error"] = str(exc)
                    j["ended_at"] = datetime.now(timezone.utc).isoformat()
                    self._persist_job_locked(j)
                    self._tx_last_completed = {
                        "job": self._job_view(j),
                        "meeting_id": j.get("meeting_id", ""),
                        "segments_count": 0,
                        "updated_at": datetime.now(timezone.utc).isoformat(),
                    }
            finally:
                with self._tx_lock:
                    if self._tx_active_job_id == job["id"]:
                        self._tx_active_job_id = None

    def _update_job_progress(self, job_id: str, progress: int, stage: str) -> None:
        with self._tx_lock:
            job = self._tx_jobs.get(job_id)
            if job is None:
                return
            if job.get("state") not in {"running", "queued"}:
                return
            job["progress"] = int(max(0, min(100, progress)))
            job["stage"] = stage
            self._persist_job_locked(job)

    def _persist_job_locked(self, job: dict[str, Any]) -> None:
        self.store.upsert_transcription_job(
            job_id=job["id"],
            meeting_id=job["meeting_id"],
            source_path=job["source_path"],
            state=job["state"],
            progress=int(job.get("progress", 0)),
            stage=str(job.get("stage", "")),
            started_at=str(job.get("started_at", "")),
            error=str(job.get("error", "")),
            reason=str(job.get("reason", "")),
            ended_at=str(job.get("ended_at", "")),
        )

    @staticmethod
    def _job_view(job: dict[str, Any]) -> dict[str, Any]:
        return {
            "id": job.get("id", ""),
            "meeting_id": job.get("meeting_id", ""),
            "source_path": job.get("source_path", ""),
            "title": job.get("title", ""),
            "state": job.get("state", "unknown"),
            "progress": int(job.get("progress", 0)),
            "stage": job.get("stage", ""),
            "error": job.get("error", ""),
            "reason": job.get("reason", ""),
            "started_at": job.get("started_at", ""),
            "ended_at": job.get("ended_at", ""),
        }

    @staticmethod
    def _count_needs_review(payload: dict[str, Any]) -> int:
        count = 0
        for item in payload.get("decision_ledger", []):
            if item.get("needs_review") is True:
                count += 1
        for item in payload.get("action_tracks", []):
            if item.get("needs_review") is True:
                count += 1
        return count

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
            ],
            "transport": "unix_socket_jsonrpc",
        }

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
