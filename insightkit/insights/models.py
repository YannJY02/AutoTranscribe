"""InsightKit shared typed models."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass
class SessionOverview:
    title: str
    overview: str
    topics: list[str] = field(default_factory=list)


@dataclass
class HighlightInsight:
    quote: str
    reason: str
    speaker: str = ""
    evidence_span: dict[str, int] = field(default_factory=dict)


@dataclass
class SpeakerPerspective:
    speaker: str
    viewpoints: list[str] = field(default_factory=list)
    evidence_spans: list[dict[str, int]] = field(default_factory=list)


@dataclass
class DecisionLedgerItem:
    problem: str
    options: list[str]
    decision: str
    rationale: str
    owner: str = ""
    evidence_span: dict[str, int] = field(default_factory=dict)


@dataclass
class ActionTrackItem:
    task: str
    owner: str
    due_at: str = ""
    priority: str = "medium"
    status: str = "draft"
    evidence_span: dict[str, int] = field(default_factory=dict)


@dataclass
class TimelineBeat:
    timestamp: str
    title: str
    summary: str


@dataclass
class ProvenanceLink:
    label: str
    url: str


InsightPackage = dict[str, Any]
