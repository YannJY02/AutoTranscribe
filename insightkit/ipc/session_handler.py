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
