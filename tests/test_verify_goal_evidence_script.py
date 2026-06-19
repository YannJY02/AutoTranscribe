import unittest

from scripts.verify_goal_evidence import (
    build_engineering_requirements,
    build_product_requirements,
    determine_goal_status,
    status_counts,
)


def sample_runtime(markdown_sections=None):
    return {
        "exports": {
            "markdown_path": "/tmp/record.md",
            "pdf_path": "/tmp/record.pdf",
            "markdown_required_sections": markdown_sections
            or [
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
            ],
        },
        "job": {"state": "completed", "source_path": "/tmp/real.m4a"},
        "record_validation": {
            "timestamped_rows": 11,
            "speaker_labels": ["spk0", "spk1"],
            "note_text": "00:05 E2E note",
        },
        "fts_validation": {"result_count": 1},
    }


def sample_visual():
    return {
        "record_id": "file-123",
        "computer_use_observations": {
            "home": {"latest_recent_record": "file-123"},
            "records_search": {"visible_count_text": "all records (3)"},
            "record_detail": {
                "smart_minutes_sections_visible": [
                    "summary",
                    "meeting_quote",
                    "speaker_summary",
                    "key_decision",
                    "action_item",
                    "smart_chapter",
                ],
                "visible_ids": [
                    "record_export_markdown_button",
                    "record_export_pdf_button",
                    "record_transcript_title",
                    "record_media_seek_status",
                    "live_note_row_0",
                ],
            },
            "seek_linkage": {
                "chapter_click": {"visible_status": "jumped to 00:11"},
                "transcript_click": {"visible_status": "jumped to 00:20"},
                "note_click": {"visible_status": "jumped to 00:05"},
            },
        },
    }


def sample_release():
    return {
        "app_info": {
            "bundle_id": "com.yannjy.insightkit",
            "version": "0.1.0",
            "build": "20260526120000",
            "icon_file": "InsightKit.icns",
            "usage_descriptions": {
                "NSMicrophoneUsageDescription": "mic",
                "NSCameraUsageDescription": "camera",
                "NSScreenCaptureUsageDescription": "screen",
            },
        },
        "runtime_proof": {"status": "passed", "path": "/tmp/runtime-proof.json"},
        "visual_proof": {"status": "passed", "path": "/tmp/visual-proof.json"},
        "process_cleanup": {"exit_code": 0, "output": "No socket: /tmp/insightkit-app-501.sock"},
        "preflight": {
            "local": {"status": "local-release-ready", "failure_count": 0, "failures": []},
            "developer_id": {"status": "externally-blocked", "failures": ["Developer ID missing"]},
            "app_store": {"status": "externally-blocked", "failures": ["privacy URL missing"]},
        },
    }


def sample_secret():
    return {
        "status": "passed",
        "scanned_files": 267,
        "findings": [],
    }


def sample_ui():
    return {
        "status": "passed",
        "scanned_files": 75,
        "findings": [],
    }


class TestVerifyGoalEvidenceScript(unittest.TestCase):
    def test_product_requirements_cover_overview_capabilities(self):
        requirements = build_product_requirements(sample_runtime(), sample_visual())
        statuses = {item["id"]: item["status"] for item in requirements}

        self.assertEqual(statuses["ai.summary"], "verified")
        self.assertEqual(statuses["ai.meeting_quote"], "verified")
        self.assertEqual(statuses["export.body"], "verified")
        self.assertEqual(statuses["raw.media_linkage"], "verified")
        self.assertEqual(statuses["raw.recording_fallback"], "personal-local-degradation")

    def test_missing_export_section_marks_requirement_missing(self):
        runtime = sample_runtime(markdown_sections=["## 会议信封", "AI 免责声明"])
        requirements = build_product_requirements(runtime, sample_visual())
        export = next(item for item in requirements if item["id"] == "export.body")

        self.assertEqual(export["status"], "missing")

    def test_engineering_requirements_track_external_distribution_blockers(self):
        requirements = build_engineering_requirements(sample_release(), sample_secret(), sample_ui())
        statuses = {item["id"]: item["status"] for item in requirements}

        self.assertEqual(statuses["release.local_preflight"], "verified")
        self.assertEqual(statuses["release.secret_hygiene"], "verified")
        self.assertEqual(statuses["release.ui_hygiene"], "verified")
        self.assertEqual(statuses["release.developer_id"], "externally-blocked")
        self.assertEqual(statuses["release.app_store"], "externally-blocked")

    def test_engineering_requirements_fail_when_secret_scan_has_findings(self):
        secret = {"status": "failed", "scanned_files": 10, "findings": [{"rule": "openai_api_key"}]}
        requirements = build_engineering_requirements(sample_release(), secret, sample_ui())
        secret_status = next(item for item in requirements if item["id"] == "release.secret_hygiene")

        self.assertEqual(secret_status["status"], "missing")

    def test_engineering_requirements_fail_when_ui_scan_has_findings(self):
        ui = {"status": "failed", "scanned_files": 75, "findings": [{"rule": "empty_button_action"}]}
        requirements = build_engineering_requirements(sample_release(), sample_secret(), ui)
        ui_status = next(item for item in requirements if item["id"] == "release.ui_hygiene")

        self.assertEqual(ui_status["status"], "missing")

    def test_goal_status_accepts_local_loop_with_external_blockers(self):
        requirements = [
            {"status": "verified"},
            {"status": "personal-local-degradation"},
            {"status": "externally-blocked"},
        ]
        self.assertEqual(
            determine_goal_status(requirements, sample_release()),
            "local_personal_loop_verified_with_external_distribution_blockers",
        )
        self.assertEqual(status_counts(requirements)["externally-blocked"], 1)

    def test_goal_status_is_incomplete_when_any_requirement_is_missing(self):
        requirements = [{"status": "verified"}, {"status": "missing"}]

        self.assertEqual(determine_goal_status(requirements, sample_release()), "incomplete")


if __name__ == "__main__":
    unittest.main()
