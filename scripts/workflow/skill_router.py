"""Skill routing heuristics for gap-driven iterations."""

from __future__ import annotations

import json
from pathlib import Path


LOCAL_SKILLS = [
    "macos-developer",
    "macos-design-guidelines",
    "ui-ux-pro-max",
    "frontend-design",
    "senior-prompt-engineer",
    "app-store-review",
    "git-commit",
]


def route_skills(gap_ids: list[str]) -> dict:
    _ = gap_ids
    deduped = [
        "macos-developer",
        "macos-design-guidelines",
        "ui-ux-pro-max",
        "frontend-design",
        "app-store-review",
        "git-commit",
    ]
    return {
        "selected_skills": deduped,
        "available_local_skills": LOCAL_SKILLS,
        "fallback": {
            "strategy": "find-skills",
            "allow_external_github": True,
            "supply_gates": ["SG0", "SG1", "SG2", "SG3", "SG4", "SG5"],
        },
    }


def save_route_decision(path: Path, round_id: int, phase: str, gap_ids: list[str]) -> dict:
    decision = {
        "round": round_id,
        "phase": phase,
        "gap_ids": gap_ids,
    }
    decision.update(route_skills(gap_ids))

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(decision, ensure_ascii=False, indent=2), encoding="utf-8")
    return decision
