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
        raw_output_dir = params.get("output_dir", "")
        if raw_output_dir and Path(raw_output_dir).is_absolute():
            output_dir = Path(raw_output_dir)
        else:
            output_dir = Path.home() / "Documents" / "InsightKit" / "exports"
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
