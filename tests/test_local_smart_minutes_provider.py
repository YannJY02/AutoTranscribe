from __future__ import annotations

import json
import urllib.request

from insightkit.insights.schema_validator import validate_insight_package
from insightkit.insights.service import InsightService


TRANSCRIPT = [
    {
        "start_ms": 0,
        "end_ms": 4_000,
        "speaker": "Speaker 1",
        "text": "Today we need to choose the launch plan and review the privacy checklist.",
    },
    {
        "start_ms": 4_000,
        "end_ms": 8_000,
        "speaker": "Speaker 2",
        "text": "We decided to use the staged launch because it gives us a safe rollback.",
    },
    {
        "start_ms": 8_000,
        "end_ms": 12_000,
        "speaker": "Speaker 1",
        "text": "Speaker 1 owns the privacy review and will finish it by Friday.",
    },
]


class CanonicalCloudProvider:
    def __init__(self) -> None:
        self.calls = 0

    def complete(self, _system_prompt: str, _user_prompt: str, _model: str) -> str:
        self.calls += 1
        local_package = InsightService(default_vendor="local").build_final(TRANSCRIPT)
        return json.dumps(local_package)


def test_explicit_local_provider_builds_canonical_source_linked_minutes_without_network(monkeypatch):
    def fail_network(*_args, **_kwargs):
        raise AssertionError("the explicit local provider must not access the network")

    monkeypatch.setattr(urllib.request, "urlopen", fail_network)
    service = InsightService()

    package = service.build_final(TRANSCRIPT, provider_vendor="local")

    validate_insight_package(package)
    assert service.last_call_meta == {
        "vendor": "local",
        "model": "extractive-v1",
        "strict_mode": False,
    }
    assert package["session_overview"]["overview"]
    assert package["highlight_insights"]
    assert package["speaker_perspectives"]
    assert package["decision_ledger"]
    assert package["action_tracks"]
    assert package["timeline_beats"]
    assert package["provenance_links"] == []
    assert all(item["evidence_span"]["end_ms"] > item["evidence_span"]["start_ms"] for item in package["highlight_insights"])
    assert all(item["evidence_span"]["end_ms"] > item["evidence_span"]["start_ms"] for item in package["decision_ledger"])
    assert all(item["evidence_span"]["end_ms"] > item["evidence_span"]["start_ms"] for item in package["action_tracks"])


def test_explicit_local_provider_supports_live_minutes_without_cloud_key(monkeypatch):
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    monkeypatch.delenv("DEEPSEEK_API_KEY", raising=False)
    service = InsightService()

    package = service.build_live(TRANSCRIPT, provider_vendor="local")

    validate_insight_package(package)
    assert service.last_call_meta["vendor"] == "local"


def test_explicit_cloud_provider_path_remains_available():
    provider = CanonicalCloudProvider()
    service = InsightService(provider=provider, model="cloud-model", default_vendor="deepseek")

    package = service.build_final(TRANSCRIPT, provider_vendor="deepseek")

    validate_insight_package(package)
    assert provider.calls == 1
    assert service.last_call_meta["vendor"] == "deepseek"
    assert service.last_call_meta["model"] == "cloud-model"


def test_local_analysis_mode_rejects_an_explicit_cloud_override(monkeypatch):
    monkeypatch.setenv("INSIGHTKIT_ANALYSIS_MODE", "local")
    provider = CanonicalCloudProvider()
    service = InsightService(provider=provider, model="cloud-model", default_vendor="deepseek")

    package = service.build_final(TRANSCRIPT, provider_vendor="deepseek")

    validate_insight_package(package)
    assert provider.calls == 0
    assert service.last_call_meta["vendor"] == "local"
