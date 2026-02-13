"""文件管理 — 移动、重命名、编号、Markdown 生成。"""

import json
import shutil
import logging
from datetime import datetime
from pathlib import Path
from typing import Optional

from config import VIDEO_DIR, TXT_DIR, PROCESSED_FILE

logger = logging.getLogger(__name__)


# ── 已处理文件记录 ────────────────────────────────────────

def load_processed() -> set:
    """加载已处理文件列表。"""
    if PROCESSED_FILE.exists():
        try:
            data = json.loads(PROCESSED_FILE.read_text(encoding="utf-8"))
            return set(data)
        except Exception:
            return set()
    return set()


def save_processed(processed: set) -> None:
    """保存已处理文件列表。"""
    PROCESSED_FILE.parent.mkdir(parents=True, exist_ok=True)
    PROCESSED_FILE.write_text(
        json.dumps(sorted(processed), ensure_ascii=False, indent=2),
        encoding="utf-8",
    )


def mark_processed(filepath: str) -> None:
    """将文件标记为已处理。"""
    processed = load_processed()
    processed.add(filepath)
    save_processed(processed)


def is_processed(filepath: str) -> bool:
    """检查文件是否已处理过。"""
    return filepath in load_processed()


# ── 编号与命名 ────────────────────────────────────────────

def get_next_index(date: datetime, lang: str) -> int:
    """获取当天同语言下一个编号。"""
    prefix = f"{date.year}_{date.month}_{date.day}_{lang}_"
    existing = []
    for f in VIDEO_DIR.iterdir():
        name = f.stem
        # 去掉 fail_ 前缀
        if name.startswith("fail_"):
            name = name[5:]
        if name.startswith(prefix):
            try:
                idx = int(name[len(prefix):])
                existing.append(idx)
            except ValueError:
                pass
    return max(existing, default=0) + 1


def generate_standard_name(lang: str, date: Optional[datetime] = None) -> str:
    """生成标准文件名（不含扩展名），如 2026_2_13_zh_1。"""
    if date is None:
        date = datetime.now()
    idx = get_next_index(date, lang)
    return f"{date.year}_{date.month}_{date.day}_{lang}_{idx}"


def move_video(src: Path, standard_name: str, success: bool) -> Path:
    """移动视频到 video/ 并重命名。"""
    ext = src.suffix
    if success:
        dest_name = f"{standard_name}{ext}"
    else:
        dest_name = f"fail_{standard_name}{ext}"

    dest = VIDEO_DIR / dest_name
    # 处理重名
    counter = 1
    while dest.exists():
        if success:
            dest = VIDEO_DIR / f"{standard_name}_{counter}{ext}"
        else:
            dest = VIDEO_DIR / f"fail_{standard_name}_{counter}{ext}"
        counter += 1

    shutil.move(str(src), str(dest))
    logger.info(f"视频已移动: {src.name} → {dest.name}")
    return dest


# ── Markdown 输出 ─────────────────────────────────────────

def format_timestamp(ms: int) -> str:
    """毫秒 → HH:MM:SS 格式。"""
    total_seconds = ms // 1000
    h = total_seconds // 3600
    m = (total_seconds % 3600) // 60
    s = total_seconds % 60
    return f"{h:02d}:{m:02d}:{s:02d}"


def save_transcript_md(
    standard_name: str,
    lang: str,
    duration_sec: float,
    segments: list[dict],
) -> Path:
    """
    将转录结果保存为 Markdown 文件。

    segments 格式: [
        {
            "start": 0,       # 毫秒
            "end": 5000,      # 毫秒
            "text": "...",
            "speaker": "spk0" # 可选
        },
        ...
    ]
    """
    lang_label = "中文" if lang == "zh" else "English" if lang == "en" else lang
    h = int(duration_sec) // 3600
    m = (int(duration_sec) % 3600) // 60
    s = int(duration_sec) % 60
    duration_str = f"{h:02d}:{m:02d}:{s:02d}"

    # 统计说话人数量
    speakers = set()
    for seg in segments:
        if "speaker" in seg and seg["speaker"]:
            speakers.add(seg["speaker"])
    num_speakers = len(speakers) if speakers else "未知"

    lines = [
        f"# 转录: {standard_name}",
        "",
        "| 项目 | 值 |",
        "|------|-----|",
        f"| 语言 | {lang_label} |",
        "| 引擎 | FunASR Paraformer |",
        f"| 时长 | {duration_str} |",
        f"| 说话人 | {num_speakers} |",
        "",
        "---",
        "",
    ]

    # 建立 speaker 映射 (spk0 → 说话人1)
    speaker_map = {}
    speaker_counter = 1
    for seg in segments:
        spk = seg.get("speaker", "")
        if spk and spk not in speaker_map:
            speaker_map[spk] = f"说话人{speaker_counter}"
            speaker_counter += 1

    # 写入内容
    for seg in segments:
        start_str = format_timestamp(seg.get("start", 0))
        end_str = format_timestamp(seg.get("end", 0))
        text = seg.get("text", "").strip()
        spk = seg.get("speaker", "")

        if spk and spk in speaker_map:
            lines.append(f"**[{start_str} → {end_str}] {speaker_map[spk]}:**")
        else:
            lines.append(f"**[{start_str} → {end_str}]**")

        lines.append(text)
        lines.append("")

    md_path = TXT_DIR / f"{standard_name}.md"
    md_path.write_text("\n".join(lines), encoding="utf-8")
    logger.info(f"Markdown 已保存: {md_path.name}")
    return md_path
