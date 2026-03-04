"""Gap registry and selection helpers for automated iterations."""

from __future__ import annotations

import json
from dataclasses import dataclass, asdict
from pathlib import Path


@dataclass
class GapItem:
    gap_id: str
    severity: str  # P0/P1/P2
    title: str
    status: str = "open"  # open/in_progress/resolved/reopened/blocked
    notes: str = ""


BASELINE_GAPS: list[GapItem] = [
    GapItem("P0-G1", "P0", "ASR script path must be stable under Finder launch"),
    GapItem("P0-G2", "P0", "App-managed sidecar lifecycle"),
    GapItem("P0-G3", "P0", "Provider default should avoid Mock-first behavior"),
    GapItem("P0-G4", "P0", "RPC/ASR timeout, retry, and circuit protection"),
    GapItem("P1-G1", "P1", "document.export should render full module output"),
    GapItem("P1-G2", "P1", "RSS bridge should support live.session actions"),
    GapItem("P1-G3", "P1", "Compliance scanner should avoid self-hit"),
    GapItem("P1-G4", "P1", "Permission-denied recovery UX"),
    GapItem("P1-G5", "P1", "Chunk lifecycle cleanup and resource caps"),
    GapItem("P1-G6", "P1", "Menu commands wired to real actions"),
]


def load_registry(path: Path) -> list[GapItem]:
    if not path.exists():
        return [GapItem(**asdict(g)) for g in BASELINE_GAPS]

    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return [GapItem(**asdict(g)) for g in BASELINE_GAPS]
    out: list[GapItem] = []
    for raw in payload:
        severity = str(raw.get("severity", "P1")).strip().upper()
        if severity not in {"P0", "P1", "P2"}:
            severity = "P1"
        status = str(raw.get("status", "open")).strip().lower()
        if status not in {"open", "in_progress", "resolved", "reopened", "blocked"}:
            status = "open"
        out.append(
            GapItem(
                gap_id=str(raw.get("gap_id", "")),
                severity=severity,
                title=str(raw.get("title", "")),
                status=status,
                notes=str(raw.get("notes", "")),
            )
        )
    baseline_by_id = {x.gap_id: x for x in BASELINE_GAPS}
    for item in out:
        base = baseline_by_id.get(item.gap_id)
        if base is None:
            continue
        item.severity = base.severity
        item.title = base.title

    existing_ids = {x.gap_id for x in out}
    for base in BASELINE_GAPS:
        if base.gap_id in existing_ids:
            continue
        out.append(GapItem(**asdict(base)))
    return out


def save_registry(path: Path, items: list[GapItem]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps([asdict(x) for x in items], ensure_ascii=False, indent=2),
        encoding="utf-8",
    )


def current_phase(items: list[GapItem]) -> str:
    open_p0 = [x for x in items if x.severity == "P0" and x.status != "resolved"]
    if open_p0:
        return "P0"
    return "P1"


def select_targets(items: list[GapItem], phase: str) -> list[GapItem]:
    cap = 2 if phase == "P0" else 3
    candidates = [
        x
        for x in items
        if x.status in {"in_progress", "open", "reopened", "blocked"} and x.severity == phase
    ]

    def rank_key(item: GapItem) -> tuple[int, str]:
        status_rank = {"in_progress": 0, "open": 1, "reopened": 2, "blocked": 3, "resolved": 4}
        return (status_rank.get(item.status, 99), item.gap_id)

    candidates.sort(key=rank_key)
    return candidates[:cap]


def mark_targets(items: list[GapItem], target_ids: set[str], status: str) -> None:
    for item in items:
        if item.gap_id in target_ids:
            item.status = status


def unresolved_by_severity(items: list[GapItem]) -> dict[str, int]:
    out = {"P0": 0, "P1": 0, "P2": 0}
    for item in items:
        if item.status != "resolved":
            out[item.severity] = out.get(item.severity, 0) + 1
    return out
