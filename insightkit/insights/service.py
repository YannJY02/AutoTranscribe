"""Insight generation orchestration service."""

from __future__ import annotations

import hashlib
import json
import logging
import os
import re
from contextlib import nullcontext
from pathlib import Path
from typing import Any

from insightkit.insights.postprocess import postprocess_insight_package
from insightkit.insights.provider import (
    ProviderAdapter,
    completion_text_and_usage,
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


def _env_enabled(name: str) -> bool:
    return os.getenv(name, "").strip().lower() in {"1", "true", "yes", "on"}


def _langfuse_client() -> Any | None:
    if not _env_enabled("INSIGHTKIT_LANGFUSE_ENABLED"):
        return None

    required = ["LANGFUSE_PUBLIC_KEY", "LANGFUSE_SECRET_KEY", "LANGFUSE_BASE_URL"]
    missing = [name for name in required if not os.getenv(name, "").strip()]
    if missing:
        raise RuntimeError(f"Langfuse tracing enabled but missing: {', '.join(missing)}")

    from langfuse import Langfuse

    return Langfuse(
        base_url=os.environ["LANGFUSE_BASE_URL"],
        environment=os.getenv("LANGFUSE_TRACING_ENVIRONMENT", "development"),
        release=os.getenv("INSIGHTKIT_BUILD", "0.1.0"),
    )


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
        self.default_vendor = (default_vendor or os.getenv("INSIGHTKIT_PROVIDER_VENDOR", "deepseek")).strip().lower()
        if strict_mode is None:
            if provider is not None:
                strict_mode = False
            else:
                strict_mode = os.getenv("INSIGHTKIT_STRICT_MODE", "1").strip() != "0"
        self.strict_mode = bool(strict_mode)
        self._langfuse = _langfuse_client()
        self.last_call_meta: dict[str, Any] = {
            "vendor": self.default_vendor,
            "model": self.model,
            "strict_mode": self.strict_mode,
        }

    def probe_provider(
        self,
        provider_vendor: str | None = None,
        provider_model: str | None = None,
        base_url: str | None = None,
    ) -> dict[str, Any]:
        effective_vendor = (provider_vendor or self.default_vendor).strip().lower()
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
        session_id: str | None = None,
    ) -> dict[str, Any]:
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
            session_id=session_id,
        )

    def build_final(
        self,
        full_transcript: list[dict[str, Any]],
        provider_vendor: str | None = None,
        provider_model: str | None = None,
        strict_mode: bool | None = None,
        session_id: str | None = None,
    ) -> dict[str, Any]:
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
            session_id=session_id,
        )

    def build_local_extractive(self, full_transcript: list[dict[str, Any]]) -> dict[str, Any]:
        """Build a privacy-preserving local draft when no analysis provider is configured."""
        payload = self._extractive_payload(full_transcript)
        payload = postprocess_insight_package(payload, full_transcript=full_transcript)
        validate_insight_package(payload)
        self.last_call_meta = {
            "vendor": "local-extractive",
            "model": "heuristic-v1",
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
        session_id: str | None = None,
    ) -> dict[str, Any]:
        effective_strict = self.strict_mode if strict_mode is None else bool(strict_mode)
        effective_vendor = (provider_vendor or self.default_vendor).strip().lower()
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

        mode = "live" if live_mode else "final"
        trace_name = f"generate-smart-minutes-{mode}"
        capture_content = _env_enabled("INSIGHTKIT_LANGFUSE_CAPTURE_CONTENT")
        attributes = nullcontext()
        if self._langfuse is not None:
            from langfuse import propagate_attributes

            attributes = propagate_attributes(
                session_id=session_id,
                tags=["smart-minutes", mode, resolved_vendor],
                trace_name=trace_name,
            )

        with attributes:
            with self._observation(
                as_type="chain",
                name=trace_name,
                input=self._trace_input(transcript_context, capture_content),
                metadata={
                    "feature": "smart-minutes",
                    "mode": mode,
                    "vendor": resolved_vendor,
                    "strict_mode": effective_strict,
                    "content_capture": capture_content,
                },
            ) as trace:
                generation_input: Any = {
                    "system_prompt_sha256": hashlib.sha256(SYSTEM_PROMPT.encode()).hexdigest(),
                    "user_prompt_sha256": hashlib.sha256(user_prompt.encode()).hexdigest(),
                    "input_characters": len(user_prompt),
                }
                if capture_content:
                    generation_input = [
                        {"role": "system", "content": SYSTEM_PROMPT},
                        {"role": "user", "content": user_prompt},
                    ]

                with self._observation(
                    as_type="generation",
                    name="call-analysis-provider",
                    model=resolved_model,
                    model_parameters={"temperature": 0.2, "response_format": "json_object"},
                    input=generation_input,
                    metadata={"vendor": resolved_vendor},
                ) as generation:
                    try:
                        completion = provider.complete(SYSTEM_PROMPT, user_prompt, resolved_model)
                        raw, usage_details = completion_text_and_usage(completion)
                    except Exception as exc:
                        logger.error("provider completion failed: %s", exc)
                        mapped = describe_provider_error(str(exc), vendor=resolved_vendor)
                        message = mapped["message"]
                        if mapped.get("hint"):
                            message = f"{message} {mapped['hint']}"
                        raise ProviderError(message) from exc
                    if generation is not None:
                        generation.update(
                            output=raw if capture_content else {"output_characters": len(raw)},
                            usage_details=usage_details or None,
                        )

                payload = self._parse_or_fallback(raw, live_mode=live_mode, strict_mode=effective_strict)
                payload = postprocess_insight_package(payload, full_transcript=transcript_context)
                validate_insight_package(payload)
                if trace is not None:
                    trace.update(output=payload if capture_content else self._trace_output(payload))
                return payload

    def _observation(self, **kwargs: Any) -> Any:
        if self._langfuse is None:
            return nullcontext()
        return self._langfuse.start_as_current_observation(**kwargs)

    def flush_traces(self) -> None:
        if self._langfuse is not None:
            try:
                self._langfuse.flush()
            except Exception as exc:
                logger.warning("Langfuse trace flush failed: %s", exc)

    @staticmethod
    def _trace_input(transcript: list[dict[str, Any]] | None, capture_content: bool) -> Any:
        rows = transcript or []
        if capture_content:
            return rows
        return {
            "segment_count": len(rows),
            "transcript_characters": sum(len(str(row.get("text", "") or "")) for row in rows),
            "content": "omitted",
        }

    @staticmethod
    def _trace_output(payload: dict[str, Any]) -> dict[str, int | str]:
        return {
            "schema": "InsightPackageV1",
            "highlights": len(payload.get("highlight_insights", [])),
            "decisions": len(payload.get("decision_ledger", [])),
            "actions": len(payload.get("action_tracks", [])),
            "timeline_beats": len(payload.get("timeline_beats", [])),
        }

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
