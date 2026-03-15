# Phase 1: Python Sidecar 拆分 — 实施计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 把 `insightkit/ipc/server.py`（1090 行）拆成 5 个职责清晰的模块，不改 RPC 协议，Swift 端零改动。

**Architecture:** 提取 handler 方法到独立模块，每个模块是一个类，接收 `store` 和 `insight_service` 等依赖。`server.py` 瘦身为 socket 监听 + 请求路由入口，通过组合模式委托给各 handler 模块。

**Tech Stack:** Python 3.11, unittest, threading, Unix domain socket JSON-RPC

---

## 方法到模块的映射

| 模块 | RPC 方法 | server.py 中的方法 |
|------|----------|-------------------|
| `session_handler.py` | session.start, session.stop, stream.push_audio, transcript.delta, transcript.list, live.session.start, live.session.stop, live.session.status | _session_start, _session_stop, _stream_push_audio, _transcript_delta, _transcript_list, _live_session_start, _live_session_stop, _live_session_status |
| `insight_coord.py` | insight.refresh_live, insight.build_final, document.export | _insight_refresh_live, _insight_build_final, _document_export, _count_needs_review |
| `asr_dispatcher.py` | asr.runtime.status, asr.runtime.bootstrap, asr.prewarm, asr.transcribe_chunk | _asr_runtime_status, _asr_runtime_bootstrap, _asr_prewarm, _asr_transcribe_chunk |
| `job_queue.py` | transcription.import_file, transcription.status, transcription.cancel_job | _transcription_import_file, _transcription_status, _transcription_cancel_job, _enqueue_watch_file, _ensure_transcription_worker_locked, _transcription_worker_loop, _update_job_progress, _persist_job_locked, _job_view |
| `provider_probe.py` | analysis.providers.status, analysis.provider.probe, diagnostics.quick_check | _analysis_providers_status, _analysis_provider_probe, _probe_provider_cached, _probe_provider_with_timeout, _diagnostics_quick_check |

server.py 保留: __init__, serve_forever, shutdown, _handle_conn, _dispatch, _sidecar_status, _sidecar_version, _sidecar_shutdown, _shutdown_async, _sidecar_ensure_ready, _module_capabilities, _module_run, main


---

### Task 1: 提取 SessionHandler

**Files:**
- Create: `insightkit/ipc/session_handler.py`
- Create: `tests/test_session_handler.py`
- Modify: (暂不改 server.py，先独立验证模块)

**Step 1: Write the failing test**

```python
# tests/test_session_handler.py
import tempfile
import unittest
from pathlib import Path

from insightkit.data.store import InsightStore
from insightkit.ipc.session_handler import SessionHandler


class TestSessionHandler(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.store = InsightStore(Path(self.tmp) / "test.db")
        self.handler = SessionHandler(store=self.store)

    def test_session_start_returns_meeting_id(self):
        result = self.handler.session_start({"title": "test", "source": "mic"})
        self.assertIn("meeting_id", result)
        self.assertEqual(result["status"], "recording")

    def test_session_start_with_explicit_id(self):
        result = self.handler.session_start({"meeting_id": "m-1", "title": "demo", "source": "file"})
        self.assertEqual(result["meeting_id"], "m-1")

    def test_session_stop(self):
        self.handler.session_start({"meeting_id": "m-1", "title": "t", "source": "file"})
        result = self.handler.session_stop({"meeting_id": "m-1"})
        self.assertEqual(result["status"], "stopped")

    def test_transcript_delta_ingests_segments(self):
        self.handler.session_start({"meeting_id": "m-1", "title": "t", "source": "mic"})
        result = self.handler.transcript_delta({
            "meeting_id": "m-1",
            "segments": [
                {"start_ms": 0, "end_ms": 1000, "speaker": "spk0", "source": "mic", "text": "hello", "confidence": 0.9},
            ],
        })
        self.assertEqual(result["ingested"], 1)

    def test_transcript_list(self):
        self.handler.session_start({"meeting_id": "m-1", "title": "t", "source": "mic"})
        self.handler.transcript_delta({
            "meeting_id": "m-1",
            "segments": [
                {"start_ms": 0, "end_ms": 500, "speaker": "spk0", "source": "mic", "text": "a", "confidence": 0.8},
                {"start_ms": 600, "end_ms": 1000, "speaker": "spk0", "source": "mic", "text": "b", "confidence": 0.8},
            ],
        })
        result = self.handler.transcript_list({"meeting_id": "m-1", "limit": 1})
        self.assertEqual(len(result["segments"]), 1)

    def test_live_session_start_and_stop(self):
        result = self.handler.live_session_start({"meeting_id": "m-2", "title": "live", "source": "mixed"})
        self.assertEqual(result["state"], "running")
        stopped = self.handler.live_session_stop({"meeting_id": "m-2"})
        self.assertEqual(stopped["state"], "stopped")

    def test_live_session_status(self):
        self.handler.live_session_start({"meeting_id": "m-3", "title": "live", "source": "mixed"})
        status = self.handler.live_session_status({"meeting_id": "m-3"})
        self.assertEqual(status["state"], "running")
        self.assertEqual(status["meeting_id"], "m-3")

    def test_stream_push_audio_accepted(self):
        result = self.handler.stream_push_audio({})
        self.assertTrue(result["accepted"])


if __name__ == "__main__":
    unittest.main()
```

**Step 2: Run test to verify it fails**

Run: `python3 -m pytest tests/test_session_handler.py -v`
Expected: FAIL with "ModuleNotFoundError: No module named 'insightkit.ipc.session_handler'"

**Step 3: Write minimal implementation**

```python
# insightkit/ipc/session_handler.py
"""Session and transcript handler for InsightKit RPC."""

from __future__ import annotations

import uuid
from datetime import datetime, timezone
from typing import Any

from insightkit.data.store import InsightStore


class SessionHandler:
    def __init__(self, store: InsightStore):
        self.store = store
        self._live_sessions: dict[str, dict[str, Any]] = {}

    def session_start(self, params: dict[str, Any]) -> dict[str, Any]:
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

    def session_stop(self, params: dict[str, Any]) -> dict[str, Any]:
        meeting_id = params["meeting_id"]
        stopped_at = datetime.now(timezone.utc).isoformat()
        if meeting_id in self._live_sessions:
            self._live_sessions[meeting_id]["state"] = "stopped"
            self._live_sessions[meeting_id]["stopped_at"] = stopped_at
        self.store.update_meeting_status(meeting_id, "stopped")
        return {"meeting_id": meeting_id, "status": "stopped", "stopped_at": stopped_at}

    def stream_push_audio(self, params: dict[str, Any]) -> dict[str, Any]:
        _ = params
        return {"accepted": True}

    def transcript_delta(self, params: dict[str, Any]) -> dict[str, Any]:
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

    def transcript_list(self, params: dict[str, Any]) -> dict[str, Any]:
        meeting_id = params["meeting_id"]
        limit = int(params.get("limit", 1000))
        rows = self.store.list_segments(meeting_id)
        if limit > 0 and len(rows) > limit:
            rows = rows[-limit:]
        return {"meeting_id": meeting_id, "segments": rows}

    def live_session_start(self, params: dict[str, Any]) -> dict[str, Any]:
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

    def live_session_stop(self, params: dict[str, Any]) -> dict[str, Any]:
        stopped = self.session_stop(params)
        return {"meeting_id": stopped["meeting_id"], "state": "stopped", "stopped_at": stopped["stopped_at"]}

    def live_session_status(self, params: dict[str, Any]) -> dict[str, Any]:
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
```

**Step 4: Run test to verify it passes**

Run: `python3 -m pytest tests/test_session_handler.py -v`
Expected: PASS (8 tests)

**Step 5: Commit**

```bash
git add insightkit/ipc/session_handler.py tests/test_session_handler.py
git commit -m "refactor: extract SessionHandler from server.py"
```


---

### Task 2: 提取 InsightCoordinator

**Files:**
- Create: `insightkit/ipc/insight_coord.py`
- Create: `tests/test_insight_coord.py`

**Step 1: Write the failing test**

```python
# tests/test_insight_coord.py
import tempfile
import unittest
from pathlib import Path

from insightkit.data.store import InsightStore
from insightkit.insights.provider import RuleBasedProvider
from insightkit.insights.service import InsightService
from insightkit.ipc.insight_coord import InsightCoordinator


class TestInsightCoordinator(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.store = InsightStore(Path(self.tmp) / "test.db")
        self.service = InsightService(provider=RuleBasedProvider(), strict_mode=False)
        self.coord = InsightCoordinator(store=self.store, insight_service=self.service)

    def test_refresh_live_empty_session(self):
        self.store.upsert_meeting("m-1", "test", "mic", status="recording")
        result = self.coord.insight_refresh_live({"meeting_id": "m-1", "window_sec": 120})
        self.assertEqual(result["meeting_id"], "m-1")
        self.assertEqual(result["mode"], "live")
        self.assertIn("insight_package", result)

    def test_build_final(self):
        self.store.upsert_meeting("m-1", "test", "mic", status="stopped")
        result = self.coord.insight_build_final({"meeting_id": "m-1"})
        self.assertEqual(result["mode"], "final")
        self.assertIn("needs_review_count", result)

    def test_document_export_markdown(self):
        self.store.upsert_meeting("m-1", "test", "mic", status="stopped")
        out_dir = Path(self.tmp) / "export"
        result = self.coord.document_export({
            "meeting_id": "m-1",
            "format": "markdown",
            "output_dir": str(out_dir),
        })
        self.assertIn("path", result)
        self.assertTrue(Path(result["path"]).exists())


if __name__ == "__main__":
    unittest.main()
```

**Step 2: Run test to verify it fails**

Run: `python3 -m pytest tests/test_insight_coord.py -v`
Expected: FAIL with "ModuleNotFoundError"

**Step 3: Write minimal implementation**

```python
# insightkit/ipc/insight_coord.py
"""Insight generation coordinator for InsightKit RPC."""

from __future__ import annotations

import json
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from insightkit.data.store import InsightStore
from insightkit.insights.render import render_insight_markdown
from insightkit.insights.service import InsightService


class InsightCoordinator:
    def __init__(self, store: InsightStore, insight_service: InsightService):
        self.store = store
        self.insight_service = insight_service

    def insight_refresh_live(self, params: dict[str, Any]) -> dict[str, Any]:
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

    def insight_build_final(self, params: dict[str, Any]) -> dict[str, Any]:
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

    def document_export(self, params: dict[str, Any]) -> dict[str, Any]:
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
```

**Step 4: Run test to verify it passes**

Run: `python3 -m pytest tests/test_insight_coord.py -v`
Expected: PASS (3 tests)

**Step 5: Commit**

```bash
git add insightkit/ipc/insight_coord.py tests/test_insight_coord.py
git commit -m "refactor: extract InsightCoordinator from server.py"
```


---

### Task 3: 提取 ASRDispatcher

**Files:**
- Create: `insightkit/ipc/asr_dispatcher.py`
- Create: `tests/test_asr_dispatcher.py`

**Step 1: Write the failing test**

```python
# tests/test_asr_dispatcher.py
import unittest
from unittest import mock

from insightkit.ipc.asr_dispatcher import ASRDispatcher


class TestASRDispatcher(unittest.TestCase):
    @mock.patch("insightkit.ipc.asr_dispatcher.runtime_status", return_value={"ready": True, "engine": "funasr"})
    @mock.patch("insightkit.ipc.asr_dispatcher.runtime_backend_status", return_value={"device": "cpu", "compute_type": "int8", "resolved": True, "supported_compute_types": [], "configured_device": "cpu", "configured_compute_type": "int8"})
    @mock.patch("insightkit.ipc.asr_dispatcher.runtime_warm_status", return_value={"ready": True, "state": "warm", "in_progress": False, "attempt": 1, "last_warm_ms": 100, "last_error": ""})
    def test_runtime_status(self, mock_warm, mock_backend, mock_status):
        dispatcher = ASRDispatcher()
        result = dispatcher.asr_runtime_status({})
        self.assertTrue(result["ready"])
        self.assertIn("backend", result)
        self.assertIn("warm", result)

    @mock.patch("insightkit.ipc.asr_dispatcher.bootstrap_runtime", return_value={"ok": True})
    def test_runtime_bootstrap(self, mock_bootstrap):
        dispatcher = ASRDispatcher()
        result = dispatcher.asr_runtime_bootstrap({"model": "base"})
        self.assertTrue(result["ok"])

    @mock.patch("insightkit.ipc.asr_dispatcher.prewarm_asr", return_value={"ok": True, "backend": {"device": "cpu"}, "warm": {"ready": True}})
    def test_prewarm(self, mock_prewarm):
        dispatcher = ASRDispatcher()
        result = dispatcher.asr_prewarm({"model": "base", "timeout_sec": 10})
        self.assertTrue(result["ok"])

    @mock.patch("insightkit.ipc.asr_dispatcher.transcribe_audio_chunk", return_value=[{"start_ms": 0, "end_ms": 1000, "text": "hello"}])
    def test_transcribe_chunk(self, mock_transcribe):
        dispatcher = ASRDispatcher()
        result = dispatcher.asr_transcribe_chunk({"wav_path": "/tmp/test.wav", "offset_ms": 0, "source": "mic"})
        self.assertEqual(len(result["segments"]), 1)
        self.assertEqual(result["segments"][0]["source"], "mic")

    def test_transcribe_chunk_requires_wav_path(self):
        dispatcher = ASRDispatcher()
        with self.assertRaises(ValueError):
            dispatcher.asr_transcribe_chunk({"wav_path": ""})


if __name__ == "__main__":
    unittest.main()
```

**Step 2: Run test to verify it fails**

Run: `python3 -m pytest tests/test_asr_dispatcher.py -v`
Expected: FAIL with "ModuleNotFoundError"

**Step 3: Write minimal implementation**

```python
# insightkit/ipc/asr_dispatcher.py
"""ASR runtime dispatcher for InsightKit RPC."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from scripts.asr_runtime_bootstrap import bootstrap_runtime, runtime_status
from scripts.transcriber import prewarm_asr, runtime_backend_status, runtime_warm_status, transcribe_audio_chunk


class ASRDispatcher:
    def asr_runtime_status(self, params: dict[str, Any]) -> dict[str, Any]:
        engine = str(params.get("engine", "") or "").strip() or None
        status = runtime_status(engine=engine)
        status["backend"] = runtime_backend_status(engine=engine)
        status["warm"] = runtime_warm_status()
        return status

    def asr_runtime_bootstrap(self, params: dict[str, Any]) -> dict[str, Any]:
        model = str(params.get("model", "") or "").strip() or None
        engine = str(params.get("engine", "") or "").strip() or None
        return bootstrap_runtime(model_name=model, engine=engine)

    def asr_prewarm(self, params: dict[str, Any]) -> dict[str, Any]:
        engine = str(params.get("engine", "") or "").strip() or None
        model = str(params.get("model", "") or "").strip() or None
        try:
            timeout_sec = max(3, min(120, int(params.get("timeout_sec", 20))))
        except Exception:
            timeout_sec = 20
        result = prewarm_asr(engine=engine, model=model, timeout_sec=timeout_sec)
        if "backend" not in result:
            result["backend"] = runtime_backend_status(engine=engine)
        if "warm" not in result:
            result["warm"] = runtime_warm_status()
        return result

    def asr_transcribe_chunk(self, params: dict[str, Any]) -> dict[str, Any]:
        wav_path = str(params.get("wav_path", "") or "").strip()
        if not wav_path:
            raise ValueError("wav_path is required")
        offset_ms = int(params.get("offset_ms", 0))
        source = str(params.get("source", "") or "").strip() or "mixed"
        segments = transcribe_audio_chunk(Path(wav_path).expanduser().resolve(), offset_ms=offset_ms)
        for seg in segments:
            seg["source"] = source
        return {"segments": segments}
```

**Step 4: Run test to verify it passes**

Run: `python3 -m pytest tests/test_asr_dispatcher.py -v`
Expected: PASS (5 tests)

**Step 5: Commit**

```bash
git add insightkit/ipc/asr_dispatcher.py tests/test_asr_dispatcher.py
git commit -m "refactor: extract ASRDispatcher from server.py"
```


---

### Task 4: 提取 ProviderProbe

**Files:**
- Create: `insightkit/ipc/provider_probe.py`
- Create: `tests/test_provider_probe.py`

**Step 1: Write the failing test**

```python
# tests/test_provider_probe.py
import unittest
from unittest import mock

from insightkit.insights.service import InsightService
from insightkit.ipc.provider_probe import ProviderProbe


class TestProviderProbe(unittest.TestCase):
    def setUp(self):
        self.service = mock.MagicMock(spec=InsightService)
        self.probe = ProviderProbe(insight_service=self.service)

    @mock.patch("insightkit.ipc.provider_probe.providers_status", return_value={
        "selected_vendor": "openai",
        "active_ready": True,
        "vendors": {"openai": {"configured": True, "model_id": "gpt-4", "base_url": ""}},
    })
    def test_providers_status_no_probe(self, mock_ps):
        result = self.probe.analysis_providers_status({"probe_active": False})
        self.assertIsNone(result["active_probe_ok"])

    @mock.patch("insightkit.ipc.provider_probe.providers_status", return_value={
        "selected_vendor": "openai",
        "active_ready": True,
        "vendors": {"openai": {"configured": True, "model_id": "gpt-4", "base_url": ""}},
    })
    def test_providers_status_with_probe_ok(self, mock_ps):
        self.service.probe_provider.return_value = {"ok": True, "code": "", "message": ""}
        result = self.probe.analysis_providers_status({"probe_active": True, "probe_timeout_sec": 2})
        self.assertTrue(result["active_probe_ok"])

    def test_provider_probe_calls_service(self):
        self.service.probe_provider.return_value = {"ok": True, "code": "", "message": ""}
        result = self.probe.analysis_provider_probe({
            "provider_vendor": "openai",
            "provider_model": "gpt-4",
            "force_refresh": True,
            "probe_timeout_sec": 2,
        })
        self.assertTrue(result["ok"])

    @mock.patch("insightkit.ipc.provider_probe.providers_status", return_value={
        "selected_vendor": "openai",
        "active_ready": False,
        "vendors": {"openai": {"configured": True, "model_id": "gpt-4", "base_url": ""}},
    })
    @mock.patch("insightkit.ipc.provider_probe.runtime_status", return_value={"ready": True, "engine": "funasr"})
    def test_diagnostics_quick_check_shape(self, mock_rt, mock_ps):
        self.service.probe_provider.return_value = {"ok": True, "code": "", "message": ""}
        result = self.probe.diagnostics_quick_check({"probe_timeout_sec": 2}, sidecar_status_fn=lambda: {"ready": True, "pid": 1})
        self.assertIn("overall", result)
        self.assertIn("checks", result)
        self.assertTrue(len(result["checks"]) >= 3)


if __name__ == "__main__":
    unittest.main()
```

**Step 2: Run test to verify it fails**

Run: `python3 -m pytest tests/test_provider_probe.py -v`
Expected: FAIL with "ModuleNotFoundError"

**Step 3: Write minimal implementation**

```python
# insightkit/ipc/provider_probe.py
"""Provider probe and diagnostics for InsightKit RPC."""

from __future__ import annotations

import os
import threading
import time
from typing import Any, Callable

from insightkit.insights.provider import providers_status
from insightkit.insights.service import InsightService
from scripts.asr_runtime_bootstrap import runtime_status


class ProviderProbe:
    def __init__(self, insight_service: InsightService):
        self.insight_service = insight_service
        self._cache: dict[str, dict[str, Any]] = {}
        self._cache_lock = threading.Lock()
        self._ttl_sec = max(5, int(os.getenv("INSIGHTKIT_PROVIDER_PROBE_TTL_SEC", "30")))

    def analysis_providers_status(self, params: dict[str, Any]) -> dict[str, Any]:
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

        probe, timed_out = self._probe_with_timeout(
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

    def analysis_provider_probe(self, params: dict[str, Any]) -> dict[str, Any]:
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

        probe, _ = self._probe_with_timeout(
            vendor=vendor, model=model, base_url=base_url,
            force_refresh=force_refresh, timeout_sec=probe_timeout_sec,
        )
        return probe

    def diagnostics_quick_check(
        self,
        params: dict[str, Any],
        sidecar_status_fn: Callable[[], dict[str, Any]] | None = None,
    ) -> dict[str, Any]:
        try:
            probe_timeout_sec = max(1, min(30, int(params.get("probe_timeout_sec", 6))))
        except Exception:
            probe_timeout_sec = 6
        checks: list[dict[str, Any]] = []

        if sidecar_status_fn is not None:
            sidecar = sidecar_status_fn()
            checks.append({
                "id": "sidecar", "title": "侧车服务",
                "status": "pass" if sidecar.get("ready") else "fail",
                "action_hint": "重启侧车服务",
                "details": f"pid={sidecar.get('pid')} ready={sidecar.get('ready')}",
                "timed_out": False,
            })

        asr = runtime_status()
        checks.append({
            "id": "asr_runtime", "title": "本地语音识别",
            "status": "pass" if asr.get("ready") else "fail",
            "action_hint": "执行一键修复语音识别",
            "details": f"engine={asr.get('engine')} model={asr.get('model', {}).get('name', '')}",
            "timed_out": False,
        })

        providers = providers_status(probe_active=False)
        active_vendor = providers.get("selected_vendor", "openai")
        checks.append({
            "id": "analysis_provider", "title": "智能分析服务",
            "status": "pass" if providers.get("active_ready") else "fail",
            "action_hint": "检查模型名称和 API Key",
            "details": f"vendor={active_vendor} ready={providers.get('active_ready')}",
            "timed_out": False,
        })

        active_vendor_payload = providers.get("vendors", {}).get(active_vendor, {})
        if bool(active_vendor_payload.get("configured", False)):
            probe, timed_out = self._probe_with_timeout(
                vendor=str(active_vendor),
                model=str(active_vendor_payload.get("model_id", "")),
                base_url=str(active_vendor_payload.get("base_url", "")),
                force_refresh=False, timeout_sec=probe_timeout_sec,
            )
            checks.append({
                "id": "analysis_provider_probe", "title": "智能分析鉴权探测",
                "status": "warn" if timed_out else ("pass" if probe.get("ok") else "fail"),
                "action_hint": "网络较慢，可先开始转写，稍后重试探测。" if timed_out else (str(probe.get("hint", "")) or "检查 API Key 与模型名称"),
                "details": f"vendor={active_vendor} code={probe.get('code', '')} message={probe.get('message', '')}",
                "timed_out": timed_out,
            })
        else:
            checks.append({
                "id": "analysis_provider_probe", "title": "智能分析鉴权探测",
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

    def _probe_cached(self, vendor: str, model: str, base_url: str, force_refresh: bool) -> dict[str, Any]:
        key = f"{vendor}|{model}|{base_url}".lower()
        now = time.time()
        if not force_refresh:
            with self._cache_lock:
                cached = self._cache.get(key)
                if cached is not None and (now - float(cached.get("_ts", 0.0))) <= self._ttl_sec:
                    return {k: v for k, v in cached.items() if k != "_ts"}
        probe = self.insight_service.probe_provider(
            provider_vendor=vendor, provider_model=model, base_url=base_url or None,
        )
        with self._cache_lock:
            self._cache[key] = {**probe, "_ts": now}
        return probe

    def _probe_with_timeout(self, vendor: str, model: str, base_url: str, force_refresh: bool, timeout_sec: int) -> tuple[dict[str, Any], bool]:
        result_holder: dict[str, Any] = {}
        error_holder: dict[str, Exception] = {}

        def worker() -> None:
            try:
                result_holder["probe"] = self._probe_cached(vendor=vendor, model=model, base_url=base_url, force_refresh=force_refresh)
            except Exception as exc:
                error_holder["error"] = exc

        thread = threading.Thread(target=worker, daemon=True)
        thread.start()
        thread.join(timeout=max(1, timeout_sec))
        if thread.is_alive():
            return {"ok": False, "code": "probe_timeout", "message": "智能分析探测超时，请稍后重试。", "hint": "网络较慢时可先开始转写，稍后重试分析服务探测。"}, True
        if "error" in error_holder:
            raise error_holder["error"]
        return result_holder.get("probe", {"ok": False, "code": "unknown", "message": "智能分析探测失败。", "hint": "请检查服务地址与模型名称。"}), False
```

**Step 4: Run test to verify it passes**

Run: `python3 -m pytest tests/test_provider_probe.py -v`
Expected: PASS (4 tests)

**Step 5: Commit**

```bash
git add insightkit/ipc/provider_probe.py tests/test_provider_probe.py
git commit -m "refactor: extract ProviderProbe from server.py"
```


---

### Task 5: 提取 JobQueue

**Files:**
- Create: `insightkit/ipc/job_queue.py`
- Create: `tests/test_job_queue.py`

**Step 1: Write the failing test**

```python
# tests/test_job_queue.py
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from insightkit.data.store import InsightStore
from insightkit.insights.service import InsightService
from insightkit.ipc.job_queue import JobQueue
from insightkit.ipc.watch_bridge import WatchBridge


class TestJobQueue(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.store = InsightStore(Path(self.tmp) / "test.db")
        self.service = mock.MagicMock(spec=InsightService)
        self.watch = WatchBridge()
        self.queue = JobQueue(store=self.store, insight_service=self.service, watch_bridge=self.watch)

    def tearDown(self):
        self.queue.shutdown()

    def test_import_file_creates_job(self):
        media = Path(self.tmp) / "demo.wav"
        media.write_bytes(b"fake")
        result = self.queue.transcription_import_file({"file_path": str(media)})
        self.assertIn("job_id", result)
        self.assertEqual(result["state"], "queued")

    def test_import_file_requires_path(self):
        with self.assertRaises(ValueError):
            self.queue.transcription_import_file({"file_path": ""})

    def test_import_file_requires_existing_file(self):
        with self.assertRaises(FileNotFoundError):
            self.queue.transcription_import_file({"file_path": "/nonexistent/file.wav"})

    def test_status_returns_shape(self):
        result = self.queue.transcription_status({})
        self.assertIn("watcher", result)
        self.assertIn("queue", result)
        self.assertIn("jobs", result)

    def test_cancel_nonexistent_job_raises(self):
        with self.assertRaises(ValueError):
            self.queue.transcription_cancel_job({"job_id": "no-such-id"})

    def test_cancel_queued_job(self):
        media = Path(self.tmp) / "demo.wav"
        media.write_bytes(b"fake")
        with mock.patch("insightkit.ipc.job_queue.run_transcription_job", side_effect=lambda **kw: time.sleep(5)):
            imported = self.queue.transcription_import_file({"file_path": str(media)})
            job_id = imported["job_id"]
            # Give worker a moment to potentially pick it up
            time.sleep(0.1)
            result = self.queue.transcription_cancel_job({"job_id": job_id, "reason": "test"})
            self.assertIn(result["state"], {"cancelled", "running"})


if __name__ == "__main__":
    unittest.main()
```

**Step 2: Run test to verify it fails**

Run: `python3 -m pytest tests/test_job_queue.py -v`
Expected: FAIL with "ModuleNotFoundError"

**Step 3: Write minimal implementation**

```python
# insightkit/ipc/job_queue.py
"""Transcription job queue for InsightKit RPC."""

from __future__ import annotations

import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from insightkit.data.store import InsightStore
from insightkit.insights.service import InsightService
from insightkit.ipc.watch_bridge import WatchBridge
from scripts.transcription_runner import JobCancelled, run_transcription_job


class JobQueue:
    def __init__(
        self,
        store: InsightStore,
        insight_service: InsightService,
        watch_bridge: WatchBridge,
    ):
        self.store = store
        self.insight_service = insight_service
        self._watch_bridge = watch_bridge
        self._lock = threading.RLock()
        self._queue: list[str] = []
        self._jobs: dict[str, dict[str, Any]] = {}
        self._cancel_events: dict[str, threading.Event] = {}
        self._active_job_id: str | None = None
        self._last_completed: dict[str, Any] | None = None
        self._worker: threading.Thread | None = None
        self._worker_stop = threading.Event()

    def shutdown(self) -> None:
        self._worker_stop.set()
        self._watch_bridge.stop()
        if self._worker is not None and self._worker.is_alive():
            self._worker.join(timeout=2.0)

    @property
    def last_completed(self) -> dict[str, Any] | None:
        return self._last_completed

    def transcription_import_file(self, params: dict[str, Any]) -> dict[str, Any]:
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
            "id": job_id, "meeting_id": meeting_id, "source_path": str(resolved),
            "title": title, "state": "queued", "progress": 0, "stage": "queued",
            "error": "", "reason": "", "started_at": now, "ended_at": "",
        }

        with self._lock:
            self._jobs[job_id] = job
            self._cancel_events[job_id] = threading.Event()
            self._queue.append(job_id)
            self.store.upsert_transcription_job(
                job_id=job_id, meeting_id=meeting_id, source_path=str(resolved),
                state="queued", progress=0, stage="queued", started_at=now,
            )
            self._ensure_worker_locked()

        return {"job_id": job_id, "meeting_id": meeting_id, "state": "queued"}

    def transcription_watch_start(self, params: dict[str, Any]) -> dict[str, Any]:
        dirs = params.get("dirs") or []
        if not isinstance(dirs, list):
            raise ValueError("dirs must be array")
        if not dirs:
            dirs = [str(Path.home() / "Desktop"), str(Path.home() / "Downloads")]
        return self._watch_bridge.start(
            [str(Path(d).expanduser()) for d in dirs],
            on_file=self._enqueue_watch_file,
        )

    def transcription_watch_stop(self, params: dict[str, Any]) -> dict[str, Any]:
        _ = params
        return self._watch_bridge.stop()

    def transcription_status(self, params: dict[str, Any]) -> dict[str, Any]:
        raw_limit = params.get("limit", 100)
        try:
            limit = int(raw_limit)
        except (TypeError, ValueError):
            limit = 100
        limit = max(1, min(1000, limit))
        with self._lock:
            jobs = [self._job_view(x) for x in self._jobs.values()]
            jobs.sort(key=lambda x: x.get("started_at", ""), reverse=True)
            queue_views = [self._job_view(self._jobs[x]) for x in self._queue if x in self._jobs]
            active = self._job_view(self._jobs[self._active_job_id]) if self._active_job_id in self._jobs else None
            last_completed = self._last_completed
        return {
            "watcher": self._watch_bridge.status(),
            "queue": queue_views[:limit],
            "active_job": active,
            "last_completed": last_completed,
            "jobs": jobs[:limit],
        }

    def transcription_cancel_job(self, params: dict[str, Any]) -> dict[str, Any]:
        job_id = str(params.get("job_id", "") or "").strip()
        if not job_id:
            raise ValueError("job_id is required")
        reason = str(params.get("reason", "") or "").strip()
        target_state = "paused_by_live" if reason == "preempted_by_live" else "cancelled"

        with self._lock:
            job = self._jobs.get(job_id)
            if job is None:
                raise ValueError(f"job not found: {job_id}")
            if job["state"] in {"completed", "failed", "cancelled", "paused_by_live"}:
                return {"job_id": job_id, "state": job["state"]}
            cancel_event = self._cancel_events.get(job_id)
            if cancel_event is not None:
                cancel_event.set()
            job["reason"] = reason
            job["state"] = target_state
            job["stage"] = "cancelled"
            job["ended_at"] = datetime.now(timezone.utc).isoformat()
            if job_id in self._queue:
                self._queue.remove(job_id)
            self._persist_job_locked(job)
        return {"job_id": job_id, "state": target_state}

    def _enqueue_watch_file(self, file_path: str) -> None:
        import logging
        try:
            self.transcription_import_file({"file_path": file_path, "title": Path(file_path).stem})
        except Exception as exc:
            logging.getLogger(__name__).warning("watch enqueue failed for %s: %s", file_path, exc)

    def _ensure_worker_locked(self) -> None:
        if self._worker is not None and self._worker.is_alive():
            return
        self._worker_stop.clear()
        self._worker = threading.Thread(target=self._worker_loop, name="InsightKitTxWorker", daemon=True)
        self._worker.start()

    def _worker_loop(self) -> None:
        while not self._worker_stop.is_set():
            job: dict[str, Any] | None = None
            cancel_event: threading.Event | None = None
            with self._lock:
                next_id = None
                while self._queue and next_id is None:
                    candidate = self._queue.pop(0)
                    candidate_job = self._jobs.get(candidate)
                    if candidate_job is None or candidate_job.get("state") != "queued":
                        continue
                    next_id = candidate
                if next_id is not None:
                    job = self._jobs[next_id]
                    cancel_event = self._cancel_events.get(next_id)
                    self._active_job_id = next_id
                    job["state"] = "running"
                    job["stage"] = "running"
                    job["progress"] = max(int(job.get("progress", 0)), 5)
                    self._persist_job_locked(job)
            if job is None:
                time.sleep(0.2)
                continue
            try:
                result = run_transcription_job(
                    file_path=job["source_path"], meeting_id=job["meeting_id"],
                    store=self.store, insight_service=self.insight_service,
                    cancel_event=cancel_event,
                    on_progress=lambda p, s, jid=job["id"]: self._update_progress(jid, p, s),
                )
                with self._lock:
                    j = self._jobs.get(job["id"], job)
                    if j.get("state") in {"cancelled", "paused_by_live"}:
                        self._persist_job_locked(j)
                    else:
                        j["state"] = "completed"
                        j["progress"] = 100
                        j["stage"] = "completed"
                        j["error"] = ""
                        j["ended_at"] = datetime.now(timezone.utc).isoformat()
                        self._persist_job_locked(j)
                        self._last_completed = {
                            "job": self._job_view(j),
                            "meeting_id": result.get("meeting_id", j.get("meeting_id", "")),
                            "segments_count": int(result.get("segments_count", 0)),
                            "updated_at": datetime.now(timezone.utc).isoformat(),
                        }
            except JobCancelled:
                with self._lock:
                    j = self._jobs.get(job["id"], job)
                    if j.get("state") not in {"paused_by_live", "cancelled"}:
                        reason = j.get("reason", "")
                        j["state"] = "paused_by_live" if reason == "preempted_by_live" else "cancelled"
                    j["stage"] = "cancelled"
                    j["ended_at"] = datetime.now(timezone.utc).isoformat()
                    self._persist_job_locked(j)
            except Exception as exc:
                with self._lock:
                    j = self._jobs.get(job["id"], job)
                    j["state"] = "failed"
                    j["stage"] = "failed"
                    j["error"] = str(exc)
                    j["ended_at"] = datetime.now(timezone.utc).isoformat()
                    self._persist_job_locked(j)
                    self._last_completed = {
                        "job": self._job_view(j),
                        "meeting_id": j.get("meeting_id", ""),
                        "segments_count": 0,
                        "updated_at": datetime.now(timezone.utc).isoformat(),
                    }
            finally:
                with self._lock:
                    if self._active_job_id == job["id"]:
                        self._active_job_id = None

    def _update_progress(self, job_id: str, progress: int, stage: str) -> None:
        with self._lock:
            job = self._jobs.get(job_id)
            if job is None or job.get("state") not in {"running", "queued"}:
                return
            job["progress"] = int(max(0, min(100, progress)))
            job["stage"] = stage
            self._persist_job_locked(job)

    def _persist_job_locked(self, job: dict[str, Any]) -> None:
        self.store.upsert_transcription_job(
            job_id=job["id"], meeting_id=job["meeting_id"], source_path=job["source_path"],
            state=job["state"], progress=int(job.get("progress", 0)),
            stage=str(job.get("stage", "")), started_at=str(job.get("started_at", "")),
            error=str(job.get("error", "")), reason=str(job.get("reason", "")),
            ended_at=str(job.get("ended_at", "")),
        )

    @staticmethod
    def _job_view(job: dict[str, Any]) -> dict[str, Any]:
        return {
            "id": job.get("id", ""), "meeting_id": job.get("meeting_id", ""),
            "source_path": job.get("source_path", ""), "title": job.get("title", ""),
            "state": job.get("state", "unknown"), "progress": int(job.get("progress", 0)),
            "stage": job.get("stage", ""), "error": job.get("error", ""),
            "reason": job.get("reason", ""), "started_at": job.get("started_at", ""),
            "ended_at": job.get("ended_at", ""),
        }
```

**Step 4: Run test to verify it passes**

Run: `python3 -m pytest tests/test_job_queue.py -v`
Expected: PASS (6 tests)

**Step 5: Commit**

```bash
git add insightkit/ipc/job_queue.py tests/test_job_queue.py
git commit -m "refactor: extract JobQueue from server.py"
```


---

### Task 6: 重写 server.py 为瘦入口 + 委托

**Files:**
- Modify: `insightkit/ipc/server.py`

**Step 1: Run existing tests to confirm baseline**

Run: `python3 -m pytest tests/ -x --tb=short`
Expected: 51 passed

**Step 2: Rewrite server.py to delegate to extracted modules**

server.py 保留：
- `__init__`：创建各模块实例
- `serve_forever` / `shutdown`：socket 生命周期
- `_handle_conn` / `_dispatch`：请求路由
- `_sidecar_*`：sidecar 自身状态方法
- `_module_capabilities` / `_module_run`：模块桥接
- `main`：入口

所有 handler 方法改为委托调用，例如：
```python
# 原来
def _session_start(self, params):
    meeting_id = params.get("meeting_id") or str(uuid.uuid4())
    ...

# 改为
def _session_start(self, params):
    return self._session_handler.session_start(params)
```

关键改动：
- `__init__` 中创建 `SessionHandler`, `InsightCoordinator`, `ASRDispatcher`, `JobQueue`, `ProviderProbe`
- `_live_sessions` 引用改为 `self._session_handler._live_sessions`（用于 sidecar_status 中的 live_sessions 计数）
- `shutdown` 中调用 `self._job_queue.shutdown()`
- `_dispatch` 的 handlers 字典不变（方法名不变，只是内部委托）

**Step 3: Run all tests to verify no regression**

Run: `python3 -m pytest tests/ -x --tb=short`
Expected: 51 passed (所有现有测试不变)

**Step 4: Commit**

```bash
git add insightkit/ipc/server.py
git commit -m "refactor: server.py delegates to extracted handler modules"
```

---

### Task 7: 新增 RPC 冒烟测试脚本

**Files:**
- Create: `scripts/smoke_test_rpc.py`

**Step 1: Write the smoke test script**

```python
#!/usr/bin/env python3
"""Smoke test: call every RPC method via the actual Unix socket."""

import json
import socket
import sys
from pathlib import Path

SOCKET_PATH = Path("/tmp/insightkit.sock")

def rpc_call(method: str, params: dict | None = None) -> dict:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.connect(str(SOCKET_PATH))
        req = json.dumps({"id": 1, "method": method, "params": params or {}})
        s.sendall(req.encode("utf-8"))
        data = s.recv(4 * 1024 * 1024)
        return json.loads(data.decode("utf-8"))

def main() -> int:
    if not SOCKET_PATH.exists():
        print(f"FAIL: socket not found at {SOCKET_PATH}")
        print("Start sidecar first: python3 scripts/insight_sidecar.py")
        return 1

    methods = [
        ("sidecar.status", {}),
        ("sidecar.version", {}),
        ("sidecar.ensure_ready", {"timeout_sec": 3}),
        ("asr.runtime.status", {}),
        ("analysis.providers.status", {"probe_active": False}),
        ("diagnostics.quick_check", {"probe_timeout_sec": 3}),
        ("module.capabilities", {}),
        ("transcription.status", {}),
    ]

    passed = 0
    failed = 0
    for method, params in methods:
        try:
            resp = rpc_call(method, params)
            if "error" in resp and resp["error"]:
                print(f"  FAIL  {method}: {resp['error']}")
                failed += 1
            else:
                print(f"  PASS  {method}")
                passed += 1
        except Exception as exc:
            print(f"  FAIL  {method}: {exc}")
            failed += 1

    print(f"\n{passed} passed, {failed} failed out of {len(methods)} methods")
    return 1 if failed else 0

if __name__ == "__main__":
    raise SystemExit(main())
```

**Step 2: Commit**

```bash
chmod +x scripts/smoke_test_rpc.py
git add scripts/smoke_test_rpc.py
git commit -m "test: add RPC smoke test script"
```

---

### Task 8: 全量回归验证

**Step 1: Run Python tests**

Run: `python3 -m pytest tests/ -x --tb=short -v`
Expected: All 51+ tests pass

**Step 2: Run Swift tests**

Run: `swift test --package-path macos/InsightKitApp`
Expected: All 27 tests pass (Swift 端零改动)

**Step 3: Verify new module tests**

Run: `python3 -m pytest tests/test_session_handler.py tests/test_insight_coord.py tests/test_asr_dispatcher.py tests/test_provider_probe.py tests/test_job_queue.py -v`
Expected: All new tests pass

**Step 4: Final commit**

```bash
git add -A
git commit -m "refactor: Phase 1 complete — sidecar split into 5 modules"
```

