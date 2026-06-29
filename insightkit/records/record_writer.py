"""Record folder writer for InsightKit — persists transcription results to disk."""

from __future__ import annotations

import json
import os
import re
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
        analysis_meta: dict[str, Any] | None = None,
        notes_md: str = "",
    ) -> Path:
        """Write record folder and return its Path."""
        root = Path(root_dir).expanduser()
        root.mkdir(parents=True, exist_ok=True)

        # ── metadata.json ────────────────────────────────────────────────
        # CRITICAL: use strftime Z suffix — Swift JSONDecoder .iso8601 rejects +00:00
        default_created_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        existing_record_dir = self._existing_record_dir(root, meeting_id)
        if existing_record_dir is None:
            created_at = default_created_at
            record_dir = self._new_record_dir(
                root=root,
                meeting_id=meeting_id,
                title=title,
                record_source=record_source,
                insight_package=insight_package,
                created_at=created_at,
            )
        else:
            record_dir = existing_record_dir
            created_at = self._existing_created_at(record_dir) or default_created_at
        record_dir.mkdir(parents=True, exist_ok=True)

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
        analysis = self._analysis_metadata(analysis_meta)
        if analysis:
            metadata["analysis"] = analysis
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
            timeline = [
                {
                    "timestamp": str(t.get("timestamp", "")),
                    "title": str(t.get("title", "")),
                    "summary": str(t.get("summary", "")),
                }
                for t in (insight_package.get("timeline_beats") or [])
                if t.get("title") or t.get("summary")
            ]
            minutes = {
                "structured_summary": overview,
                "highlights": highlights,
                "key_decisions": decisions,
                "action_items": actions,
                "timeline_beats": timeline,
            }
        self._write_json(record_dir / "minutes.json", minutes)

        if insight_package is not None:
            self._write_json(record_dir / "insight_package.json", insight_package)

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

    @classmethod
    def _existing_record_dir(cls, root: Path, meeting_id: str) -> Path | None:
        direct = root / meeting_id
        if cls._metadata_id(direct / "metadata.json") == meeting_id:
            return direct
        if direct.exists() and direct.is_dir() and not (direct / "metadata.json").exists():
            return direct
        for child in root.iterdir():
            if not child.is_dir() or child == direct:
                continue
            if cls._metadata_id(child / "metadata.json") == meeting_id:
                return child
        return None

    @classmethod
    def _new_record_dir(
        cls,
        *,
        root: Path,
        meeting_id: str,
        title: str,
        record_source: str,
        insight_package: dict[str, Any] | None,
        created_at: str,
    ) -> Path:
        timestamp = cls._folder_timestamp(created_at)
        source = cls._source_slug(record_source)
        topic = cls._topic_slug(title=title, insight_package=insight_package)
        short_id = cls._short_id(meeting_id)
        base = f"{timestamp}-{source}-{topic}-{short_id}"
        candidate = root / base
        suffix = 2
        while candidate.exists():
            candidate = root / f"{base}-{suffix}"
            suffix += 1
        return candidate

    @staticmethod
    def _metadata_id(path: Path) -> str | None:
        data = RecordWriter._metadata(path)
        value = data.get("id") if isinstance(data, dict) else None
        return str(value) if value else None

    @staticmethod
    def _existing_created_at(record_dir: Path) -> str | None:
        data = RecordWriter._metadata(record_dir / "metadata.json")
        value = data.get("createdAt") if isinstance(data, dict) else None
        return str(value) if value else None

    @staticmethod
    def _metadata(path: Path) -> dict[str, Any]:
        if not path.exists() or not path.is_file():
            return {}
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return {}
        return data if isinstance(data, dict) else {}

    @staticmethod
    def _folder_timestamp(created_at: str) -> str:
        try:
            dt = datetime.strptime(created_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).astimezone()
            return dt.strftime("%Y%m%d-%H%M")
        except ValueError:
            return datetime.now().astimezone().strftime("%Y%m%d-%H%M")

    @staticmethod
    def _source_slug(record_source: str) -> str:
        normalized = str(record_source or "").strip().lower()
        if normalized == "imported":
            return "import"
        if normalized == "live":
            return "live"
        return RecordWriter._slugify(normalized, fallback="record", limit=16)

    @classmethod
    def _topic_slug(cls, *, title: str, insight_package: dict[str, Any] | None) -> str:
        candidates = [
            title,
            cls._safe_str(insight_package, ["session_overview", "title"]),
            cls._safe_str(insight_package, ["session_overview", "overview"]),
        ]
        for candidate in candidates:
            if cls._is_generic_title(candidate):
                continue
            slug = cls._slugify(candidate, fallback="", limit=48)
            if slug:
                return slug
        return "record"

    @staticmethod
    def _is_generic_title(value: str) -> bool:
        normalized = str(value or "").strip().lower()
        return not normalized or normalized in {"live", "直播洞察", "直播会话", "未命名会话", "record"}

    @staticmethod
    def _short_id(meeting_id: str) -> str:
        normalized = re.sub(r"^(file|live)-", "", str(meeting_id or "").strip().lower())
        compact = "".join(ch for ch in normalized if ch.isalnum())
        return (compact[-8:] if compact else "record")

    @staticmethod
    def _slugify(value: str, *, fallback: str, limit: int) -> str:
        normalized = str(value or "").strip().lower()
        parts: list[str] = []
        last_was_dash = False
        for ch in normalized:
            if ch.isalnum():
                parts.append(ch)
                last_was_dash = False
            elif not last_was_dash:
                parts.append("-")
                last_was_dash = True
        slug = "".join(parts).strip("-")
        if len(slug) > limit:
            slug = slug[:limit].strip("-")
        return slug or fallback

    @staticmethod
    def _write_json(path: Path, data: Any) -> None:
        path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")

    @staticmethod
    def _copy_or_hardlink(src: Path, dest: Path) -> None:
        """Prefer hard link (instant, no disk copy); fall back to shutil.copy2."""
        if dest.exists() and os.path.samefile(src, dest):
            return
        try:
            os.link(src, dest)
        except OSError:
            if dest.exists() and os.path.samefile(src, dest):
                return
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

    @staticmethod
    def _analysis_metadata(meta: dict[str, Any] | None) -> dict[str, Any]:
        if not isinstance(meta, dict):
            return {}

        def clean(key: str) -> str:
            return str(meta.get(key, "") or "").strip()

        provider = clean("provider") or clean("provider_vendor") or clean("vendor")
        model = clean("model") or clean("provider_model")
        source = clean("source") or clean("mode")
        analysis_state = clean("analysis_state") or clean("analysisState")
        generated_at = clean("generated_at") or clean("updated_at")
        strict_raw = meta.get("strict_mode")
        payload: dict[str, Any] = {}
        if provider:
            payload["provider"] = provider
        if model:
            payload["model"] = model
        if source:
            payload["source"] = source
        if analysis_state:
            payload["analysisState"] = analysis_state
        if isinstance(strict_raw, bool):
            payload["strictMode"] = strict_raw
        if generated_at:
            payload["generatedAt"] = generated_at
        return payload
