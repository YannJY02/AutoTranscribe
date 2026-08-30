"""Provider probe and diagnostics for InsightKit RPC."""

from __future__ import annotations

import os
import threading
import time
from typing import Any, Callable

from insightkit.insights.provider import providers_status
from insightkit.insights.service import InsightService
from scripts.asr_runtime_profile import attach_asr_runtime_profile
from scripts.asr_runtime_bootstrap import runtime_status
from scripts.transcriber import runtime_backend_status, runtime_warm_status


class ProviderProbe:
    def __init__(self, insight_service: InsightService):
        self.insight_service = insight_service
        self._cache: dict[str, dict[str, Any]] = {}
        self._cache_lock = threading.Lock()
        self._ttl_sec = max(5, int(os.getenv("INSIGHTKIT_PROVIDER_PROBE_TTL_SEC", "30")))

    def analysis_providers_status(self, params: dict[str, Any]) -> dict[str, Any]:
        probe_active = bool(params.get("probe_active", False))
        try:
            probe_timeout_sec = max(1, min(30, int(params.get("probe_timeout_sec", 6))))
        except Exception:
            probe_timeout_sec = 6
        status = providers_status(probe_active=False)
        status["active_probe_ok"] = None
        status["active_probe_error_code"] = ""
        status["active_probe_message"] = ""

        if not probe_active:
            return status

        active_vendor = str(status.get("selected_vendor", "openai"))
        vendors = status.get("vendors", {})
        active = vendors.get(active_vendor, {})
        if not bool(active.get("configured", False)):
            status["active_probe_ok"] = False
            status["active_probe_error_code"] = "missing_configuration"
            status["active_probe_message"] = "当前服务缺少 API Key 或模型名称。"
            return status

        probe, timed_out = self._probe_with_timeout(
            vendor=active_vendor,
            model=str(active.get("model_id", "")),
            base_url=str(active.get("base_url", "")),
            force_refresh=False,
            timeout_sec=probe_timeout_sec,
        )
        if timed_out:
            status["active_probe_ok"] = False
            status["active_probe_error_code"] = "probe_timeout"
            status["active_probe_message"] = "智能分析探测超时，请稍后重试。"
            return status

        status["active_probe_ok"] = bool(probe.get("ok", False))
        status["active_probe_error_code"] = str(probe.get("code", ""))
        status["active_probe_message"] = str(probe.get("message", ""))
        return status

    def analysis_provider_probe(self, params: dict[str, Any]) -> dict[str, Any]:
        vendor = str(params.get("provider_vendor", "") or "").strip()
        model = str(params.get("provider_model", "") or "").strip()
        base_url = str(params.get("base_url", "") or "").strip()
        force_refresh = bool(params.get("force_refresh", True))
        try:
            probe_timeout_sec = max(1, min(30, int(params.get("probe_timeout_sec", 12))))
        except Exception:
            probe_timeout_sec = 12

        if not vendor:
            vendor = os.getenv("INSIGHTKIT_PROVIDER_VENDOR", "openai").strip().lower() or "openai"
        if not model:
            model = os.getenv("INSIGHTKIT_PROVIDER_MODEL", "").strip()

        probe, _ = self._probe_with_timeout(
            vendor=vendor, model=model, base_url=base_url,
            force_refresh=force_refresh, timeout_sec=probe_timeout_sec,
        )
        return probe

    def diagnostics_quick_check(
        self,
        params: dict[str, Any],
        sidecar_status_fn: Callable[[], dict[str, Any]] | None = None,
    ) -> dict[str, Any]:
        try:
            probe_timeout_sec = max(1, min(30, int(params.get("probe_timeout_sec", 6))))
        except Exception:
            probe_timeout_sec = 6
        checks: list[dict[str, Any]] = []

        if sidecar_status_fn is not None:
            sidecar = sidecar_status_fn()
            checks.append({
                "id": "sidecar", "title": "侧车服务",
                "status": "pass" if sidecar.get("ready") else "fail",
                "action_hint": "重启侧车服务",
                "details": f"pid={sidecar.get('pid')} ready={sidecar.get('ready')}",
                "timed_out": False,
            })

        asr = attach_asr_runtime_profile(
            runtime_status(),
            backend=runtime_backend_status(),
            warm=runtime_warm_status(),
        )
        asr_profile = asr.get("profile") or {}
        checks.append({
            "id": "asr_runtime", "title": "本地语音识别",
            "status": "pass" if (asr_profile.get("final_media_asr") or {}).get("ready") else "fail",
            "action_hint": str(asr_profile.get("user_recovery_hint") or "执行一键修复语音识别"),
            "details": (
                f"engine={asr_profile.get('active_engine', asr.get('engine'))} "
                f"model={asr.get('model', {}).get('name', '')} "
                f"profile_status={asr_profile.get('technical_status', '')}"
            ),
            "runtime_profile": asr_profile,
            "timed_out": False,
        })

        if os.getenv("INSIGHTKIT_ANALYSIS_MODE", "cloud").strip().lower() == "local":
            checks.append({
                "id": "analysis_provider", "title": "本地智能分析",
                "status": "pass",
                "action_hint": "",
                "details": "mode=local ready=True",
                "timed_out": False,
            })
        else:
            providers = providers_status(probe_active=False)
            active_vendor = providers.get("selected_vendor", "openai")
            checks.append({
                "id": "analysis_provider", "title": "智能分析服务",
                "status": "pass" if providers.get("active_ready") else "fail",
                "action_hint": "检查模型名称和 API Key",
                "details": f"vendor={active_vendor} ready={providers.get('active_ready')}",
                "timed_out": False,
            })

            active_vendor_payload = providers.get("vendors", {}).get(active_vendor, {})
            if bool(active_vendor_payload.get("configured", False)):
                probe, timed_out = self._probe_with_timeout(
                    vendor=str(active_vendor),
                    model=str(active_vendor_payload.get("model_id", "")),
                    base_url=str(active_vendor_payload.get("base_url", "")),
                    force_refresh=False, timeout_sec=probe_timeout_sec,
                )
                checks.append({
                    "id": "analysis_provider_probe", "title": "智能分析鉴权探测",
                    "status": "warn" if timed_out else ("pass" if probe.get("ok") else "fail"),
                    "action_hint": "网络较慢，可先开始转写，稍后重试探测。" if timed_out else (str(probe.get("hint", "")) or "检查 API Key 与模型名称"),
                    "details": f"vendor={active_vendor} code={probe.get('code', '')} message={probe.get('message', '')}",
                    "timed_out": timed_out,
                })
            else:
                checks.append({
                    "id": "analysis_provider_probe", "title": "智能分析鉴权探测",
                    "status": "fail",
                    "action_hint": "请先在设置中填写 API Key 与模型名称",
                    "details": f"vendor={active_vendor} code=missing_configuration",
                    "timed_out": False,
                })

        overall = "pass"
        if any(item["status"] == "fail" for item in checks):
            overall = "fail"
        elif any(item["status"] == "warn" for item in checks):
            overall = "warn"
        return {"overall": overall, "checks": checks}

    def _probe_cached(self, vendor: str, model: str, base_url: str, force_refresh: bool) -> dict[str, Any]:
        key = f"{vendor}|{model}|{base_url}".lower()
        now = time.time()
        if not force_refresh:
            with self._cache_lock:
                cached = self._cache.get(key)
                if cached is not None and (now - float(cached.get("_ts", 0.0))) <= self._ttl_sec:
                    return {k: v for k, v in cached.items() if k != "_ts"}
        probe = self.insight_service.probe_provider(
            provider_vendor=vendor, provider_model=model, base_url=base_url or None,
        )
        with self._cache_lock:
            self._cache[key] = {**probe, "_ts": now}
        return probe

    def _probe_with_timeout(self, vendor: str, model: str, base_url: str, force_refresh: bool, timeout_sec: int) -> tuple[dict[str, Any], bool]:
        result_holder: dict[str, Any] = {}
        error_holder: dict[str, Exception] = {}

        def worker() -> None:
            try:
                result_holder["probe"] = self._probe_cached(vendor=vendor, model=model, base_url=base_url, force_refresh=force_refresh)
            except Exception as exc:
                error_holder["error"] = exc

        thread = threading.Thread(target=worker, daemon=True)
        thread.start()
        thread.join(timeout=max(1, timeout_sec))
        if thread.is_alive():
            return {"ok": False, "code": "probe_timeout", "message": "智能分析探测超时，请稍后重试。", "hint": "网络较慢时可先开始转写，稍后重试分析服务探测。"}, True
        if "error" in error_holder:
            raise error_holder["error"]
        return result_holder.get("probe", {"ok": False, "code": "unknown", "message": "智能分析探测失败。", "hint": "请检查服务地址与模型名称。"}), False
