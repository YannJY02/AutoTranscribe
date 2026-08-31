"""Render InsightPackage payload into shareable document sections."""

from __future__ import annotations

import textwrap
from html import escape
from pathlib import Path
from typing import Any


def _text(value: Any, fallback: str = "") -> str:
    rendered = str(value or "").strip()
    return rendered or fallback


def _speakers_from_segments(segments: list[dict[str, Any]] | None) -> list[str]:
    if not segments:
        return []
    speakers = {
        str(row.get("speaker", "") or "").strip()
        for row in segments
        if str(row.get("speaker", "") or "").strip()
    }
    return sorted(speakers)


def _meeting_time_label(meeting: dict[str, Any] | None) -> str:
    if not meeting:
        return "未记录"
    started = _text(meeting.get("started_at"))
    ended = _text(meeting.get("ended_at"))
    if started and ended:
        return f"{started} - {ended}"
    return started or ended or "未记录"


def _related_links(
    payload: dict[str, Any],
    *,
    meeting_id: str | None = None,
    source_path: str | None = None,
) -> list[dict[str, str]]:
    links: list[dict[str, str]] = []
    if meeting_id:
        links.append({"label": "原始记录", "url": f"InsightKit 本地会话: {meeting_id}"})
        links.append({"label": "文字记录", "url": f"InsightKit SQLite segments: meeting_id={meeting_id}"})

    for link in payload.get("provenance_links", []):
        label = _text(link.get("label"))
        url = _text(link.get("url"))
        if label and url:
            links.append({"label": label, "url": url})

    if source_path:
        links.append({"label": "媒体回放", "url": f"file://{Path(source_path).expanduser().resolve()}"})
    elif meeting_id:
        links.append({
            "label": "媒体回放",
            "url": "请在 InsightKit 记录详情页打开本地记录；此 RPC 导出未附加独立媒体文件路径。",
        })

    deduped: list[dict[str, str]] = []
    seen: set[str] = set()
    for link in links:
        key = link["url"]
        if key not in seen:
            seen.add(key)
            deduped.append(link)
    return deduped


def render_insight_markdown(
    payload: dict[str, Any],
    title: str,
    *,
    meeting: dict[str, Any] | None = None,
    transcript: list[dict[str, Any]] | None = None,
    meeting_id: str | None = None,
    source_path: str | None = None,
) -> str:
    overview = payload.get("session_overview", {})
    speakers = _speakers_from_segments(transcript)
    participant_label = ", ".join(speakers) if speakers else "本地记录未标注参会人；使用说话人标签降级。"

    lines: list[str] = []
    lines.append(f"# {title} - 定稿洞察")
    lines.append("")

    lines.append("## 会议信封")
    lines.append("")
    lines.append(f"- 文档标题: {title} - 定稿洞察")
    lines.append(f"- 会议主题: {_text(overview.get('title'), title)}")
    lines.append(f"- 会议时间: {_meeting_time_label(meeting)}")
    lines.append(f"- 参会人: {participant_label}")
    if meeting:
        lines.append(f"- 来源: {_text(meeting.get('source'), '未记录')}")
    lines.append("- AI 免责声明: 本文档由 InsightKit 根据本地逐字稿和记录文件自动生成，可能存在识别或总结误差；归档、分享或决策前请回看原始媒体并核对关键事实。")
    lines.append("")

    lines.append("## 长文版结构化总结")
    lines.append("")
    lines.append(overview.get("overview", ""))
    lines.append("")
    topics = overview.get("topics", [])
    for topic in topics:
        lines.append(f"- {topic}")
    lines.append("")

    lines.append("## 会议金句")
    lines.append("")
    for item in payload.get("highlight_insights", []):
        lines.append(f"- 「{item.get('quote', '')}」")
        lines.append(f"  - 说明: {item.get('reason', '')}")
        span = item.get("evidence_span", {})
        lines.append(f"  - 证据区间: {span.get('start_ms', 0)}-{span.get('end_ms', 0)}ms")
    lines.append("")

    lines.append("## 发言人总结")
    lines.append("")
    for sp in payload.get("speaker_perspectives", []):
        lines.append(f"- {sp.get('speaker', '未知发言人')}")
        for vp in sp.get("viewpoints", []):
            lines.append(f"  - {vp}")
    lines.append("")

    lines.append("## 关键决策")
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

    lines.append("## 待办事项")
    lines.append("")
    for action in payload.get("action_tracks", []):
        lines.append(f"- 任务: {action.get('task', '')}")
        lines.append(f"  - 负责人: {action.get('owner', '')}")
        lines.append(f"  - 截止: {action.get('due_at', '')}")
        lines.append(f"  - 优先级: {action.get('priority', '')}")
        lines.append(f"  - 状态: {action.get('status', '')}")
    lines.append("")

    lines.append("## 智能章节")
    lines.append("")
    for beat in payload.get("timeline_beats", []):
        lines.append(f"- {beat.get('timestamp', '')} {beat.get('title', '')}")
        lines.append(f"  - {beat.get('summary', '')}")
    lines.append("")

    lines.append("## 相关链接")
    lines.append("")
    links = _related_links(payload, meeting_id=meeting_id, source_path=source_path)
    if not links:
        lines.append("- 当前导出未附加原始记录、文字记录或媒体回放链接。")
    for link in links:
        lines.append(f"- {link.get('label', '')}: {link.get('url', '')}")
    lines.append("")

    return "\n".join(lines)


def render_insight_html(
    payload: dict[str, Any],
    title: str,
    *,
    meeting: dict[str, Any] | None = None,
    transcript: list[dict[str, Any]] | None = None,
    meeting_id: str | None = None,
    source_path: str | None = None,
) -> str:
    """Render the same meeting asset as a printable HTML document."""
    overview = payload.get("session_overview", {})
    speakers = _speakers_from_segments(transcript)
    participant_label = ", ".join(speakers) if speakers else "本地记录未标注参会人；使用说话人标签降级。"

    def text(value: Any) -> str:
        return escape(str(value or ""))

    def span_label(item: dict[str, Any]) -> str:
        span = item.get("evidence_span", {})
        start_ms = span.get("start_ms", 0)
        end_ms = span.get("end_ms", 0)
        return f"{start_ms}-{end_ms}ms"

    parts: list[str] = [
        "<!doctype html>",
        '<html lang="zh-Hans">',
        "<head>",
        '<meta charset="utf-8">',
        f"<title>{text(title)} - 定稿洞察</title>",
        "<style>",
        """
        @page { size: A4; margin: 22mm 18mm; }
        body {
            color: #1d1d1f;
            font-family: -apple-system, BlinkMacSystemFont, "PingFang SC",
                "Hiragino Sans GB", "Noto Sans CJK SC", sans-serif;
            font-size: 12px;
            line-height: 1.55;
        }
        h1 { font-size: 24px; margin: 0 0 18px; }
        h2 {
            border-bottom: 1px solid #d8dee4;
            font-size: 16px;
            margin: 22px 0 10px;
            padding-bottom: 5px;
        }
        p { margin: 6px 0 8px; }
        ul { margin: 6px 0 12px 18px; padding: 0; }
        li { margin: 4px 0; }
        .muted { color: #636b74; }
        .quote { font-weight: 600; }
        .meta-grid {
            border: 1px solid #d8dee4;
            border-radius: 8px;
            display: grid;
            grid-template-columns: 90px 1fr;
            overflow: hidden;
        }
        .meta-grid div { padding: 8px 10px; border-bottom: 1px solid #edf0f2; }
        .meta-grid div:nth-child(odd) { background: #f6f8fa; font-weight: 600; }
        .meta-grid div:nth-last-child(-n+2) { border-bottom: 0; }
        .item {
            border-left: 3px solid #3b82f6;
            margin: 8px 0;
            padding: 2px 0 2px 10px;
        }
        """,
        "</style>",
        "</head>",
        "<body>",
        f"<h1>{text(title)} - 定稿洞察</h1>",
        '<section class="meta-grid">',
        "<div>文档标题</div>",
        f"<div>{text(title)} - 定稿洞察</div>",
        "<div>会议主题</div>",
        f"<div>{text(overview.get('title', title))}</div>",
        "<div>会议时间</div>",
        f"<div>{text(_meeting_time_label(meeting))}</div>",
        "<div>参会人</div>",
        f"<div>{text(participant_label)}</div>",
        "<div>来源</div>",
        f"<div>{text(meeting.get('source', '未记录') if meeting else '未记录')}</div>",
        "<div>AI 免责声明</div>",
        "<div>本文档由 InsightKit 根据本地逐字稿和记录文件自动生成，可能存在识别或总结误差；归档、分享或决策前请回看原始媒体并核对关键事实。</div>",
        "</section>",
        "<h2>长文版结构化总结</h2>",
        f"<p>{text(overview.get('overview', ''))}</p>",
    ]

    topics = overview.get("topics", [])
    if topics:
        parts.append("<ul>")
        for topic in topics:
            parts.append(f"<li>{text(topic)}</li>")
        parts.append("</ul>")

    parts.append("<h2>会议金句</h2>")
    for item in payload.get("highlight_insights", []):
        parts.extend([
            '<div class="item">',
            f'<p class="quote">“{text(item.get("quote", ""))}”</p>',
            f'<p class="muted">说明: {text(item.get("reason", ""))}</p>',
            f'<p class="muted">证据区间: {text(span_label(item))}</p>',
            "</div>",
        ])

    parts.append("<h2>发言人总结</h2>")
    for speaker in payload.get("speaker_perspectives", []):
        parts.append(f'<p><strong>{text(speaker.get("speaker", "未知发言人"))}</strong></p>')
        viewpoints = speaker.get("viewpoints", [])
        if viewpoints:
            parts.append("<ul>")
            for viewpoint in viewpoints:
                parts.append(f"<li>{text(viewpoint)}</li>")
            parts.append("</ul>")

    parts.append("<h2>关键决策</h2>")
    for item in payload.get("decision_ledger", []):
        parts.extend([
            '<div class="item">',
            f"<p><strong>问题:</strong> {text(item.get('problem', ''))}</p>",
            f"<p><strong>方案:</strong> {text(', '.join(item.get('options', [])))}</p>",
            f"<p><strong>决策:</strong> {text(item.get('decision', ''))}</p>",
            f"<p><strong>依据:</strong> {text(item.get('rationale', ''))}</p>",
            f"<p><strong>Owner:</strong> {text(item.get('owner', ''))}</p>",
            f'<p class="muted">证据区间: {text(span_label(item))}</p>',
            "</div>",
        ])

    parts.append("<h2>待办事项</h2>")
    for action in payload.get("action_tracks", []):
        parts.extend([
            '<div class="item">',
            f"<p><strong>任务:</strong> {text(action.get('task', ''))}</p>",
            f"<p><strong>负责人:</strong> {text(action.get('owner', ''))}</p>",
            f"<p><strong>截止:</strong> {text(action.get('due_at', ''))}</p>",
            f"<p><strong>优先级:</strong> {text(action.get('priority', ''))}</p>",
            f"<p><strong>状态:</strong> {text(action.get('status', ''))}</p>",
            "</div>",
        ])

    parts.append("<h2>智能章节</h2>")
    for beat in payload.get("timeline_beats", []):
        parts.extend([
            '<div class="item">',
            f"<p><strong>{text(beat.get('timestamp', ''))} {text(beat.get('title', ''))}</strong></p>",
            f"<p>{text(beat.get('summary', ''))}</p>",
            "</div>",
        ])

    parts.append("<h2>相关链接</h2>")
    links = _related_links(payload, meeting_id=meeting_id, source_path=source_path)
    if links:
        parts.append("<ul>")
        for link in links:
            parts.append(f"<li>{text(link.get('label', ''))}: {text(link.get('url', ''))}</li>")
        parts.append("</ul>")
    else:
        parts.append('<p class="muted">当前导出未附加原始记录、文字记录或媒体回放链接。</p>')

    parts.extend([
        "</body>",
        "</html>",
    ])
    return "\n".join(parts)


def _markdown_to_plain_lines(markdown: str) -> list[str]:
    lines: list[str] = []
    for raw in markdown.splitlines():
        line = raw.rstrip()
        stripped = line.strip()
        if not stripped:
            lines.append("")
            continue
        if stripped.startswith("# "):
            lines.append(stripped[2:].strip())
        elif stripped.startswith("## "):
            lines.extend(["", stripped[3:].strip()])
        elif stripped.startswith("> "):
            lines.append(stripped[2:].strip())
        else:
            lines.append(line)
    return lines


def _wrap_pdf_line(line: str, width: int = 62) -> list[str]:
    if len(line) <= width:
        return [line]
    wrapped = textwrap.wrap(
        line,
        width=width,
        break_long_words=False,
        replace_whitespace=False,
    )
    chunks: list[str] = []
    for item in wrapped or [line]:
        if len(item) <= width:
            chunks.append(item)
            continue
        chunks.extend(item[index:index + width] for index in range(0, len(item), width))
    return chunks


def _pdf_text_hex(line: str) -> str:
    return line.encode("utf-16-be", errors="replace").hex().upper()


def _write_builtin_text_pdf(lines: list[str], output_path: Path) -> None:
    """Write a simple Unicode PDF without optional Python PDF dependencies."""
    output_path.parent.mkdir(parents=True, exist_ok=True)
    body_lines: list[str] = []
    for line in lines:
        wrapped = _wrap_pdf_line(line)
        body_lines.extend(wrapped)
    if not body_lines:
        body_lines = ["InsightKit 导出文档"]

    lines_per_page = 52
    pages = [
        body_lines[index:index + lines_per_page]
        for index in range(0, len(body_lines), lines_per_page)
    ]

    page_count = len(pages)
    page_ids = list(range(5, 5 + page_count))
    content_ids = list(range(5 + page_count, 5 + page_count * 2))
    max_object_id = 4 + page_count * 2

    objects: dict[int, bytes] = {
        1: b"<< /Type /Catalog /Pages 2 0 R >>",
        2: (
            f"<< /Type /Pages /Kids [{' '.join(f'{page_id} 0 R' for page_id in page_ids)}] "
            f"/Count {page_count} >>"
        ).encode("ascii"),
        3: (
            b"<< /Type /Font /Subtype /Type0 /BaseFont /STSong-Light "
            b"/Encoding /UniGB-UCS2-H /DescendantFonts [4 0 R] >>"
        ),
        4: (
            b"<< /Type /Font /Subtype /CIDFontType0 /BaseFont /STSong-Light "
            b"/CIDSystemInfo << /Registry (Adobe) /Ordering (GB1) /Supplement 2 >> >>"
        ),
    }

    for index, page_lines in enumerate(pages):
        page_id = page_ids[index]
        content_id = content_ids[index]
        objects[page_id] = (
            f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] "
            f"/Resources << /Font << /F1 3 0 R >> >> /Contents {content_id} 0 R >>"
        ).encode("ascii")

        content = bytearray()
        content.extend(b"BT\n/F1 10 Tf\n50 800 Td\n14 TL\n")
        for line in page_lines:
            if line:
                content.extend(f"<{_pdf_text_hex(line)}> Tj\n".encode("ascii"))
            content.extend(b"T*\n")
        content.extend(b"ET\n")
        objects[content_id] = (
            f"<< /Length {len(content)} >>\nstream\n".encode("ascii")
            + bytes(content)
            + b"endstream"
        )

    pdf = bytearray(b"%PDF-1.4\n%\xE2\xE3\xCF\xD3\n")
    offsets = [0] * (max_object_id + 1)
    for object_id in range(1, max_object_id + 1):
        offsets[object_id] = len(pdf)
        pdf.extend(f"{object_id} 0 obj\n".encode("ascii"))
        pdf.extend(objects[object_id])
        pdf.extend(b"\nendobj\n")

    xref_offset = len(pdf)
    pdf.extend(f"xref\n0 {max_object_id + 1}\n".encode("ascii"))
    pdf.extend(b"0000000000 65535 f \n")
    for object_id in range(1, max_object_id + 1):
        pdf.extend(f"{offsets[object_id]:010d} 00000 n \n".encode("ascii"))
    pdf.extend(
        f"trailer\n<< /Size {max_object_id + 1} /Root 1 0 R >>\n"
        f"startxref\n{xref_offset}\n%%EOF\n".encode("ascii")
    )

    output_path.write_bytes(bytes(pdf))


def write_insight_pdf(
    payload: dict[str, Any],
    title: str,
    output_path: Path,
    *,
    meeting: dict[str, Any] | None = None,
    transcript: list[dict[str, Any]] | None = None,
    meeting_id: str | None = None,
    source_path: str | None = None,
) -> None:
    """Write a real PDF file using the sidecar Python runtime."""
    output_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        from weasyprint import HTML
    except ImportError:
        markdown = render_insight_markdown(
            payload,
            title=title,
            meeting=meeting,
            transcript=transcript,
            meeting_id=meeting_id,
            source_path=source_path,
        )
        _write_builtin_text_pdf(_markdown_to_plain_lines(markdown), output_path)
        return

    HTML(
        string=render_insight_html(
            payload,
            title=title,
            meeting=meeting,
            transcript=transcript,
            meeting_id=meeting_id,
            source_path=source_path,
        ),
        base_url=str(output_path.parent),
    ).write_pdf(str(output_path))

    if not output_path.exists() or output_path.stat().st_size == 0:
        raise RuntimeError(f"PDF export did not create a readable file: {output_path}")
