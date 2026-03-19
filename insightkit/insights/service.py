"""Insight generation orchestration service."""

from __future__ import annotations

import json
import logging
import os
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


class InsightService:
    def __init__(
        self,
        provider: ProviderAdapter | None = None,
        model: str = "gpt-4.1",
        default_vendor: str | None = None,
        strict_mode: bool | None = None,
    ):
        # provider 参数仅用于测试/兼容场景。生产默认走 resolve_provider。
        self.provider = provider
        self.model = model
        self.default_vendor = (default_vendor or os.getenv("INSIGHTKIT_PROVIDER_VENDOR", "openai")).strip().lower()
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

    def probe_provider(
        self,
        provider_vendor: str | None = None,
        provider_model: str | None = None,
        base_url: str | None = None,
    ) -> dict[str, Any]:
        effective_vendor = (provider_vendor or self.default_vendor).strip().lower()
        effective_model = (provider_model or self.model).strip() or self.model
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
        user_prompt = LIVE_PROMPT.replace(
            "{{TRANSCRIPT_WINDOW_JSON}}", json.dumps(transcript_window, ensure_ascii=False)
        )
        return self._complete(
            user_prompt,
            live_mode=True,
            provider_vendor=provider_vendor,
            provider_model=provider_model,
            strict_mode=strict_mode,
        )

    def build_final(
        self,
        full_transcript: list[dict[str, Any]],
        provider_vendor: str | None = None,
        provider_model: str | None = None,
        strict_mode: bool | None = None,
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
        )

    def _complete(
        self,
        user_prompt: str,
        live_mode: bool,
        provider_vendor: str | None,
        provider_model: str | None,
        strict_mode: bool | None,
    ) -> dict[str, Any]:
        effective_strict = self.strict_mode if strict_mode is None else bool(strict_mode)
        effective_vendor = (provider_vendor or self.default_vendor).strip().lower()
        effective_model = (provider_model or self.model).strip() or self.model

        provider = self.provider
        resolved_model = effective_model
        resolved_vendor = effective_vendor
        if provider is None:
            provider, profile = resolve_provider(vendor=effective_vendor, model_override=effective_model)
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
        payload = postprocess_insight_package(payload)
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
