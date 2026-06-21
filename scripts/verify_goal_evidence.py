#!/usr/bin/env python3
"""Aggregate InsightKit goal evidence against the Legacy product rationale.

This verifier reads the latest real runtime, visual GUI, and release-readiness
proofs. It does not launch the app, run GUI automation, or delete artifacts.
Its job is to keep the active goal auditable as one machine-readable ledger.
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from verify_release_readiness import (  # noqa: E402
    DEFAULT_APP,
    DEFAULT_DIAGNOSTICS_ROOT,
    latest_path,
    load_json,
    read_app_info,
    summarize_url_import_proof,
    summarize_visual_proof,
)

ROOT_DIR = SCRIPT_DIR.parent
LEGACY_LIBRARY_DIR = ROOT_DIR / "docs" / "Legacy" / "matt-workflow-library"
OVERVIEW_DOC = LEGACY_LIBRARY_DIR / "original-assets" / "docs" / "Legacy" / "overview.md"
GOAL_EVIDENCE_DOC = LEGACY_LIBRARY_DIR / "original-assets" / "docs" / "plans" / "2026-05-23-insightkit-goal-evidence.md"
RELEASE_READINESS_DOC = LEGACY_LIBRARY_DIR / "original-assets" / "docs" / "plans" / "2026-05-26-insightkit-release-readiness-status.md"
RELEASE_VERIFICATION_DOC = LEGACY_LIBRARY_DIR / "original-assets" / "docs" / "plans" / "2026-05-24-insightkit-release-verification.md"
LIVE_RECORDING_PROOF = ROOT_DIR / "logs" / "diagnostics" / "2026-05-24" / "live-recording-media-proof.json"
LIVE_MINUTES_PROOF = ROOT_DIR / "logs" / "diagnostics" / "2026-05-25" / "live-final-minutes-persistence-proof.json"


def iso_now() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def today_output_root() -> Path:
    day = datetime.now().strftime("%Y-%m-%d")
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    return DEFAULT_DIAGNOSTICS_ROOT / day / f"goal-evidence-status-{stamp}"


def latest_release_readiness_proof() -> Path | None:
    return latest_path("*/release-readiness-status-*/proof.json")


def latest_secret_hygiene_proof() -> Path | None:
    return latest_path("*/secret-hygiene-*/proof.json")


def latest_ui_hygiene_proof() -> Path | None:
    return latest_path("*/ui-hygiene-*/proof.json")


def requirement(id_: str, title: str, ok: bool, evidence: str, status: str = "verified") -> dict[str, Any]:
    return {
        "id": id_,
        "title": title,
        "status": status if ok else "missing",
        "evidence": evidence,
    }


def degraded_requirement(id_: str, title: str, ok: bool, evidence: str) -> dict[str, Any]:
    return requirement(id_, title, ok, evidence, status="personal-local-degradation")


def external_blocker(id_: str, title: str, ok: bool, evidence: str) -> dict[str, Any]:
    return requirement(id_, title, ok, evidence, status="externally-blocked")


def markdown_sections(runtime_data: dict[str, Any]) -> set[str]:
    exports = runtime_data.get("exports") or {}
    return {str(item) for item in exports.get("markdown_required_sections") or []}


def record_validation(runtime_data: dict[str, Any]) -> dict[str, Any]:
    value = runtime_data.get("record_validation") or {}
    return value if isinstance(value, dict) else {}


def visual_observations(visual_data: dict[str, Any]) -> dict[str, Any]:
    value = visual_data.get("computer_use_observations") or {}
    return value if isinstance(value, dict) else {}


def smart_minutes_sections(visual_data: dict[str, Any]) -> set[str]:
    detail = visual_observations(visual_data).get("record_detail") or {}
    return {str(item) for item in detail.get("smart_minutes_sections_visible") or []}


def seek_linkage(visual_data: dict[str, Any]) -> dict[str, Any]:
    value = visual_observations(visual_data).get("seek_linkage") or {}
    return value if isinstance(value, dict) else {}


def build_product_requirements(runtime_data: dict[str, Any], visual_data: dict[str, Any]) -> list[dict[str, Any]]:
    sections = markdown_sections(runtime_data)
    validation = record_validation(runtime_data)
    visual_sections = smart_minutes_sections(visual_data)
    observations = visual_observations(visual_data)
    records_search = observations.get("records_search") or {}
    seek = seek_linkage(visual_data)
    note_text = str(validation.get("note_text") or "")
    job = runtime_data.get("job") or {}
    latest_recent = str((observations.get("home") or {}).get("latest_recent_record") or "")
    record_id = str(visual_data.get("record_id") or "")
    detail_ids = set((observations.get("record_detail") or {}).get("visible_ids") or [])

    required_export_sections = {
        "## 会议信封",
        "## 长文版结构化总结",
        "## 会议金句",
        "## 发言人总结",
        "## 关键决策",
        "## 待办事项",
        "## 智能章节",
        "## 相关链接",
        "AI 免责声明",
        "媒体回放",
    }
    return [
        requirement(
            "ai.summary",
            "AI 摘要视图包含总结",
            "summary" in visual_sections,
            f"visual sections={sorted(visual_sections)}",
        ),
        requirement(
            "ai.meeting_quote",
            "AI 摘要视图包含会议金句",
            "meeting_quote" in visual_sections and "## 会议金句" in sections,
            f"visual sections={sorted(visual_sections)}; markdown sections={sorted(sections)}",
        ),
        requirement(
            "ai.speaker_summary",
            "AI 摘要视图包含发言人总结",
            "speaker_summary" in visual_sections and "## 发言人总结" in sections,
            f"visual sections={sorted(visual_sections)}; markdown sections={sorted(sections)}",
        ),
        requirement(
            "ai.key_decisions",
            "AI 摘要视图包含关键决策",
            "key_decision" in visual_sections and "## 关键决策" in sections,
            f"visual sections={sorted(visual_sections)}; markdown sections={sorted(sections)}",
        ),
        requirement(
            "ai.action_items",
            "AI 摘要视图包含待办事项",
            "action_item" in visual_sections and "## 待办事项" in sections,
            f"visual sections={sorted(visual_sections)}; markdown sections={sorted(sections)}",
        ),
        requirement(
            "ai.smart_chapters",
            "AI 摘要视图包含智能章节",
            "smart_chapter" in visual_sections and "## 智能章节" in sections,
            f"visual sections={sorted(visual_sections)}; markdown sections={sorted(sections)}",
        ),
        requirement(
            "export.body",
            "会议纪要正文 / Markdown / PDF 导出覆盖头部、免责声明、总结、待办、章节、相关链接",
            required_export_sections.issubset(sections)
            and bool((runtime_data.get("exports") or {}).get("markdown_path"))
            and bool((runtime_data.get("exports") or {}).get("pdf_path")),
            f"required_sections_present={sorted(required_export_sections.intersection(sections))}",
        ),
        requirement(
            "raw.import",
            "音频/视频导入走真实媒体路径",
            (job.get("state") == "completed") and bool(job.get("source_path")),
            f"job_state={job.get('state')}; source_path={job.get('source_path')}",
        ),
        degraded_requirement(
            "raw.recording_fallback",
            "实时录制使用个人本地可防守降级路径",
            LIVE_RECORDING_PROOF.exists() and LIVE_MINUTES_PROOF.exists(),
            f"{LIVE_RECORDING_PROOF}; {LIVE_MINUTES_PROOF}",
        ),
        requirement(
            "raw.timestamped_transcript",
            "逐字稿带时间戳",
            int(validation.get("timestamped_rows") or 0) > 0,
            f"timestamped_rows={validation.get('timestamped_rows')}",
        ),
        requirement(
            "raw.speaker_labels",
            "逐字稿包含说话人标记或保守降级标签",
            bool(validation.get("speaker_labels") or []),
            f"speaker_labels={validation.get('speaker_labels')}",
        ),
        requirement(
            "raw.media_linkage",
            "章节、逐字稿、笔记点击可跳转媒体时间点",
            bool((seek.get("chapter_click") or {}).get("visible_status"))
            and bool((seek.get("transcript_click") or {}).get("visible_status"))
            and bool((seek.get("note_click") or {}).get("visible_status")),
            json.dumps(seek, ensure_ascii=False),
        ),
        requirement(
            "raw.search_filter_records",
            "记录管理包含搜索/筛选并验证 SQLite/FTS",
            bool(records_search.get("visible_count_text")) and int((runtime_data.get("fts_validation") or {}).get("result_count") or 0) > 0,
            f"records_search={records_search}; fts={runtime_data.get('fts_validation')}",
        ),
        requirement(
            "raw.time_bound_notes",
            "笔记与录制时间绑定并可恢复",
            note_text.startswith("00:") and "live_note_row_0" in detail_ids,
            f"note_text={note_text}; detail_ids={sorted(detail_ids)}",
        ),
        requirement(
            "raw.restart_recovery",
            "重启/重开后恢复记录、媒体、纪要、逐字稿、笔记和导出入口",
            bool(record_id) and latest_recent == record_id and {
                "record_export_markdown_button",
                "record_export_pdf_button",
                "record_transcript_title",
                "record_media_seek_status",
            }.issubset(detail_ids),
            f"latest_recent={latest_recent}; record_id={record_id}; detail_ids={sorted(detail_ids)}",
        ),
    ]


def build_engineering_requirements(release_data: dict[str, Any], secret_data: dict[str, Any], ui_data: dict[str, Any]) -> list[dict[str, Any]]:
    app_info = release_data.get("app_info") or {}
    runtime = release_data.get("runtime_proof") or {}
    visual = release_data.get("visual_proof") or {}
    preflight = release_data.get("preflight") or {}
    process_cleanup = release_data.get("process_cleanup") or {}
    usage = app_info.get("usage_descriptions") or {}
    local_preflight = preflight.get("local") or {}
    developer_id = preflight.get("developer_id") or {}
    app_store = preflight.get("app_store") or {}

    return [
        requirement(
            "engineering.schema_sidecar_sqlite_fts_export",
            "schema、sidecar、SQLite/FTS、Markdown/PDF 导出在真实导入 proof 中验证",
            runtime.get("status") == "passed",
            f"runtime_proof={runtime.get('path')}",
        ),
        requirement(
            "engineering.visual_gui",
            "GUI 真实路径截图级验证通过",
            visual.get("status") == "passed",
            f"visual_proof={visual.get('path')}",
        ),
        requirement(
            "engineering.process_cleanup",
            "退出后无 app、sidecar、socket 残留",
            process_cleanup.get("exit_code") == 0 and "No socket:" in str(process_cleanup.get("output") or ""),
            str(process_cleanup.get("output") or ""),
        ),
        requirement(
            "release.metadata_permissions_icon",
            "bundle metadata、icon、权限说明存在",
            app_info.get("bundle_id") == "com.yannjy.insightkit"
            and bool(app_info.get("version"))
            and bool(app_info.get("build"))
            and bool(app_info.get("icon_file"))
            and all(bool(usage.get(key)) for key in ("NSMicrophoneUsageDescription", "NSCameraUsageDescription", "NSScreenCaptureUsageDescription")),
            json.dumps(
                {
                    "bundle_id": app_info.get("bundle_id"),
                    "version": app_info.get("version"),
                    "build": app_info.get("build"),
                    "icon_file": app_info.get("icon_file"),
                    "usage_keys": sorted([key for key, value in usage.items() if value]),
                },
                ensure_ascii=False,
            ),
        ),
        requirement(
            "release.local_preflight",
            "本机 local release preflight 通过",
            local_preflight.get("status") == "local-release-ready" and local_preflight.get("failure_count") == 0,
            f"status={local_preflight.get('status')}; failures={local_preflight.get('failures')}",
        ),
        requirement(
            "release.secret_hygiene",
            "源码/配置/文档无高置信度硬编码密钥或私钥",
            secret_data.get("status") == "passed" and int(secret_data.get("scanned_files") or 0) > 0 and not secret_data.get("findings"),
            f"status={secret_data.get('status')}; scanned_files={secret_data.get('scanned_files')}; findings={len(secret_data.get('findings') or [])}",
        ),
        requirement(
            "release.ui_hygiene",
            "App UI 源码无发布阻塞占位、空按钮或永久禁用控件",
            ui_data.get("status") == "passed" and int(ui_data.get("scanned_files") or 0) > 0 and not ui_data.get("findings"),
            f"status={ui_data.get('status')}; scanned_files={ui_data.get('scanned_files')}; findings={len(ui_data.get('findings') or [])}",
        ),
        external_blocker(
            "release.developer_id",
            "Developer ID 公证分发外部条件已显式标注",
            developer_id.get("status") == "externally-blocked" or developer_id.get("status") == "developer-id-ready",
            f"status={developer_id.get('status')}; failures={developer_id.get('failures')}",
        ),
        external_blocker(
            "release.app_store",
            "Mac App Store 外部条件已显式标注",
            app_store.get("status") == "externally-blocked" or app_store.get("status") == "app-store-ready",
            f"status={app_store.get('status')}; failures={app_store.get('failures')}",
        ),
    ]


def build_doc_requirements() -> list[dict[str, Any]]:
    return [
        requirement("docs.overview", "overview.md 基准存在", OVERVIEW_DOC.exists(), str(OVERVIEW_DOC)),
        requirement("docs.goal_evidence", "目标 evidence ledger 存在", GOAL_EVIDENCE_DOC.exists(), str(GOAL_EVIDENCE_DOC)),
        requirement("docs.release_readiness", "发布 readiness 状态表存在", RELEASE_READINESS_DOC.exists(), str(RELEASE_READINESS_DOC)),
        requirement("docs.release_verification", "发布验证 checklist 存在", RELEASE_VERIFICATION_DOC.exists(), str(RELEASE_VERIFICATION_DOC)),
    ]


def status_counts(requirements: list[dict[str, Any]]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for item in requirements:
        status = str(item.get("status") or "unknown")
        counts[status] = counts.get(status, 0) + 1
    return counts


def determine_goal_status(requirements: list[dict[str, Any]], release_data: dict[str, Any]) -> str:
    counts = status_counts(requirements)
    if counts.get("missing", 0) > 0:
        return "incomplete"
    app_store = ((release_data.get("preflight") or {}).get("app_store") or {}).get("status")
    developer_id = ((release_data.get("preflight") or {}).get("developer_id") or {}).get("status")
    if app_store == "app-store-ready" or developer_id == "developer-id-ready":
        return "release_ready"
    return "local_personal_loop_verified_with_external_distribution_blockers"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=DEFAULT_APP, help=f"Canonical installed app. Default: {DEFAULT_APP}")
    parser.add_argument("--url-proof", type=Path, help="Specific packaged-app URL import proof JSON.")
    parser.add_argument("--visual-proof", type=Path, help="Specific visual GUI proof JSON.")
    parser.add_argument("--release-proof", type=Path, help="Specific release-readiness proof JSON.")
    parser.add_argument("--secret-proof", type=Path, help="Specific secret hygiene proof JSON.")
    parser.add_argument("--ui-proof", type=Path, help="Specific UI hygiene proof JSON.")
    parser.add_argument("--output-root", type=Path, default=today_output_root(), help="Directory for proof.json.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    app_path = args.app.expanduser().resolve()
    app_info = read_app_info(app_path)
    app_build = str(app_info.get("build") or "")
    url_path = args.url_proof.expanduser().resolve() if args.url_proof else latest_path("*/packaged-app-url-import-smoke-*/proof.json")
    visual_path = args.visual_proof.expanduser().resolve() if args.visual_proof else latest_path("*/current-build-visual-gui-proof-*.json")
    release_path = args.release_proof.expanduser().resolve() if args.release_proof else latest_release_readiness_proof()
    secret_path = args.secret_proof.expanduser().resolve() if args.secret_proof else latest_secret_hygiene_proof()
    ui_path = args.ui_proof.expanduser().resolve() if args.ui_proof else latest_ui_hygiene_proof()

    runtime_data = load_json(url_path) if url_path and url_path.exists() else {}
    visual_data = load_json(visual_path) if visual_path and visual_path.exists() else {}
    release_data = load_json(release_path) if release_path and release_path.exists() else {}
    secret_data = load_json(secret_path) if secret_path and secret_path.exists() else {}
    ui_data = load_json(ui_path) if ui_path and ui_path.exists() else {}

    product_requirements = build_product_requirements(runtime_data, visual_data)
    engineering_requirements = build_engineering_requirements(release_data, secret_data, ui_data)
    doc_requirements = build_doc_requirements()
    requirements = product_requirements + engineering_requirements + doc_requirements
    status = determine_goal_status(requirements, release_data)

    output_root = args.output_root.expanduser().resolve()
    output_root.mkdir(parents=True, exist_ok=True)
    proof_path = output_root / "proof.json"
    proof = {
        "generated_at": iso_now(),
        "status": status,
        "workspace": str(ROOT_DIR),
        "canonical_app": str(app_path),
        "app_info": app_info,
        "source_proofs": {
            "url_import": summarize_url_import_proof(url_path, app_build),
            "visual_gui": summarize_visual_proof(visual_path, app_build),
            "release_readiness": {
                "path": str(release_path) if release_path else "",
                "status": release_data.get("status", "missing") if release_data else "missing",
            },
            "secret_hygiene": {
                "path": str(secret_path) if secret_path else "",
                "status": secret_data.get("status", "missing") if secret_data else "missing",
                "scanned_files": secret_data.get("scanned_files", 0) if secret_data else 0,
                "findings": len(secret_data.get("findings") or []) if secret_data else 0,
            },
            "ui_hygiene": {
                "path": str(ui_path) if ui_path else "",
                "status": ui_data.get("status", "missing") if ui_data else "missing",
                "scanned_files": ui_data.get("scanned_files", 0) if ui_data else 0,
                "findings": len(ui_data.get("findings") or []) if ui_data else 0,
            },
        },
        "requirements": {
            "product": product_requirements,
            "engineering_release": engineering_requirements,
            "docs": doc_requirements,
        },
        "status_counts": status_counts(requirements),
        "external_blockers": [item for item in requirements if item.get("status") == "externally-blocked"],
        "missing": [item for item in requirements if item.get("status") == "missing"],
        "conclusion": (
            "The local personal meeting-asset loop is verified against the overview.md capability map; public "
            "distribution remains gated by explicitly tracked Apple/account/release-channel blockers."
            if status == "local_personal_loop_verified_with_external_distribution_blockers"
            else "The goal evidence is incomplete; inspect missing requirements before claiming completion."
        ),
    }
    proof_path.write_text(json.dumps(proof, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"wrote proof: {proof_path}")
    print(f"status: {status}")
    print(f"requirements: {proof['status_counts']}")
    print(f"url_import: {proof['source_proofs']['url_import']['status']} {proof['source_proofs']['url_import']['path']}")
    print(f"visual_gui: {proof['source_proofs']['visual_gui']['status']} {proof['source_proofs']['visual_gui']['path']}")
    print(f"release_readiness: {proof['source_proofs']['release_readiness']['status']} {proof['source_proofs']['release_readiness']['path']}")
    print(f"secret_hygiene: {proof['source_proofs']['secret_hygiene']['status']} {proof['source_proofs']['secret_hygiene']['path']}")
    print(f"ui_hygiene: {proof['source_proofs']['ui_hygiene']['status']} {proof['source_proofs']['ui_hygiene']['path']}")
    return 0 if status != "incomplete" else 1


if __name__ == "__main__":
    raise SystemExit(main())
