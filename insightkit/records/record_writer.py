"""Record folder writer for InsightKit — persists transcription results to disk."""

from __future__ import annotations

import json
import os
import shutil
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


VIDEO_EXTENSIONS = {".mp4", ".mov", ".mkv", ".avi", ".webm"}


def detect_media_type(file_path: str) -> str:
    """Return 'video' for known video extensions, 'audio' otherwise."""
    ext = Path(file_path).suffix.lower()
    return "video" if ext in VIDEO_EXTENSIONS else "audio"


def detect_duration(segs: list[dict[str, Any]]) -> float:
    """Derive duration in seconds from segment end_ms values (zero-dependency)."""
    if not segs:
        return 0.0
    return max((int(s.get("end_ms", 0) or 0) for s in segs), default=0) / 1000.0


class RecordWriter:
    """Write a completed transcription job to a self-contained record folder."""

    def write_record(
        self,
        *,
        root_dir: Path | str,
        meeting_id: str,
        title: str,
        source_path: str,
        segments: list[dict[str, Any]],
        insight_package: dict[str, Any] | None,
        media_type: str,
        record_source: str,
        duration_sec: float,
        notes_md: str = "",
    ) -> Path:
        """Write record folder and return its Path."""
        root = Path(root_dir).expanduser()
        record_dir = root / meeting_id
        record_dir.mkdir(parents=True, exist_ok=True)

        # ── metadata.json ────────────────────────────────────────────────
        # CRITICAL: use strftime Z suffix — Swift JSONDecoder .iso8601 rejects +00:00
        created_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        overview = self._safe_str(insight_package, ["session_overview", "overview"])
        topics = self._safe_list(insight_package, ["session_overview", "topics"])
        metadata = {
            "id": meeting_id,
            "createdAt": created_at,
            "duration": duration_sec,
            "mediaType": media_type,
            "source": record_source,
            "userTags": [],
            "autoTags": topics,
            "summaryPreview": overview[:200] if overview else "",
        }
        self._write_json(record_dir / "metadata.json", metadata)

        # ── transcript.json ───────────────────────────────────────────────
        transcript = [
            {
                "start_ms": int(s.get("start_ms", 0)),
                "end_ms": int(s.get("end_ms", 0)),
                "speaker": str(s.get("speaker", "") or ""),
                "text": str(s.get("text", "") or ""),
            }
            for s in segments
        ]
        self._write_json(record_dir / "transcript.json", transcript)

        # ── minutes.json ──────────────────────────────────────────────────
        if insight_package is None:
            minutes: dict[str, Any] = {}
        else:
            highlights = [
                str(h.get("quote", ""))
                for h in (insight_package.get("highlight_insights") or [])
                if h.get("quote")
            ]
            decisions = [
                str(d.get("decision", ""))
                for d in (insight_package.get("decision_ledger") or [])
                if d.get("decision")
            ]
            actions = [
                str(a.get("task", ""))
                for a in (insight_package.get("action_tracks") or [])
                if a.get("task")
            ]
            minutes = {
                "structured_summary": overview,
                "highlights": highlights,
                "key_decisions": decisions,
                "action_items": actions,
            }
        self._write_json(record_dir / "minutes.json", minutes)

        # ── notes.md ──────────────────────────────────────────────────────
        (record_dir / "notes.md").write_text(notes_md, encoding="utf-8")

        # ── recording.{ext} ───────────────────────────────────────────────
        if source_path and source_path.strip():
            src = Path(source_path)
            if src.exists() and src.is_file():
                dest = record_dir / f"recording{src.suffix}"
                self._copy_or_hardlink(src, dest)

        return record_dir

    # ── helpers ───────────────────────────────────────────────────────────

    @staticmethod
    def _write_json(path: Path, data: Any) -> None:
        path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")

    @staticmethod
    def _copy_or_hardlink(src: Path, dest: Path) -> None:
        """Prefer hard link (instant, no disk copy); fall back to shutil.copy2."""
        try:
            os.link(src, dest)
        except OSError:
            shutil.copy2(src, dest)

    @staticmethod
    def _safe_str(pkg: dict[str, Any] | None, keys: list[str]) -> str:
        if pkg is None:
            return ""
        node: Any = pkg
        for k in keys:
            if not isinstance(node, dict):
                return ""
            node = node.get(k)
        return str(node) if node else ""

    @staticmethod
    def _safe_list(pkg: dict[str, Any] | None, keys: list[str]) -> list[str]:
        if pkg is None:
            return []
        node: Any = pkg
        for k in keys:
            if not isinstance(node, dict):
                return []
            node = node.get(k)
        if not isinstance(node, list):
            return []
        return [str(x) for x in node if x]
