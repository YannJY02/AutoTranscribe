from __future__ import annotations

import json
from contextlib import contextmanager
from unittest import mock

from insightkit.insights.provider import ProviderCompletion
from insightkit.insights.service import InsightService


class RecordingObservation:
    def __init__(self, record: dict[str, object]):
        self.record = record

    def update(self, **kwargs: object) -> None:
        self.record.setdefault("updates", []).append(kwargs)


class RecordingLangfuse:
    def __init__(self):
        self.observations: list[dict[str, object]] = []
        self.depth = 0
        self.flushed = False

    @contextmanager
    def start_as_current_observation(self, **kwargs: object):
        record = {**kwargs, "depth": self.depth, "updates": []}
        self.observations.append(record)
        self.depth += 1
        try:
            yield RecordingObservation(record)
        finally:
            self.depth -= 1

    def flush(self) -> None:
        self.flushed = True


class CompletingProvider:
    def complete(self, system_prompt: str, user_prompt: str, model: str) -> ProviderCompletion:
        _ = (system_prompt, user_prompt, model)
        return ProviderCompletion(
            text=json.dumps(InsightService._fallback_payload(live_mode=True)),
            usage_details={"input_tokens": 21, "output_tokens": 34, "total_tokens": 55},
        )


@contextmanager
def _attribute_context():
    yield


def _run_trace(monkeypatch, capture_content: bool) -> tuple[RecordingLangfuse, mock.Mock]:
    monkeypatch.setenv("INSIGHTKIT_LANGFUSE_CAPTURE_CONTENT", "1" if capture_content else "0")
    client = RecordingLangfuse()
    service = InsightService(
        provider=CompletingProvider(), model="test-model", default_vendor="test", strict_mode=True
    )
    service._langfuse = client
    attributes = mock.Mock(return_value=_attribute_context())
    transcript = [{"start_ms": 0, "end_ms": 1000, "speaker": "A", "text": "private transcript"}]

    with mock.patch("langfuse.propagate_attributes", attributes):
        service.build_live(transcript, session_id="meeting-123")

    return client, attributes


def test_langfuse_trace_is_nested_grouped_and_private_by_default(monkeypatch):
    client, attributes = _run_trace(monkeypatch, capture_content=False)

    assert [(item["name"], item["as_type"], item["depth"]) for item in client.observations] == [
        ("generate-smart-minutes-live", "chain", 0),
        ("call-analysis-provider", "generation", 1),
    ]
    attributes.assert_called_once_with(
        session_id="meeting-123",
        tags=["smart-minutes", "live", "test"],
        trace_name="generate-smart-minutes-live",
    )
    generation = client.observations[1]
    assert generation["model"] == "test-model"
    assert "private transcript" not in json.dumps(client.observations)
    assert generation["updates"][-1]["usage_details"] == {
        "input_tokens": 21,
        "output_tokens": 34,
        "total_tokens": 55,
    }

    service = InsightService(
        provider=CompletingProvider(), model="test-model", default_vendor="test", strict_mode=True
    )
    service._langfuse = client
    service.flush_traces()
    assert client.flushed is True


def test_langfuse_content_capture_requires_explicit_opt_in(monkeypatch):
    client, _ = _run_trace(monkeypatch, capture_content=True)

    assert "private transcript" in json.dumps(client.observations)
