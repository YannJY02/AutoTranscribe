"""Render InsightPackage payload into markdown document sections."""

from __future__ import annotations

from typing import Any


def render_insight_markdown(payload: dict[str, Any], title: str) -> str:
    overview = payload.get("session_overview", {})

    lines: list[str] = []
    lines.append(f"# {title} - 定稿洞察")
    lines.append("")

    lines.append("## 会议信封")
    lines.append("")
    lines.append(f"- 标题: {overview.get('title', title)}")
    lines.append("- 说明: 本文档由 InsightKit 自动生成，请人工复核后使用。")
    lines.append("")

    lines.append("## 全景纪要")
    lines.append("")
    lines.append(overview.get("overview", ""))
    lines.append("")
    topics = overview.get("topics", [])
    for topic in topics:
        lines.append(f"- {topic}")
    lines.append("")

    lines.append("## 高光洞察")
    lines.append("")
    for item in payload.get("highlight_insights", []):
        lines.append(f"- 「{item.get('quote', '')}」")
        lines.append(f"  - 说明: {item.get('reason', '')}")
        span = item.get("evidence_span", {})
        lines.append(f"  - 证据区间: {span.get('start_ms', 0)}-{span.get('end_ms', 0)}ms")
    lines.append("")

    lines.append("## 观点图谱")
    lines.append("")
    for sp in payload.get("speaker_perspectives", []):
        lines.append(f"- {sp.get('speaker', '未知发言人')}")
        for vp in sp.get("viewpoints", []):
            lines.append(f"  - {vp}")
    lines.append("")

    lines.append("## 决策账本")
    lines.append("")
    for item in payload.get("decision_ledger", []):
        lines.append(f"- 问题: {item.get('problem', '')}")
        lines.append(f"  - 方案: {', '.join(item.get('options', []))}")
        lines.append(f"  - 决策: {item.get('decision', '')}")
        lines.append(f"  - 依据: {item.get('rationale', '')}")
        lines.append(f"  - Owner: {item.get('owner', '')}")
        span = item.get("evidence_span", {})
        lines.append(f"  - 证据区间: {span.get('start_ms', 0)}-{span.get('end_ms', 0)}ms")
    lines.append("")

    lines.append("## 执行清单")
    lines.append("")
    for action in payload.get("action_tracks", []):
        lines.append(f"- 任务: {action.get('task', '')}")
        lines.append(f"  - 负责人: {action.get('owner', '')}")
        lines.append(f"  - 截止: {action.get('due_at', '')}")
        lines.append(f"  - 优先级: {action.get('priority', '')}")
        lines.append(f"  - 状态: {action.get('status', '')}")
    lines.append("")

    lines.append("## 时间脉络")
    lines.append("")
    for beat in payload.get("timeline_beats", []):
        lines.append(f"- {beat.get('timestamp', '')} {beat.get('title', '')}")
        lines.append(f"  - {beat.get('summary', '')}")
    lines.append("")

    lines.append("## 溯源链接")
    lines.append("")
    for link in payload.get("provenance_links", []):
        lines.append(f"- {link.get('label', '')}: {link.get('url', '')}")
    lines.append("")

    lines.append("## 交互占位提示")
    lines.append("")
    lines.append("- 本导出不包含交互式反馈组件。")

    return "\n".join(lines)
