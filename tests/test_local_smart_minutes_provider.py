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
        pytest.param(
            "I own the report. The report might not be due until Friday.", "",
            id="en-might-not-be-due-until-remains-uncertain",
        ),
        pytest.param(
            "I own the report. The report may not be due until Friday.", "",
            id="en-may-not-be-due-until-remains-uncertain",
        ),
        pytest.param(
            "I own the report. The report could be due Friday.", "",
            id="en-could-be-due-remains-uncertain",
        ),
        pytest.param(
            "我负责报告，不是周五截止；截止日期改为周一。", "周一",
            id="zh-replacement-deadline-changed-to-monday",
        ),
        pytest.param(
            "我负责报告，不是周五截止；截止日期改到周一。", "周一",
            id="zh-replacement-deadline-moved-to-monday",
        ),
        pytest.param(
            "我负责报告，不是周五截止；截止日期可能改为周一。", "",
            id="zh-possible-replacement-deadline-remains-uncertain",
        ),
        pytest.param(
            "I own the report. The deadline is Friday, tentatively.", "",
            id="en-tentative-qualifier-immediately-after-comma",
        ),
        pytest.param(
            "我负责报告，截止日期是周五，暂定。", "",
            id="zh-tentative-qualifier-immediately-after-comma",
        ),
        pytest.param(
            "我负责报告，截止2026-09-30，暂定。", "",
            id="zh-tentative-calendar-deadline-after-comma",
        ),
        pytest.param(
            "I own the report. The deadline is Friday, submit the final report.", "friday",
            id="en-independent-action-after-comma-keeps-deadline",
        ),
        pytest.param(
            "我负责报告，截止日期是周五，提交最终报告。", "周五",
            id="zh-independent-action-after-comma-keeps-deadline",
        ),
        pytest.param(
            "I own the report. The deadline is not Friday; Monday is the deadline-setting meeting.", "",
            id="en-deadline-setting-meeting-is-not-a-replacement-deadline",
        ),
        pytest.param(
            "I own the report. The deadline is not Friday; Monday is the deadline planning meeting.", "",
            id="en-deadline-planning-meeting-is-not-a-replacement-deadline",
        ),
        pytest.param(
            "I own the report. The deadline is not Friday; Monday is the deadline.", "monday",
            id="en-explicit-date-first-replacement-deadline",
        ),
        pytest.param(
            "I own the report. The deadline is not Friday; Monday is the deadline for the report.", "monday",
            id="en-date-first-replacement-deadline-with-for-complement",
        ),
        pytest.param(
            "I own the report. The deadline is neither Friday nor Monday.", "",
            id="en-neither-nor-rejects-both-dates",
        ),
        pytest.param(
            "I own the report. The deadline is neither Friday nor Monday; finish by Tuesday.", "tuesday",
            id="en-neither-nor-preserves-later-affirmative-tuesday",
        ),
        pytest.param(
            "I own the report. We will discuss the report on Monday, then submit it by Friday.", "friday",
            id="en-first-discussion-date-does-not-hide-deadline",
        ),
        pytest.param(
            "我负责报告，周一开会讨论，周五前提交。", "周五",
            id="zh-first-meeting-date-does-not-hide-deadline",
        ),
        pytest.param(
            "I own the report. We will discuss the deadline on Monday.", "",
            id="en-only-discussion-date-is-not-a-deadline",
        ),
        pytest.param(
            "我负责报告，周一开会再决定日期。", "",
            id="zh-only-meeting-date-is-not-a-deadline",
        ),
        pytest.param(
            "I own the report. Friday will not be the deadline.", "",
            id="en-date-first-future-negation",
        ),
        pytest.param(
            "I own the report. Friday won't be the deadline.", "",
            id="en-date-first-future-contracted-negation",
        ),
        pytest.param(
            "I own the report. Friday will never be the deadline; submit it by Monday.", "monday",
            id="en-date-first-future-negation-retains-replacement",
        ),
        pytest.param(
            "I own the report. Friday will be the deadline.", "friday",
            id="en-date-first-future-affirmed-deadline",
        ),
        pytest.param(
            "I own the status reports. Status reports are due Fridays.", "friday",
            id="en-plural-weekday-deadline-normalized",
        ),
        pytest.param(
            "I own the status reports. Status reports are not due Fridays.", "",
            id="en-plural-weekday-negation-retained",
        ),
        pytest.param(
            "I own the status reports. Status reports are due Mondays, tentatively.", "",
            id="en-plural-weekday-uncertainty-retained",
        ),
        pytest.param(
            "I own the report. The deadline is Fridayish.", "",
            id="en-weekday-substring-is-not-a-date",
        ),
        pytest.param(
            "I own the report and will finish Friday.", "friday",
            id="en-completion-without-date-preposition",
        ),
        pytest.param(
            "I own the report and will submit it on Friday.", "friday",
            id="en-completion-on-weekday",
        ),
        pytest.param(
            "I own the report and will deliver tomorrow.", "tomorrow",
            id="en-completion-tomorrow",
        ),
        pytest.param(
            "I own the report; no later than Friday.", "friday",
            id="en-standalone-upper-bound",
        ),
        pytest.param(
            "I own the report. The deadline will be Friday.", "friday",
            id="en-future-affirmed-deadline-before-date",
        ),
        pytest.param(
            "我负责报告，周五前把报告提交。", "周五",
            id="zh-completion-object-after-date",
        ),
        pytest.param(
            "我负责报告，最迟周五。", "周五",
            id="zh-standalone-upper-bound",
        ),
        pytest.param(
            "I own the report. The deadline is not Monday; submit it after Friday.", "",
            id="en-completion-lower-bound-is-not-a-deadline",
        ),
        pytest.param(
            "I own the report. Do not submit it after Friday.", "friday",
            id="en-negated-completion-upper-bound",
        ),
        pytest.param(
            "I own the report. We must submit it not after Friday.", "friday",
            id="en-completion-not-after-upper-bound",
        ),
        pytest.param(
            "I own the report. We might not submit it after Friday.", "",
            id="en-uncertain-negated-completion-upper-bound",
        ),
        pytest.param(
            "I own the report. Maybe do not submit it after Friday.", "",
            id="en-uncertain-imperative-completion-upper-bound",
        ),
        pytest.param(
            "I own the report. Do not submit it before Friday.", "",
            id="en-negated-completion-lower-bound-is-not-a-deadline",
        ),
        pytest.param("I will send the report by Friday.", "friday", id="en-send-by-deadline"),
        pytest.param("I will email the report by Friday.", "friday", id="en-email-by-deadline"),
        pytest.param("I will hand over the report by Monday.", "monday", id="en-hand-over-by-deadline"),
        pytest.param("Do not email the report by Friday.", "", id="en-negated-email-by-deadline"),
        pytest.param("Status reports are due every Friday.", "friday", id="en-recurring-every-deadline"),
        pytest.param("Status reports are due each Friday.", "friday", id="en-recurring-each-deadline"),
        pytest.param("Status reports are not due every Friday.", "", id="en-negated-recurring-deadline"),
        pytest.param("Status reports might be due each Friday.", "", id="en-uncertain-recurring-deadline"),
        pytest.param("Don't submit the report after Friday.", "friday", id="en-contracted-completion-upper-bound"),
        pytest.param("Don’t submit the report after Friday.", "friday", id="en-curly-contracted-completion-upper-bound"),
        pytest.param("Maybe don't submit the report after Friday.", "", id="en-uncertain-contracted-upper-bound"),
        pytest.param("Don't submit the report before Friday.", "", id="en-contracted-completion-lower-bound"),
        pytest.param("Due: Friday.", "friday", id="en-due-colon-label"),
        pytest.param("Maybe due: Friday.", "", id="en-uncertain-due-colon-label"),
        pytest.param("Friday is still the deadline.", "friday", id="en-reaffirmed-date-first-deadline"),
        pytest.param("Friday remains the deadline.", "friday", id="en-date-first-deadline-remains"),
        pytest.param("Friday is still the deadline-setting meeting.", "", id="en-reaffirmed-deadline-meeting-is-not-deadline"),
        pytest.param("Friday is still not the deadline.", "", id="en-reaffirmed-date-first-negation"),
        pytest.param("The deadline for the report is Friday.", "friday", id="en-deadline-for-complement"),
        pytest.param("The deadline for the report will be Friday.", "friday", id="en-future-deadline-for-complement"),
        pytest.param("The deadline for the report is not Friday.", "", id="en-negated-deadline-for-complement"),
        pytest.param("We will discuss the deadline for the report on Monday.", "", id="en-discussion-with-deadline-for-complement"),
        pytest.param("I will not send the report by Friday.", "", id="en-negated-send-by-deadline"),
        pytest.param("Do not change the plan and send the report by Friday.", "friday", id="en-unrelated-negation-with-send-deadline"),
        pytest.param("Due: maybe Friday.", "", id="en-uncertainty-after-due-colon"),
        pytest.param("Due: TBD; meeting on Friday.", "", id="en-tbd-label-with-meeting-date"),
        pytest.param("The deadline for the report is tentatively Friday.", "", id="en-uncertain-deadline-for-complement"),
        pytest.param("The report must be completed by Friday.", "friday", id="en-passive-completed-deadline"),
        pytest.param("The report should be submitted by Friday.", "friday", id="en-passive-submitted-deadline"),
        pytest.param("The report will be delivered by Friday.", "friday", id="en-passive-delivered-deadline"),
        pytest.param("The report has been sent by Monday.", "monday", id="en-perfect-sent-deadline"),
        pytest.param("The report must not be completed by Friday.", "", id="en-negated-passive-completion"),
        pytest.param("The report might be submitted by Friday.", "", id="en-uncertain-passive-completion"),
        pytest.param("The report might have been delivered by Friday.", "", id="en-uncertain-perfect-passive-completion"),
        pytest.param(
            "Submit the report by Monday and hold a rehearsal on Wednesday, tentatively.", "monday",
            id="en-trailing-qualifier-belongs-to-separate-rehearsal",
        ),
        pytest.param(
            "Submit the report by Monday and hold a rehearsal Wednesday or Friday, tentatively.", "monday",
            id="en-trailing-rehearsal-alternatives-do-not-qualify-submission",
        ),
        pytest.param("The deadline is Monday or Wednesday, tentatively.", "", id="en-qualified-deadline-alternatives"),
        pytest.param("Submit by Monday or by Wednesday, tentatively.", "", id="en-qualified-completion-alternatives"),
        pytest.param("Submit by Monday and Wednesday, tentatively.", "", id="en-qualified-shared-completion-dates"),
        pytest.param("Please submit the report by 5 PM Friday.", "friday", id="en-clock-before-weekday-deadline"),
        pytest.param("Please submit the report by 5PM Friday.", "friday", id="en-compact-clock-before-weekday-deadline"),
        pytest.param("Please submit the report by EOD Friday.", "friday", id="en-eod-before-weekday-deadline"),
        pytest.param("The report is not due until 5 PM Friday.", "friday", id="en-clock-preserves-not-due-until"),
        pytest.param("Don't submit the report after EOD Friday.", "friday", id="en-clock-preserves-negated-upper-bound"),
        pytest.param("The report might be submitted by 5 PM Friday.", "", id="en-clock-does-not-hide-uncertainty"),
        pytest.param("Do not submit the report before 5 PM Friday.", "", id="en-clock-preserves-negated-lower-bound"),
        pytest.param("Submit the report after EOD Friday.", "", id="en-clock-preserves-lower-bound"),
        pytest.param("Friday is our submission deadline.", "friday", id="en-date-first-submission-deadline"),
        pytest.param("Friday is our delivery deadline.", "friday", id="en-date-first-delivery-deadline"),
        pytest.param("Friday is not our submission deadline.", "", id="en-negated-date-first-submission-deadline"),
        pytest.param("Friday is our submission deadline-setting meeting.", "", id="en-submission-deadline-meeting-is-not-deadline"),
        pytest.param("By Friday, submit the report.", "friday", id="en-leading-deadline-before-completion"),
        pytest.param("By next Monday, we will email the report.", "monday", id="en-leading-deadline-before-affirmed-action"),
        pytest.param("By 5 PM Friday, submit the report.", "friday", id="en-leading-clock-deadline-before-completion"),
        pytest.param("By Friday, don't submit the report.", "", id="en-leading-date-with-negated-action"),
        pytest.param("By Friday, maybe submit the report.", "", id="en-leading-date-with-uncertain-action"),
        pytest.param("By Friday, we will not submit the report.", "", id="en-leading-date-with-negated-future-action"),
        pytest.param("By Friday, hold a meeting about the report.", "", id="en-leading-date-with-meeting-only"),
        pytest.param("The deadline has been set for Friday.", "friday", id="en-confirmed-deadline-has-been-set"),
        pytest.param("The deadline is set for Monday.", "monday", id="en-confirmed-deadline-is-set"),
        pytest.param("The deadline for the report will be set for Friday.", "friday", id="en-future-set-deadline-for-complement"),
        pytest.param("The deadline has not been set for Friday.", "", id="en-negated-set-deadline"),
        pytest.param("The deadline is maybe set for Friday.", "", id="en-uncertain-set-deadline"),
        pytest.param("The deadline might have been set for Friday.", "", id="en-uncertain-perfect-set-deadline"),
        pytest.param("The deadline is on Friday.", "friday", id="en-deadline-is-on-weekday"),
        pytest.param("The report is due before Friday.", "friday", id="en-due-before-weekday"),
        pytest.param("The deadline is not on Friday.", "", id="en-negated-deadline-is-on-weekday"),
        pytest.param("The report might be due before Friday.", "", id="en-uncertain-due-before-weekday"),
        pytest.param("I need the report by Friday.", "friday", id="en-report-required-by-weekday"),
        pytest.param("The report must be ready by Friday.", "friday", id="en-readiness-required-by-weekday"),
        pytest.param("I don't need the report by Friday.", "", id="en-negated-report-required-by-weekday"),
        pytest.param("I didn't need the report by Friday.", "", id="en-negated-past-report-requirement"),
        pytest.param("The report doesn't need to be ready by Friday.", "", id="en-negated-present-readiness-requirement"),
        pytest.param("The report wasn't being submitted by Friday.", "", id="en-negated-progressive-submission"),
        pytest.param("The report might be being submitted by Friday.", "", id="en-uncertain-progressive-submission"),
        pytest.param("The report hasn't been delivered by Friday.", "", id="en-negated-perfect-delivery"),
        pytest.param("The report shouldn't be completed by Friday.", "", id="en-negated-modal-completion"),
        pytest.param("We will not be able to submit the report by Friday.", "", id="en-unable-negated-completion-auxiliary"),
        pytest.param("We won't be able to submit the report by Friday.", "", id="en-unable-contracted-completion-auxiliary"),
        pytest.param("We are unable to submit the report by Friday.", "", id="en-unable-completion-complement"),
        pytest.param("We might be able to submit the report by Friday.", "", id="en-uncertain-completion-ability"),
        pytest.param("We will be able to submit the report by Friday.", "friday", id="en-affirmed-completion-ability"),
        pytest.param("I will submit feedback on the report by Friday.", "friday", id="en-completion-object-on-complement"),
        pytest.param("I will not submit feedback on the report by Friday.", "", id="en-negated-completion-object-on-complement"),
        pytest.param("I might submit feedback on the report by Friday.", "", id="en-uncertain-completion-object-on-complement"),
        pytest.param("I will submit feedback on the report after Friday.", "", id="en-completion-object-on-lower-bound"),
        pytest.param("Don't submit feedback on the report after Friday.", "friday", id="en-completion-object-on-upper-bound"),
        pytest.param("I will submit feedback on Monday's report by Friday.", "friday", id="en-possessive-weekday-object-before-deadline"),
        pytest.param("I will submit feedback on Monday’s report by Friday.", "friday", id="en-curly-possessive-weekday-object-before-deadline"),
        pytest.param("I will not submit feedback on Monday's report by Friday.", "", id="en-negated-possessive-weekday-object"),
        pytest.param("I will submit version 2.0 by Friday.", "friday", id="en-version-number-before-deadline"),
        pytest.param("I will submit report.final.pdf by Friday.", "friday", id="en-dotted-filename-before-deadline"),
        pytest.param("I will not submit version 2.0 by Friday.", "", id="en-negated-version-number-before-deadline"),
        pytest.param("Do not submit the draft. I will email v2.0 by Friday.", "friday", id="en-sentence-boundary-before-version-deadline"),
        pytest.param("The deadline has been confirmed for Friday.", "friday", id="en-confirmed-for-deadline"),
        pytest.param("The deadline was confirmed as Monday.", "monday", id="en-confirmed-as-deadline"),
        pytest.param("The deadline hasn't been confirmed for Friday.", "", id="en-negated-confirmed-for-deadline"),
        pytest.param("The deadline might be confirmed for Friday.", "", id="en-uncertain-confirmed-for-deadline"),
        pytest.param("The deadline has been confirmed for Friday, tentatively.", "", id="en-tentative-confirmed-for-deadline"),
        pytest.param("Submit the report by Friday's deadline.", "friday", id="en-possessive-date-with-explicit-deadline-bound"),
        pytest.param("Do not submit the report by Friday's deadline.", "", id="en-negated-possessive-deadline-bound"),
        pytest.param("Don't submit the report after Friday's deadline.", "friday", id="en-possessive-date-with-upper-bound"),
        pytest.param("'Do not submit the draft.' I will email it by Friday.", "friday", id="en-quoted-sentence-before-affirmed-deadline"),
        pytest.param('"Do not submit the draft." I will email it by Friday.', "friday", id="en-double-quoted-sentence-before-affirmed-deadline"),
        pytest.param('I will submit "report.final.pdf" by Friday.', "friday", id="en-quoted-dotted-filename-before-deadline"),
        pytest.param("The report might be ready by Friday.", "", id="en-uncertain-readiness-by-weekday"),
        pytest.param("I need to discuss the report on Friday.", "", id="en-need-without-deadline-bound"),
        pytest.param("我负责报告，周五前必须提交。", "周五", id="zh-required-submission-before-weekday"),
        pytest.param("我负责报告，周五前需要完成。", "周五", id="zh-required-completion-before-weekday"),
        pytest.param("我负责报告，周五前不必提交。", "", id="zh-negated-submission-before-weekday"),
        pytest.param("我负责报告，周五前可能提交。", "", id="zh-uncertain-submission-before-weekday"),
        pytest.param("周五前，提交报告。", "周五", id="zh-leading-deadline-before-comma-action"),
        pytest.param("周五之前, 提交报告。", "周五", id="zh-leading-deadline-before-ascii-comma-action"),
        pytest.param("周五前，不要提交报告。", "", id="zh-leading-deadline-with-negated-action"),
        pytest.param("周五前，可能提交报告。", "", id="zh-leading-deadline-with-uncertain-action"),
        pytest.param("周五前，提交报告，暂定。", "", id="zh-leading-deadline-with-tentative-action"),
        pytest.param("周五前。提交报告。", "", id="zh-leading-date-does-not-cross-sentence"),
        pytest.param("We will submit the U.S. report by Friday.", "friday", id="en-initialism-before-deadline"),
        pytest.param("We will not submit the U.S. report by Friday.", "", id="en-negated-initialism-before-deadline"),
        pytest.param("We might submit the U.S. report by Friday.", "", id="en-uncertain-initialism-before-deadline"),
        pytest.param("We will submit the U.S. report by Friday, tentatively.", "", id="en-tentative-initialism-before-deadline"),
        pytest.param("We will submit the U.S. We will meet on Friday.", "", id="en-initialism-at-real-sentence-boundary"),
        pytest.param("Do not submit the U.S. We will submit the report by Friday.", "friday", id="en-negated-initialism-sentence-before-deadline"),
        pytest.param("Submit feedback on the Monday meeting by Friday.", "friday", id="en-weekday-modifies-object-before-deadline"),
        pytest.param("Do not submit feedback on the Monday meeting by Friday.", "", id="en-negated-weekday-object-before-deadline"),
        pytest.param("Maybe submit feedback on the Monday meeting by Friday.", "", id="en-uncertain-weekday-object-before-deadline"),
        pytest.param("Submit feedback on the Monday meeting after Friday.", "", id="en-weekday-object-before-lower-bound"),
        pytest.param("Submit feedback on Monday.", "monday", id="en-on-weekday-still-affirms-completion"),
        pytest.param("Please submit the final copy of the client report by Friday.", "friday", id="en-long-completion-object-before-deadline"),
        pytest.param("Do not submit the final copy of the client report by Friday.", "", id="en-negated-long-completion-object"),
        pytest.param("Maybe submit the final copy of the client report by Friday.", "", id="en-uncertain-long-completion-object"),
        pytest.param("Submit the final copy of the client report after Friday.", "", id="en-long-completion-object-lower-bound"),
        pytest.param("我会在周五前发送报告。", "周五", id="zh-send-before-weekday"),
        pytest.param("我会在周五前发邮件。", "周五", id="zh-email-before-weekday"),
        pytest.param("我不会在周五前发送报告。", "", id="zh-negated-send-before-weekday"),
        pytest.param("我可能会在周五前发邮件。", "", id="zh-uncertain-email-before-weekday"),
        pytest.param("我会在周五前发送报告，暂定。", "", id="zh-tentative-send-before-weekday"),
        pytest.param("I will submit the report, by Friday.", "friday", id="en-trailing-comma-deadline-bound"),
        pytest.param("I will not submit the report, by Friday.", "", id="en-negated-trailing-comma-bound"),
        pytest.param("I might submit the report, by Friday.", "", id="en-uncertain-trailing-comma-bound"),
        pytest.param("I will submit the report, by Friday, tentatively.", "", id="en-tentative-trailing-comma-bound"),
        pytest.param("I will submit the report. By Friday.", "", id="en-trailing-bound-does-not-cross-sentence"),
        pytest.param("The deadline remains Friday.", "friday", id="en-deadline-remains-weekday"),
        pytest.param("The deadline does not remain Friday.", "", id="en-negated-deadline-remains"),
        pytest.param("The deadline remains maybe Friday.", "", id="en-uncertain-deadline-remains"),
        pytest.param("The deadline remains Friday, tentatively.", "", id="en-tentative-deadline-remains"),
        pytest.param("Yann owns the export check by Friday.", "friday", id="en-owned-task-with-deadline-bound"),
        pytest.param("Yann does not own the export check by Friday.", "", id="en-negated-owned-task-bound"),
        pytest.param("Yann might own the export check by Friday.", "", id="en-uncertain-owned-task-bound"),
        pytest.param("Yann owns the export check on Friday.", "", id="en-ownership-without-deadline-bound"),
        pytest.param("The team will submit the draft and will not deliver the final report by Friday.", "", id="en-long-object-cannot-absorb-negated-next-action"),
        pytest.param("The team will submit the draft and might deliver the final report by Friday.", "", id="en-long-object-cannot-absorb-uncertain-next-action"),
        pytest.param("Submit the final report and the client checklist by Friday.", "friday", id="en-conjoined-objects-retain-their-deadline"),
        pytest.param("Remember, by Friday, submit the report.", "friday", id="en-leading-deadline-after-introductory-clause"),
        pytest.param("Remember, by Friday, do not submit the report.", "", id="en-leading-deadline-after-introduction-keeps-negation"),
        pytest.param("Submit the report tentatively, by Friday.", "", id="en-trailing-comma-bound-keeps-action-uncertainty"),
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


@pytest.mark.parametrize("trailing_qualifier", ["", ", tentatively."])
def test_local_minutes_completes_a_long_segment_with_rejected_dates(trailing_qualifier):
    # A generous subprocess deadline catches the former minute-long quadratic
    # stall without turning ordinary CI scheduling noise into a timing budget.
    program = """
import socket
import sys
import urllib.request
from insightkit.insights.service import InsightService
def no_network(*args, **kwargs):
    raise AssertionError('local minutes must not access the network')
socket.create_connection = no_network
urllib.request.urlopen = no_network
text = 'I own the report. ' + 'not Friday ' * 10_000 + sys.argv[1]
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
        [sys.executable, "-c", program, trailing_qualifier],
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
