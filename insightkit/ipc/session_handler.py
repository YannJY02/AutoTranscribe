"""Session and transcript handler for InsightKit RPC."""

from __future__ import annotations

import secrets
import uuid
from datetime import datetime, timezone
from typing import Any

from insightkit.data.store import InsightStore


class SessionHandler:
    def __init__(self, store: InsightStore):
        self.store = store
        self._live_sessions: dict[str, dict[str, Any]] = {}
        self._finalizing_sessions: dict[str, str] = {}

    def active_session_count(self) -> int:
        running = sum(session.get("state") == "running" for session in self._live_sessions.values())
        return running + len(self._finalizing_sessions)

    def validate_finalization(self, meeting_id: str, token: str) -> bool:
        expected = self._finalizing_sessions.get(meeting_id)
        if expected is None:
            session = self._live_sessions.get(meeting_id)
            if token and session is not None and session.get("state") == "running":
                raise RuntimeError("finalization_not_stopped")
            return False
        if not token or not secrets.compare_digest(expected, token):
            raise RuntimeError("invalid_finalization_lease")
        return True

    def complete_finalization(self, meeting_id: str, token: str) -> None:
        if self.validate_finalization(meeting_id, token):
            del self._finalizing_sessions[meeting_id]

    def session_start(self, params: dict[str, Any]) -> dict[str, Any]:
        meeting_id = params.get("meeting_id") or str(uuid.uuid4())
        title = params.get("title") or "未命名会话"
        source = params.get("source") or "file"
        if meeting_id in self._finalizing_sessions:
            raise RuntimeError("session_finalizing: meeting_id cannot be reused")
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
        session = self._live_sessions.get(meeting_id)
        was_running = session is not None and session.get("state") == "running"
        await_record_save = bool(params.get("await_record_save"))
        lease = self._finalizing_sessions.get(meeting_id)
        token = str(params.get("finalization_lease_token", "") or "")
        if await_record_save:
            if was_running and not token:
                raise ValueError("finalization_lease_token is required")
            if lease is not None and (not token or not secrets.compare_digest(lease, token)):
                raise RuntimeError("invalid_finalization_lease")
        if was_running:
            self._live_sessions[meeting_id]["state"] = "stopped"
            self._live_sessions[meeting_id]["stopped_at"] = stopped_at
        if was_running and await_record_save:
            self._finalizing_sessions[meeting_id] = token
        self.store.update_meeting_status(meeting_id, "stopped")
        result = {"meeting_id": meeting_id, "status": "stopped", "stopped_at": stopped_at}
        return result

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

    def transcript_replace(self, params: dict[str, Any]) -> dict[str, Any]:
        meeting_id = params["meeting_id"]
        segments = params.get("segments", [])
        replaced = self.store.replace_segments(meeting_id, segments)
        return {"meeting_id": meeting_id, "replaced": replaced}

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
