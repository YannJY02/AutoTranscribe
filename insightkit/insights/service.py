"""Insight generation orchestration service."""

from __future__ import annotations

import json
import logging
import os
import re
from pathlib import Path
from typing import Any

from insightkit.insights.postprocess import postprocess_insight_package
from insightkit.insights.provider import (
    ProviderAdapter,
    ProviderError,
    describe_provider_error,
    probe_provider as provider_probe,
    resolve_provider,
)
from insightkit.insights.schema_validator import validate_insight_package

PROMPT_DIR = Path(__file__).resolve().parent.parent / "prompts"
SYSTEM_PROMPT = (PROMPT_DIR / "system_instruction.md").read_text(encoding="utf-8")
LIVE_PROMPT = (PROMPT_DIR / "live_insight_prompt.md").read_text(encoding="utf-8")
FINAL_PROMPT = (PROMPT_DIR / "final_insight_prompt.md").read_text(encoding="utf-8")
logger = logging.getLogger(__name__)


def attach_transcript_provenance(package: dict[str, Any], meeting_id: str) -> dict[str, Any]:
    """Attach the canonical meeting-specific transcript source representation."""
    enriched = dict(package)
    existing = []
    seen_urls = set()
    for link in package.get("provenance_links", []):
        if not isinstance(link, dict):
            continue
        url = str(link.get("url", "")).strip()
        if not url or url in seen_urls:
            continue
        existing.append(link)
        seen_urls.add(url)
    transcript_url = f"InsightKit SQLite segments: meeting_id={meeting_id}"
    if transcript_url not in seen_urls:
        existing.append({"label": "Transcript evidence", "url": transcript_url})
    enriched["provenance_links"] = existing
    validate_insight_package(enriched)
    return enriched


class InsightService:
    def __init__(
        self,
        provider: ProviderAdapter | None = None,
        model: str | None = None,
        default_vendor: str | None = None,
        strict_mode: bool | None = None,
    ):
        # provider 参数仅用于测试/兼容场景。生产默认走 resolve_provider。
        self.provider = provider
        self.model = (model or "").strip()
        configured_vendor = default_vendor or os.getenv("INSIGHTKIT_PROVIDER_VENDOR", "deepseek")
        if default_vendor is None and os.getenv("INSIGHTKIT_ANALYSIS_MODE", "cloud").strip().lower() == "local":
            configured_vendor = "local"
        self.default_vendor = configured_vendor.strip().lower()
        if strict_mode is None:
            if provider is not None:
                strict_mode = False
            else:
                strict_mode = os.getenv("INSIGHTKIT_STRICT_MODE", "1").strip() != "0"
        self.strict_mode = bool(strict_mode)
        self.last_call_meta: dict[str, Any] = {
            "vendor": self.default_vendor,
            "model": self.model,
            "strict_mode": self.strict_mode,
        }

    def _effective_vendor(self, provider_vendor: str | None) -> str:
        if os.getenv("INSIGHTKIT_ANALYSIS_MODE", "cloud").strip().lower() == "local":
            return "local"
        return (provider_vendor or self.default_vendor).strip().lower()

    def probe_provider(
        self,
        provider_vendor: str | None = None,
        provider_model: str | None = None,
        base_url: str | None = None,
    ) -> dict[str, Any]:
        effective_vendor = self._effective_vendor(provider_vendor)
        effective_model = (provider_model or self.model).strip() or None
        return provider_probe(
            vendor=effective_vendor,
            model_override=effective_model,
            base_url_override=base_url,
        )

    def build_live(
        self,
        transcript_window: list[dict[str, Any]],
        provider_vendor: str | None = None,
        provider_model: str | None = None,
        strict_mode: bool | None = None,
    ) -> dict[str, Any]:
        if self._effective_vendor(provider_vendor) == "local":
            return self._build_local(transcript_window, vendor="local", model="extractive-v1")
        user_prompt = LIVE_PROMPT.replace(
            "{{TRANSCRIPT_WINDOW_JSON}}", json.dumps(transcript_window, ensure_ascii=False)
        )
        return self._complete(
            user_prompt,
            live_mode=True,
            provider_vendor=provider_vendor,
            provider_model=provider_model,
            strict_mode=strict_mode,
            transcript_context=transcript_window,
        )

    def build_final(
        self,
        full_transcript: list[dict[str, Any]],
        provider_vendor: str | None = None,
        provider_model: str | None = None,
        strict_mode: bool | None = None,
    ) -> dict[str, Any]:
        if self._effective_vendor(provider_vendor) == "local":
            return self._build_local(full_transcript, vendor="local", model="extractive-v1")
        user_prompt = FINAL_PROMPT.replace(
            "{{FULL_TRANSCRIPT_JSON}}", json.dumps(full_transcript, ensure_ascii=False)
        )
        return self._complete(
            user_prompt,
            live_mode=False,
            provider_vendor=provider_vendor,
            provider_model=provider_model,
            strict_mode=strict_mode,
            transcript_context=full_transcript,
        )

    def build_local_extractive(self, full_transcript: list[dict[str, Any]]) -> dict[str, Any]:
        """Build a privacy-preserving local draft when no analysis provider is configured."""
        return self._build_local(full_transcript, vendor="local-extractive", model="heuristic-v1")

    def _build_local(
        self,
        full_transcript: list[dict[str, Any]],
        *,
        vendor: str,
        model: str,
    ) -> dict[str, Any]:
        payload = self._extractive_payload(full_transcript)
        payload = postprocess_insight_package(payload, full_transcript=full_transcript)
        validate_insight_package(payload)
        self.last_call_meta = {
            "vendor": vendor,
            "model": model,
            "strict_mode": False,
        }
        return payload

    def _complete(
        self,
        user_prompt: str,
        live_mode: bool,
        provider_vendor: str | None,
        provider_model: str | None,
        strict_mode: bool | None,
        transcript_context: list[dict[str, Any]] | None = None,
    ) -> dict[str, Any]:
        effective_strict = self.strict_mode if strict_mode is None else bool(strict_mode)
        effective_vendor = self._effective_vendor(provider_vendor)
        effective_model = (provider_model or self.model).strip()

        provider = self.provider
        resolved_model = effective_model
        resolved_vendor = effective_vendor
        if provider is None:
            provider, profile = resolve_provider(vendor=effective_vendor, model_override=effective_model or None)
            resolved_model = profile.model_id
            resolved_vendor = profile.vendor

        self.last_call_meta = {
            "vendor": resolved_vendor,
            "model": resolved_model,
            "strict_mode": effective_strict,
        }

        try:
            raw = provider.complete(SYSTEM_PROMPT, user_prompt, resolved_model)
        except Exception as exc:
            logger.error("provider completion failed: %s", exc)
            mapped = describe_provider_error(str(exc), vendor=resolved_vendor)
            message = mapped["message"]
            if mapped.get("hint"):
                message = f"{message} {mapped['hint']}"
            raise ProviderError(message) from exc

        payload = self._parse_or_fallback(raw, live_mode=live_mode, strict_mode=effective_strict)
        payload = postprocess_insight_package(payload, full_transcript=transcript_context)
        validate_insight_package(payload)
        return payload

    @staticmethod
    def _parse_or_fallback(raw: str, live_mode: bool, strict_mode: bool) -> dict[str, Any]:
        try:
            payload = json.loads(raw)
            if isinstance(payload, dict) and "session_overview" in payload:
                return payload
        except Exception as exc:
            if strict_mode:
                raise ProviderError(f"provider returned non-JSON payload: {exc}") from exc

        if strict_mode:
            raise ProviderError("provider returned payload missing InsightPackageV1 keys")
        return InsightService._fallback_payload(live_mode=live_mode)

    @staticmethod
    def _fallback_payload(live_mode: bool) -> dict[str, Any]:
        status = "draft" if live_mode else "open"
        return {
            "session_overview": {
                "title": "未命名会话",
                "overview": "当前内容为灾备回退结果，需复核后使用。",
                "topics": ["待补充"],
            },
            "highlight_insights": [
                {
                    "quote": "待补充高光内容",
                    "reason": "自动提取失败，已回退模板。",
                    "speaker": "",
                    "evidence_span": {"start_ms": 0, "end_ms": 0},
                }
            ],
            "speaker_perspectives": [],
            "decision_ledger": [
                {
                    "problem": "待补充决策问题",
                    "options": ["待补充"],
                    "decision": "待补充",
                    "rationale": "信息不足",
                    "owner": "",
                    "needs_review": True,
                    "evidence_span": {"start_ms": 0, "end_ms": 0},
                }
            ],
            "action_tracks": [
                {
                    "task": "待补充任务",
                    "owner": "待分配",
                    "due_at": "",
                    "priority": "medium",
                    "status": status,
                    "needs_review": True,
                    "evidence_span": {"start_ms": 0, "end_ms": 0},
                }
            ],
            "timeline_beats": [
                {
                    "timestamp": "00:00",
                    "title": "开始",
                    "summary": "待补充时间脉络",
                }
            ],
            "provenance_links": [],
        }

    @staticmethod
    def _extractive_payload(full_transcript: list[dict[str, Any]]) -> dict[str, Any]:
        rows = [row for row in full_transcript if str(row.get("text", "") or "").strip()]
        if not rows:
            return InsightService._fallback_payload(live_mode=False)

        def text(row: dict[str, Any]) -> str:
            return str(row.get("text", "") or "").strip()

        def speaker(row: dict[str, Any]) -> str:
            value = str(row.get("speaker", "") or "").strip()
            return value or "未知发言人"

        def span(row: dict[str, Any]) -> dict[str, int]:
            start = int(row.get("start_ms", 0) or 0)
            end = int(row.get("end_ms", start) or start)
            return {"start_ms": max(0, start), "end_ms": max(0, max(end, start))}

        def timestamp(row: dict[str, Any]) -> str:
            total = int(row.get("start_ms", 0) or 0) // 1000
            return f"{total // 60:02d}:{total % 60:02d}"

        def short_title(value: str) -> str:
            cleaned = re.sub(r"\s+", " ", value).strip()
            return cleaned[:28] or "片段"

        joined = " ".join(text(row) for row in rows)
        keywords = InsightService._topic_terms(joined)
        highlights = sorted(rows, key=lambda row: len(text(row)), reverse=True)[:3]

        decision_markers = [
            "decision", "decide", "decided", "confirm", "confirmed", "决定", "确认", "敲定", "同意",
        ]
        action_markers = [
            "owner", "owns", "负责", "跟进", "完成", "by ", "due", "deadline", "截止", "周", "today", "tomorrow", "friday",
        ]
        decision_rows = [
            row for row in rows if any(marker in text(row).lower() for marker in decision_markers)
        ][:3]
        action_rows = [
            row for row in rows if any(marker in text(row).lower() for marker in action_markers)
        ][:4]

        speaker_groups: dict[str, list[dict[str, Any]]] = {}
        for row in rows:
            speaker_groups.setdefault(speaker(row), []).append(row)

        first_text = text(rows[0])
        overview = (
            f"本地提取式纪要：共 {len(rows)} 段带时间信息的转写，"
            f"覆盖 {len(speaker_groups)} 位发言人。开场内容：{first_text}"
        )

        return {
            "session_overview": {
                "title": "本地转写会话",
                "overview": overview,
                "topics": keywords or ["本地转写", "会议纪要"],
            },
            "highlight_insights": [
                {
                    "quote": text(row),
                    "reason": "本地提取：该片段信息量较高，适合作为复核入口。",
                    "speaker": speaker(row),
                    "evidence_span": span(row),
                }
                for row in highlights
            ],
            "speaker_perspectives": [
                {
                    "speaker": name,
                    "viewpoints": [text(row) for row in group[:3]],
                    "evidence_spans": [span(row) for row in group[:3]],
                }
                for name, group in list(speaker_groups.items())[:6]
            ],
            "decision_ledger": [
                {
                    "problem": "会议决策复核",
                    "options": [],
                    "decision": text(row),
                    "rationale": "本地规则检测到决策或确认类表达，需人工复核。",
                    "owner": speaker(row),
                    "needs_review": True,
                    "evidence_span": span(row),
                }
                for row in (decision_rows or rows[:1])
            ],
            "action_tracks": [
                {
                    "task": text(row),
                    "owner": speaker(row),
                    "due_at": InsightService._extract_due_hint(text(row)),
                    "priority": "medium",
                    "status": "open",
                    "needs_review": True,
                    "evidence_span": span(row),
                }
                for row in (action_rows or rows[-1:])
            ],
            "timeline_beats": [
                {
                    "timestamp": timestamp(row),
                    "title": short_title(text(row)),
                    "summary": text(row),
                }
                for row in rows[:8]
            ],
            "provenance_links": [],
        }

    @staticmethod
    def _topic_terms(text: str) -> list[str]:
        tokens = re.findall(r"[A-Za-z][A-Za-z0-9_-]{3,}|[\u4e00-\u9fff]{2,}", text.lower())
        stop = {
            "this", "that", "with", "from", "have", "will", "first", "today", "meeting",
            "我们", "这个", "一个", "可以", "需要", "本次", "会议",
        }
        seen: set[str] = set()
        topics: list[str] = []
        for token in tokens:
            if token in stop or token in seen:
                continue
            seen.add(token)
            topics.append(token)
            if len(topics) >= 6:
                break
        return topics

    @staticmethod
    def _extract_due_hint(text: str) -> str:
        lower = text.lower()
        for marker in ["today", "tomorrow", "friday", "monday", "tuesday", "wednesday", "thursday"]:
            if marker in lower:
                return marker
        match = re.search(r"(今天|明天|周[一二三四五六日天]|星期[一二三四五六日天]|本周|下周|截止[^，。,. ]*)", text)
        return match.group(1) if match else ""
