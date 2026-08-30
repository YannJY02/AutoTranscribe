import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from insightkit.data.store import InsightStore
from insightkit.insights.provider import RuleBasedProvider
from insightkit.insights.render import write_insight_pdf
from insightkit.insights.service import InsightService, attach_transcript_provenance
from insightkit.ipc.insight_coord import InsightCoordinator


class TestInsightCoordinator(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.store = InsightStore(Path(self.tmp) / "test.db")
        self.store.init_schema()
        self.service = InsightService(provider=RuleBasedProvider(), strict_mode=False)
        self.coord = InsightCoordinator(store=self.store, insight_service=self.service)

    def test_refresh_live_empty_session(self):
        self.store.upsert_meeting("m-1", "test", "mic", status="recording")
        result = self.coord.insight_refresh_live({"meeting_id": "m-1", "window_sec": 120})
        self.assertEqual(result["meeting_id"], "m-1")
        self.assertEqual(result["mode"], "live")
        self.assertIn("insight_package", result)

    def test_build_final(self):
        self.store.upsert_meeting("m-1", "test", "mic", status="stopped")
        result = self.coord.insight_build_final({"meeting_id": "m-1"})
        self.assertEqual(result["mode"], "final")
        self.assertIn("needs_review_count", result)
        self.assertEqual(
            result["insight_package"]["provenance_links"][-1]["url"],
            "InsightKit SQLite segments: meeting_id=m-1",
        )

    def test_transcript_provenance_deduplicates_the_canonical_url(self):
        package = self.service.build_local_extractive([
            {"start_ms": 0, "end_ms": 1000, "speaker": "spk0", "text": "Keep one transcript source."}
        ])
        transcript_url = "InsightKit SQLite segments: meeting_id=m-1"
        package["provenance_links"] = [
            {"label": "文字记录", "url": transcript_url},
            {"label": "Transcript evidence", "url": transcript_url},
        ]

        enriched = attach_transcript_provenance(package, "m-1")

        self.assertEqual(enriched["provenance_links"], [{"label": "文字记录", "url": transcript_url}])

    def test_document_export_markdown(self):
        self.store.upsert_meeting("m-1", "test", "mic", status="stopped")
        source = Path(self.tmp) / "source.m4a"
        source.write_bytes(b"audio")
        self.store.insert_segment(
            "m-1",
            start_ms=0,
            end_ms=1800,
            speaker="spk0",
            text="We decided to archive the meeting record.",
            confidence=0.9,
            source="mic",
        )
        self.store.upsert_transcription_job(
            job_id="job-1",
            meeting_id="m-1",
            source_path=str(source),
            state="completed",
            progress=100,
            stage="done",
            started_at="2026-05-24T19:00:00+08:00",
            ended_at="2026-05-24T19:01:00+08:00",
        )
        out_dir = Path(self.tmp) / "export"
        result = self.coord.document_export({
            "meeting_id": "m-1",
            "format": "markdown",
            "output_dir": str(out_dir),
        })
        self.assertIn("path", result)
        out = Path(result["path"])
        self.assertTrue(out.exists())
        content = out.read_text(encoding="utf-8")
        self.assertIn("## 会议信封", content)
        self.assertIn("- 会议主题:", content)
        self.assertIn("- 会议时间:", content)
        self.assertIn("- 参会人: spk0", content)
        self.assertIn("AI 免责声明", content)
        self.assertIn("## 长文版结构化总结", content)
        self.assertIn("## 会议金句", content)
        self.assertIn("## 发言人总结", content)
        self.assertIn("## 关键决策", content)
        self.assertIn("## 待办事项", content)
        self.assertIn("## 智能章节", content)
        self.assertIn("## 相关链接", content)
        self.assertIn("原始记录", content)
        self.assertIn("文字记录", content)
        self.assertIn("媒体回放", content)
        self.assertIn("file://", content)
        self.assertNotIn("交互占位提示", content)

    def test_document_export_honors_explicit_local_analysis(self):
        self.store.upsert_meeting("m-local-export", "offline export", "file", status="stopped")
        self.store.insert_segment(
            "m-local-export", start_ms=0, end_ms=1200, speaker="Speaker 1",
            text="We decided to keep exports local.", confidence=0.9, source="file",
        )

        for export_format in ("markdown", "pdf"):
            result = self.coord.document_export({
                "meeting_id": "m-local-export",
                "format": export_format,
                "output_dir": str(Path(self.tmp) / "local-export"),
                "provider_vendor": "local",
            })

            self.assertEqual(self.service.last_call_meta["vendor"], "local")
            self.assertEqual(result["format"], export_format)
            self.assertTrue(Path(result["path"]).exists())

    def test_document_export_keeps_related_links_without_source_path(self):
        self.store.upsert_meeting("m-related", "no media source", "live", status="stopped")
        self.store.insert_segment(
            "m-related",
            start_ms=0,
            end_ms=1200,
            speaker="spk0",
            text="The record should keep archive links even when media path is unavailable.",
            confidence=0.9,
            source="mic",
        )
        out_dir = Path(self.tmp) / "export-related"
        result = self.coord.document_export({
            "meeting_id": "m-related",
            "format": "markdown",
            "output_dir": str(out_dir),
        })

        content = Path(result["path"]).read_text(encoding="utf-8")
        self.assertIn("## 相关链接", content)
        self.assertIn("- 原始记录: InsightKit 本地会话: m-related", content)
        self.assertIn("- 文字记录: InsightKit SQLite segments: meeting_id=m-related", content)
        self.assertEqual(content.count("InsightKit SQLite segments: meeting_id=m-related"), 1)
        self.assertIn("- 媒体回放: 请在 InsightKit 记录详情页打开本地记录", content)
        self.assertNotIn("当前导出未附加原始记录、文字记录或媒体回放链接", content)

    def test_document_export_pdf(self):
        self.store.upsert_meeting("m-1", "test", "mic", status="stopped")
        out_dir = Path(self.tmp) / "export"
        result = self.coord.document_export({
            "meeting_id": "m-1",
            "format": "pdf",
            "output_dir": str(out_dir),
        })
        out = Path(result["path"])
        self.assertEqual(result["format"], "pdf")
        self.assertTrue(out.exists())
        self.assertEqual(out.suffix, ".pdf")
        self.assertGreater(out.stat().st_size, 0)
        self.assertEqual(out.read_bytes()[:5], b"%PDF-")

    def test_document_export_honors_relative_output_dir(self):
        self.store.upsert_meeting("m-1", "test", "mic", status="stopped")
        cwd = Path(self.tmp) / "cwd"
        cwd.mkdir()
        original_cwd = Path.cwd()
        try:
            os.chdir(cwd)
            result = self.coord.document_export({
                "meeting_id": "m-1",
                "format": "markdown",
                "output_dir": "relative-export",
            })
        finally:
            os.chdir(original_cwd)

        out = Path(result["path"])
        self.assertTrue(out.exists())
        self.assertEqual(out.parent.resolve(), (cwd / "relative-export").resolve())

    def test_document_export_keeps_legacy_txt_output_dir_default(self):
        self.store.upsert_meeting("m-1", "test", "mic", status="stopped")
        fake_home = Path(self.tmp) / "home"
        with mock.patch("insightkit.ipc.insight_coord.Path.home", return_value=fake_home):
            result = self.coord.document_export({
                "meeting_id": "m-1",
                "format": "markdown",
                "output_dir": "txt",
            })

        out = Path(result["path"])
        self.assertTrue(out.exists())
        self.assertEqual(out.parent, fake_home / "Documents" / "InsightKit" / "exports")

    def test_builtin_pdf_fallback_when_weasyprint_missing(self):
        payload = self.service.build_local_extractive([
            {
                "start_ms": 0,
                "end_ms": 1600,
                "speaker": "spk0",
                "text": "确认导出路径在无 WeasyPrint 时仍可归档。",
            }
        ])
        out = Path(self.tmp) / "fallback.pdf"
        with mock.patch.dict("sys.modules", {"weasyprint": None}):
            write_insight_pdf(
                payload,
                title="Fallback PDF",
                output_path=out,
                meeting={"source": "imported", "started_at": "2026-05-24T21:00:00+08:00"},
                transcript=[{"speaker": "spk0"}],
                meeting_id="m-fallback",
                source_path=str(Path(self.tmp) / "source.m4a"),
            )

        self.assertTrue(out.exists())
        self.assertGreater(out.stat().st_size, 0)
        self.assertEqual(out.read_bytes()[:5], b"%PDF-")
        self.assertIn(b"/STSong-Light", out.read_bytes())


if __name__ == "__main__":
    unittest.main()
