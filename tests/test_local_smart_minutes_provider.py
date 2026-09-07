from __future__ import annotations

import json
from pathlib import Path
import socket
import subprocess
import sys
import urllib.request

import pytest

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


@pytest.mark.parametrize(
    ("text", "expected_due"),
    [
        pytest.param(
            "我负责检查文件哈希，不是周五截止，日期尚未确定。", "",
            id="zh-observed-negated-friday",
        ),
        pytest.param(
            "I own the file-hash check. The deadline is not Friday; no due date has been agreed.", "",
            id="en-observed-negated-friday",
        ),
        pytest.param(
            "我负责检查文件哈希，周五不是截止日期。", "",
            id="zh-date-before-negation",
        ),
        pytest.param(
            "I own the file-hash check. Friday is not the deadline.", "",
            id="en-date-before-negation",
        ),
        pytest.param(
            "我负责检查文件哈希，可能周五完成，截止日期尚未确定。", "",
            id="zh-uncertain-friday",
        ),
        pytest.param(
            "I own the file-hash check. Friday is only tentative; no deadline is agreed.", "",
            id="en-uncertain-friday",
        ),
        pytest.param(
            "我负责检查文件哈希，截止日期待定。", "",
            id="zh-no-concrete-date",
        ),
        pytest.param(
            "I own the file-hash check. The deadline has not been set.", "",
            id="en-no-concrete-date",
        ),
        pytest.param(
            "我负责检查文件哈希，不是周五截止，改为周一前完成。", "周一",
            id="zh-negated-friday-affirmative-monday",
        ),
        pytest.param(
            "I own the file-hash check. The deadline is not Friday; finish by Monday.", "monday",
            id="en-negated-friday-affirmative-monday",
        ),
        pytest.param(
            "我负责检查文件哈希，周五不是截止日期，周一前完成。", "周一",
            id="zh-date-before-negation-then-monday",
        ),
        pytest.param(
            "I own the file-hash check. Friday is not the deadline; complete it by Monday.", "monday",
            id="en-date-before-negation-then-monday",
        ),
        pytest.param(
            "我负责检查文件哈希，周五前完成。", "周五",
            id="zh-affirmative-before-friday",
        ),
        pytest.param(
            "我负责检查文件哈希，不得晚于周五完成。", "周五",
            id="zh-no-later-than-friday",
        ),
        pytest.param(
            "I own the file-hash check and will finish by Friday.", "friday",
            id="en-affirmative-by-friday",
        ),
        pytest.param(
            "I own the file-hash check; complete it no later than Friday.", "friday",
            id="en-no-later-than-friday",
        ),
        pytest.param(
            "我负责检查文件哈希，不要修改固定方案并在周五前提交。", "周五",
            id="zh-unrelated-prohibition-with-friday",
        ),
        pytest.param(
            "I own the file-hash check. Do not change the plan and finish by Friday.", "friday",
            id="en-unrelated-prohibition-with-friday",
        ),
        pytest.param(
            "我负责检查周边地区的文件哈希。", "",
            id="zh-week-character-without-date",
        ),
        pytest.param(
            "I own the file-hash check. The deadline isn't Friday.", "",
            id="en-negated-friday-contraction",
        ),
        pytest.param(
            "我负责检查文件哈希，截止时间。", "",
            id="zh-bare-deadline-label",
        ),
        pytest.param(
            "我负责检查文件哈希，截止2026-09-30。", "截止2026-09-30",
            id="zh-explicit-calendar-deadline",
        ),
        pytest.param(
            "我负责检查文件哈希，不是截止2026-09-30。", "",
            id="zh-negated-calendar-deadline",
        ),
        pytest.param(
            "我负责检查文件哈希，截止日期暂定2026-09-30。", "",
            id="zh-tentative-calendar-deadline",
        ),
        pytest.param(
            "我负责检查文件哈希，截止时间可能为2026-09-30。", "",
            id="zh-possible-calendar-deadline",
        ),
        pytest.param(
            "我负责检查文件哈希，截止日期暂定为周五。", "",
            id="zh-tentative-named-deadline",
        ),
        pytest.param(
            "I own the file-hash check. The deadline must not be after Friday.", "friday",
            id="en-not-after-friday-upper-bound",
        ),
        pytest.param(
            "I own the file-hash check. There is no Friday deadline.", "",
            id="en-no-friday-deadline",
        ),
        pytest.param(
            "我负责检查文件哈希，没有周五截止的约定。", "",
            id="zh-no-friday-deadline",
        ),
        pytest.param(
            "I own the file-hash check. The deadline is tentatively due Friday.", "",
            id="en-tentative-due-friday",
        ),
        pytest.param(
            "I own the file-hash check. Friday isn't confirmed.", "",
            id="en-date-not-confirmed",
        ),
        pytest.param(
            "I own the report. The deadline is not Friday; Monday's meeting will decide the date.", "",
            id="en-replacement-meeting-date-is-not-a-deadline",
        ),
        pytest.param(
            "我负责报告，不是周五截止；周一的会议再决定日期。", "",
            id="zh-replacement-meeting-date-is-not-a-deadline",
        ),
        pytest.param(
            "I own the report. The deadline is not Friday; we will discuss the deadline on Monday.", "",
            id="en-replacement-discussion-date-is-not-a-deadline",
        ),
        pytest.param(
            "我负责报告，周五不是截止日期；周一再讨论截止时间。", "",
            id="zh-replacement-discussion-date-is-not-a-deadline",
        ),
        pytest.param(
            "I own the report. The deadline is not Friday; the report is due Monday.", "monday",
            id="en-explicit-replacement-due-monday",
        ),
        pytest.param(
            "I own the report. The report is not due until Friday.", "friday",
            id="en-not-due-until-friday",
        ),
        pytest.param(
            "I own the report. The report won't be due until Friday.", "friday",
            id="en-wont-be-due-until-friday",
        ),
        pytest.param(
            "I own the report. The report is not due before Friday.", "",
            id="en-not-due-before-is-not-a-fixed-deadline",
        ),
        pytest.param(
            "I own the report. The report is maybe not due until Friday.", "",
            id="en-maybe-not-due-until-remains-uncertain",
        ),
        pytest.param(
            "I own the report. The deadline is not Friday; the deadline must not be after Monday.", "monday",
            id="en-replacement-not-after-upper-bound",
        ),
        pytest.param(
            "I own the report. The deadline is not Friday; deadline: Monday.", "monday",
            id="en-replacement-deadline-colon",
        ),
        pytest.param(
            "I own the report. The deadline is not Friday; finish by next Monday.", "monday",
            id="en-replacement-next-monday",
        ),
        pytest.param(
            "我负责报告，不是周五截止；不得晚于周一。", "周一",
            id="zh-replacement-explicit-upper-bound",
        ),
    ],
)
def test_local_due_hints_require_affirmative_concrete_dates(monkeypatch, text, expected_due):
    def fail_network(*_args, **_kwargs):
        raise AssertionError("local due-date extraction must not access the network")

    monkeypatch.setattr(urllib.request, "urlopen", fail_network)
    monkeypatch.setattr(socket, "create_connection", fail_network)
    row = {
        "start_ms": 11_000,
        "end_ms": 14_500,
        "speaker": "Synthetic owner",
        "text": text,
    }
    service = InsightService()

    package = service.build_final([row], provider_vendor="local")

    assert service.last_call_meta["vendor"] == "local"
    assert len(package["action_tracks"]) == 1
    action = package["action_tracks"][0]
    assert action["task"] == text
    assert action["owner"] == row["speaker"]
    assert action["evidence_span"] == {"start_ms": 11_000, "end_ms": 14_500}
    assert action["needs_review"] is True
    assert action["due_at"] == expected_due


def test_local_minutes_completes_a_long_segment_with_rejected_dates():
    # A generous subprocess deadline catches the former minute-long quadratic
    # stall without turning ordinary CI scheduling noise into a timing budget.
    program = """
import socket
import urllib.request
from insightkit.insights.service import InsightService
def no_network(*args, **kwargs):
    raise AssertionError('local minutes must not access the network')
socket.create_connection = no_network
urllib.request.urlopen = no_network
text = 'I own the report. ' + 'not Friday ' * 10_000
row = {'start_ms': 0, 'end_ms': 8_000, 'speaker': 'Synthetic owner', 'text': text}
service = InsightService(default_vendor='local')
package = service.build_final([row], provider_vendor='local')
action = package['action_tracks'][0]
assert action['due_at'] == ''
assert action['task'] == text.strip()
assert action['owner'] == row['speaker']
assert action['needs_review'] is True
assert service.last_call_meta['vendor'] == 'local'
"""
    subprocess.run(
        [sys.executable, "-c", program],
        cwd=Path(__file__).resolve().parents[1],
        capture_output=True,
        text=True,
        check=True,
        timeout=10,
    )


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
