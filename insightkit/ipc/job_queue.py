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
from insightkit.ipc.push_broker import PushBroker
from insightkit.ipc.watch_bridge import WatchBridge
from scripts.transcription_runner import JobCancelled, run_transcription_job


class JobQueue:
    def __init__(
        self,
        store: InsightStore,
        insight_service: InsightService,
        watch_bridge: WatchBridge,
        push_broker: PushBroker | None = None,
    ):
        self.store = store
        self.insight_service = insight_service
        self._watch_bridge = watch_bridge
        self._push_broker = push_broker
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
            "provider_vendor": str(params.get("provider_vendor", "") or "").strip(),
            "provider_model": str(params.get("provider_model", "") or "").strip(),
            "strict_mode": params.get("strict_mode"),
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
                    provider_vendor=job.get("provider_vendor") or None,
                    provider_model=job.get("provider_model") or None,
                    strict_mode=job.get("strict_mode"),
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
                            "record_path": str(result.get("record_path", "")),
                            "updated_at": datetime.now(timezone.utc).isoformat(),
                        }
                    if self._push_broker is not None and j.get("state") == "completed":
                        self._push_broker.emit("transcription.completed", {
                            "job_id": j["id"], "meeting_id": j.get("meeting_id", ""), "state": j["state"],
                        })
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
        if self._push_broker is not None:
            self._push_broker.emit("transcription.progress", {
                "job_id": job_id, "progress": job["progress"], "stage": stage,
            })

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
