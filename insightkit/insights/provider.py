"""Cloud provider adapter layer for BYOK insight generation."""

from __future__ import annotations

import json
import os
import re
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from typing import Any, Protocol


class ProviderError(RuntimeError):
    """Provider request failed."""


DEFAULT_VENDOR = "deepseek"
DEEPSEEK_DEFAULT_BASE_URL = "https://api.deepseek.com"
DEEPSEEK_DEFAULT_MODEL = "deepseek-v4-flash"


@dataclass(frozen=True)
class ProviderCompletion:
    text: str
    usage_details: dict[str, int] = field(default_factory=dict)


def _redact_secret(value: str) -> str:
    redacted = re.sub(r"(Authorization:\s*Bearer\s+)[^\s,\"]+", r"\1[REDACTED]", value, flags=re.IGNORECASE)
    redacted = re.sub(r"([?&]key=)[^&\s]+", r"\1[REDACTED]", redacted, flags=re.IGNORECASE)
    redacted = re.sub(r"((?:OPENAI|DEEPSEEK|GEMINI|QWEN|DOUBAO|API)_?KEY\s*[=:]\s*)[^\s,\"]+", r"\1[REDACTED]", redacted, flags=re.IGNORECASE)
    redacted = re.sub(r"\bsk-[A-Za-z0-9_-]{8,}\b", "[REDACTED]", redacted)
    redacted = re.sub(r"\bhf_[A-Za-z0-9_-]{8,}\b", "[REDACTED]", redacted)
    redacted = re.sub(
        r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b",
        "[REDACTED]",
        redacted,
    )
    return redacted


class ProviderAdapter(Protocol):
    def complete(self, system_prompt: str, user_prompt: str, model: str) -> str | ProviderCompletion:
        raise NotImplementedError


def describe_provider_error(message: str, vendor: str | None = None) -> dict[str, str]:
    raw = _redact_secret((message or "").strip())
    lower = raw.lower()
    vendor_label = (vendor or "").strip().lower()

    if "missing api key" in lower:
        return {
            "code": "missing_key",
            "message": "智能分析服务未配置 API Key。",
            "hint": "请在设置中为当前服务填写 API Key，然后点击“检查可用性”。",
        }
    if "http 401" in lower or "authentication fails" in lower or "governor" in lower:
        return {
            "code": "auth_failed",
            "message": "智能分析服务鉴权失败（401）。",
            "hint": "请核对 API Key 是否正确、是否已过期，以及该 Key 是否有当前模型访问权限。",
        }
    if "http 404" in lower or "model not exist" in lower or "invalidendpointormodel.notfound" in lower:
        model_hint = "请确认模型名称是否存在，且账号具备该模型权限。"
        if vendor_label == "doubao":
            model_hint = "请确认“模型名称（或接入点 ID）”正确，且该接入点对当前 API Key 可见。"
        return {
            "code": "model_not_found",
            "message": "模型不存在或当前账号无访问权限。",
            "hint": model_hint,
        }
    if "unsupported vendor" in lower:
        return {
            "code": "unsupported_vendor",
            "message": "当前服务类型不受支持。",
            "hint": "请在设置中切换到受支持的智能分析服务。",
        }
    if "http 429" in lower:
        return {
            "code": "rate_limited",
            "message": "智能分析服务请求过于频繁（429）。",
            "hint": "请稍后重试，或切换到配额更高的服务/模型。",
        }
    if "http 5" in lower:
        return {
            "code": "provider_unavailable",
            "message": "智能分析服务暂时不可用。",
            "hint": "请稍后重试；若持续失败，可切换其他服务。",
        }
    return {
        "code": "unknown",
        "message": "智能分析服务调用失败。",
        "hint": raw or "请检查服务地址、模型名称与网络连通性。",
    }


@dataclass
class ProviderProfile:
    vendor: str
    base_url: str
    model_id: str
    api_key_env: str
    extra_headers: dict[str, str] = field(default_factory=dict)


@dataclass
class RuleBasedProvider:
    """
    Legacy deterministic provider retained for workflow tooling compatibility.

    This provider is never selected by default in strict production mode.
    """

    def complete(self, system_prompt: str, user_prompt: str, model: str) -> str:
        _ = (system_prompt, model)
        return user_prompt


@dataclass
class OpenAICompatibleProvider:
    """OpenAI-compatible chat completion provider."""

    base_url: str
    api_key: str
    extra_headers: dict[str, str] = field(default_factory=dict)

    def complete(self, system_prompt: str, user_prompt: str, model: str) -> ProviderCompletion:
        url = self.base_url.rstrip("/") + "/chat/completions"
        body = {
            "model": model,
            "temperature": 0.2,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt},
            ],
            "response_format": {"type": "json_object"},
        }
        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json",
        }
        headers.update(self.extra_headers)

        content = self._request(url=url, body=body, headers=headers)
        try:
            usage = content.get("usage") or {}
            return ProviderCompletion(
                text=content["choices"][0]["message"]["content"],
                usage_details=_usage_details(
                    usage,
                    input_key="prompt_tokens",
                    output_key="completion_tokens",
                    total_key="total_tokens",
                ),
            )
        except Exception as exc:
            raise ProviderError(f"bad provider response: {_redact_secret(repr(content))}") from exc

    def _request(self, url: str, body: dict[str, Any], headers: dict[str, str]) -> dict[str, Any]:
        req = urllib.request.Request(
            url,
            data=json.dumps(body).encode("utf-8"),
            method="POST",
            headers=headers,
        )
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            raw = exc.read().decode("utf-8", errors="ignore")
            # Some OpenAI-compatible providers reject `response_format`.
            if exc.code in {400, 422} and "response_format" in raw and "response_format" in body:
                retry_body = dict(body)
                retry_body.pop("response_format", None)
                retry_req = urllib.request.Request(
                    url,
                    data=json.dumps(retry_body).encode("utf-8"),
                    method="POST",
                    headers=headers,
                )
                try:
                    with urllib.request.urlopen(retry_req, timeout=120) as resp:
                        return json.loads(resp.read().decode("utf-8"))
                except urllib.error.HTTPError as retry_exc:
                    retry_raw = retry_exc.read().decode("utf-8", errors="ignore")
                    raise ProviderError(f"http {retry_exc.code}: {_redact_secret(retry_raw)}") from retry_exc
                except Exception as retry_exc:
                    raise ProviderError(_redact_secret(str(retry_exc))) from retry_exc
            raise ProviderError(f"http {exc.code}: {_redact_secret(raw)}") from exc
        except Exception as exc:
            raise ProviderError(_redact_secret(str(exc))) from exc


@dataclass
class GeminiProvider:
    """Google Gemini REST provider."""

    base_url: str
    api_key: str

    def complete(self, system_prompt: str, user_prompt: str, model: str) -> ProviderCompletion:
        model_name = urllib.parse.quote(model, safe="")
        url = (
            self.base_url.rstrip("/")
            + f"/v1beta/models/{model_name}:generateContent"
        )
        body = {
            "systemInstruction": {"parts": [{"text": system_prompt}]},
            "contents": [{"role": "user", "parts": [{"text": user_prompt}]}],
            "generationConfig": {
                "temperature": 0.2,
                "responseMimeType": "application/json",
            },
        }
        req = urllib.request.Request(
            url,
            data=json.dumps(body).encode("utf-8"),
            method="POST",
            headers={"Content-Type": "application/json", "x-goog-api-key": self.api_key},
        )
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                content = json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            msg = exc.read().decode("utf-8", errors="ignore")
            raise ProviderError(f"http {exc.code}: {_redact_secret(msg)}") from exc
        except Exception as exc:
            raise ProviderError(_redact_secret(str(exc))) from exc

        try:
            usage = content.get("usageMetadata") or {}
            return ProviderCompletion(
                text=content["candidates"][0]["content"]["parts"][0]["text"],
                usage_details=_usage_details(
                    usage,
                    input_key="promptTokenCount",
                    output_key="candidatesTokenCount",
                    total_key="totalTokenCount",
                ),
            )
        except Exception as exc:
            raise ProviderError(f"bad gemini response: {content}") from exc


def _usage_details(
    usage: dict[str, Any],
    *,
    input_key: str,
    output_key: str,
    total_key: str,
) -> dict[str, int]:
    def token_count(key: str) -> int:
        try:
            return max(0, int(usage.get(key, 0) or 0))
        except (TypeError, ValueError):
            return 0

    details = {
        "input_tokens": token_count(input_key),
        "output_tokens": token_count(output_key),
        "total_tokens": token_count(total_key),
    }
    return {key: value for key, value in details.items() if value > 0}


def completion_text_and_usage(completion: str | ProviderCompletion) -> tuple[str, dict[str, int]]:
    if isinstance(completion, ProviderCompletion):
        return completion.text, completion.usage_details
    return str(completion), {}


def _default_profiles() -> dict[str, ProviderProfile]:
    return {
        "openai": ProviderProfile(
            vendor="openai",
            base_url=os.getenv("OPENAI_BASE_URL", "https://api.openai.com/v1").strip(),
            model_id=os.getenv("OPENAI_MODEL", "gpt-4.1").strip() or "gpt-4.1",
            api_key_env="OPENAI_API_KEY",
        ),
        "gemini": ProviderProfile(
            vendor="gemini",
            base_url=os.getenv("GEMINI_BASE_URL", "https://generativelanguage.googleapis.com").strip(),
            model_id=os.getenv("GEMINI_MODEL", "gemini-2.5-flash").strip() or "gemini-2.5-flash",
            api_key_env="GEMINI_API_KEY",
        ),
        "deepseek": ProviderProfile(
            vendor="deepseek",
            base_url=os.getenv("DEEPSEEK_BASE_URL", DEEPSEEK_DEFAULT_BASE_URL).strip(),
            model_id=os.getenv("DEEPSEEK_MODEL", DEEPSEEK_DEFAULT_MODEL).strip() or DEEPSEEK_DEFAULT_MODEL,
            api_key_env="DEEPSEEK_API_KEY",
        ),
        "qwen": ProviderProfile(
            vendor="qwen",
            base_url=os.getenv("QWEN_BASE_URL", "https://dashscope.aliyuncs.com/compatible-mode/v1").strip(),
            model_id=os.getenv("QWEN_MODEL", "qwen-plus-latest").strip() or "qwen-plus-latest",
            api_key_env="QWEN_API_KEY",
        ),
        "doubao": ProviderProfile(
            vendor="doubao",
            base_url=os.getenv("DOUBAO_BASE_URL", "https://ark.cn-beijing.volces.com/api/v3").strip(),
            model_id=os.getenv("DOUBAO_MODEL", "doubao-seed-1-6-250615").strip() or "doubao-seed-1-6-250615",
            api_key_env="DOUBAO_API_KEY",
        ),
    }


def available_vendors() -> list[str]:
    return ["openai", "gemini", "deepseek", "qwen", "doubao"]


def resolve_profile(
    vendor: str | None = None,
    model_override: str | None = None,
    base_url_override: str | None = None,
) -> ProviderProfile:
    vendor_key = (vendor or os.getenv("INSIGHTKIT_PROVIDER_VENDOR", DEFAULT_VENDOR)).strip().lower()
    profiles = _default_profiles()
    if vendor_key not in profiles:
        raise ProviderError(f"unsupported vendor: {vendor_key}")

    profile = profiles[vendor_key]
    if model_override is not None and model_override.strip():
        profile.model_id = model_override.strip()
    if base_url_override is not None and base_url_override.strip():
        profile.base_url = base_url_override.strip()
    return profile


def resolve_provider(
    vendor: str | None = None,
    model_override: str | None = None,
    base_url_override: str | None = None,
) -> tuple[ProviderAdapter, ProviderProfile]:
    profile = resolve_profile(vendor=vendor, model_override=model_override, base_url_override=base_url_override)
    api_key = os.getenv(profile.api_key_env, "").strip()
    if not api_key:
        raise ProviderError(f"missing API key in {profile.api_key_env}")
    if not profile.model_id:
        raise ProviderError(f"missing model id for vendor={profile.vendor}")

    if profile.vendor == "gemini":
        provider: ProviderAdapter = GeminiProvider(base_url=profile.base_url, api_key=api_key)
    else:
        provider = OpenAICompatibleProvider(
            base_url=profile.base_url,
            api_key=api_key,
            extra_headers=profile.extra_headers,
        )
    return provider, profile


def resolve_default_provider() -> ProviderAdapter:
    provider, _ = resolve_provider()
    return provider


def probe_provider(
    vendor: str | None = None,
    model_override: str | None = None,
    base_url_override: str | None = None,
) -> dict[str, Any]:
    profile: ProviderProfile | None = None
    try:
        provider, profile = resolve_provider(
            vendor=vendor,
            model_override=model_override,
            base_url_override=base_url_override,
        )
        probe_completion = provider.complete(
            "你是可用性探测器。仅返回 JSON 对象。",
            "输出 {\"ok\":true}。",
            profile.model_id,
        )
        probe_text, _ = completion_text_and_usage(probe_completion)
        ok = _probe_response_ok(str(probe_text))
        return {
            "ok": ok,
            "vendor": profile.vendor,
            "model": profile.model_id,
            "base_url": profile.base_url,
            "code": "ok" if ok else "unknown",
            "message": "连接成功。" if ok else "服务已响应但探测 JSON 不符合预期。",
            "hint": "" if ok else "请检查模型名称、服务地址与 JSON 输出能力。",
        }
    except Exception as exc:
        fallback_vendor = profile.vendor if profile is not None else (vendor or "")
        fallback_model = profile.model_id if profile is not None else (model_override or "")
        fallback_base_url = profile.base_url if profile is not None else (base_url_override or "")
        mapped = describe_provider_error(str(exc), vendor=fallback_vendor)
        return {
            "ok": False,
            "vendor": fallback_vendor,
            "model": fallback_model,
            "base_url": fallback_base_url,
            "code": mapped["code"],
            "message": mapped["message"],
            "hint": mapped["hint"],
        }


def providers_status(probe_active: bool = False) -> dict[str, Any]:
    selected_vendor = os.getenv("INSIGHTKIT_PROVIDER_VENDOR", DEFAULT_VENDOR).strip().lower() or DEFAULT_VENDOR
    profiles = _default_profiles()

    vendors: dict[str, Any] = {}
    for vendor in available_vendors():
        profile = profiles[vendor]
        key = os.getenv(profile.api_key_env, "").strip()
        model_ready = bool(profile.model_id)
        configured = bool(key) and model_ready
        vendors[vendor] = {
            "vendor": vendor,
            "base_url": profile.base_url,
            "model_id": profile.model_id,
            "api_key_env": profile.api_key_env,
            "configured": configured,
            "has_api_key": bool(key),
            "model_ready": model_ready,
        }

    active = vendors.get(selected_vendor) or vendors["openai"]
    payload: dict[str, Any] = {
        "selected_vendor": selected_vendor,
        "active_ready": bool(active.get("configured", False)),
        "vendors": vendors,
    }
    if probe_active:
        if bool(active.get("configured", False)):
            probe = probe_provider(
                vendor=selected_vendor,
                model_override=str(active.get("model_id", "")),
                base_url_override=str(active.get("base_url", "")),
            )
            payload["active_probe_ok"] = bool(probe.get("ok", False))
            payload["active_probe_error_code"] = str(probe.get("code", ""))
            payload["active_probe_message"] = str(probe.get("message", ""))
        else:
            payload["active_probe_ok"] = False
            payload["active_probe_error_code"] = "missing_configuration"
            payload["active_probe_message"] = "当前服务缺少 API Key 或模型名称。"
    return payload


def _probe_response_ok(text: str) -> bool:
    stripped = text.strip()
    if not stripped:
        return False
    if stripped.startswith("```"):
        lines = stripped.splitlines()
        if len(lines) >= 3 and lines[0].startswith("```") and lines[-1].strip() == "```":
            stripped = "\n".join(lines[1:-1]).strip()
            if stripped.lower().startswith("json\n"):
                stripped = stripped[5:].strip()
    try:
        payload = json.loads(stripped)
    except Exception:
        return False
    return isinstance(payload, dict) and payload.get("ok") is True
