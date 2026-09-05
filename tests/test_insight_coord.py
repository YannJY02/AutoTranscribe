import os
import re
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from insightkit.data.store import InsightStore
from insightkit.insights.provider import RuleBasedProvider
from insightkit.insights.render import render_insight_html, render_insight_markdown, write_insight_pdf
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
        payload["action_tracks"] = [
            {"task": "Review the source", "priority": "medium", "status": "open", "needs_review": True},
        ]
        payload["decision_ledger"] = [
            {"decision": "Keep the source", "needs_review": True},
        ]
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
        review_text = "复核：待复核".encode("utf-16-be").hex().upper().encode("ascii")
        self.assertEqual(out.read_bytes().count(review_text), 2)


class TestInsightReviewExports(unittest.TestCase):
    def review_payload(self):
        actions = []
        decisions = []
        for index, flag in enumerate((True, False, None)):
            action = {"task": f"Task {index}", "priority": "medium", "status": "open"}
            decision = {"problem": f"Problem {index}", "decision": f"Decision {index}"}
            if flag is not None:
                action["needs_review"] = flag
                decision["needs_review"] = flag
            actions.append(action)
            decisions.append(decision)
        return {"action_tracks": actions, "decision_ledger": decisions}

    def assert_review_items(self, decisions, actions):
        self.assertEqual(len(decisions), 3)
        self.assertEqual(len(actions), 3)
        for index, (decision, action) in enumerate(zip(decisions, actions)):
            with self.subTest(index=index):
                self.assertIn(f"Decision {index}", decision)
                self.assertIn(f"Task {index}", action)
                self.assertIn("medium", action)
                self.assertIn("open", action)
                for item in (decision, action):
                    self.assertEqual(item.count("待复核"), 1 if index == 0 else 0)
                    self.assertNotIn("已确认", item)

    def test_markdown_keeps_review_state_on_its_decision_and_action(self):
        markdown = render_insight_markdown(self.review_payload(), "Mixed review states")
        decisions = markdown.split("## 关键决策\n", 1)[1].split("## 待办事项\n", 1)[0]
        actions = markdown.split("## 待办事项\n", 1)[1].split("## 智能章节\n", 1)[0]
        self.assert_review_items(decisions.split("- 问题:")[1:], actions.split("- 任务:")[1:])

    def test_html_keeps_review_state_on_its_decision_and_action(self):
        html = render_insight_html(self.review_payload(), "Mixed review states")
        decisions = html.split("<h2>关键决策</h2>", 1)[1].split("<h2>待办事项</h2>", 1)[0]
        actions = html.split("<h2>待办事项</h2>", 1)[1].split("<h2>智能章节</h2>", 1)[0]
        items = r'<div class="item">(.*?)</div>'
        self.assert_review_items(re.findall(items, decisions, re.S), re.findall(items, actions, re.S))


class TestBuiltinPDFReviewPagination(unittest.TestCase):
    def export_pages(self, payload):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "review-boundary.pdf"
            with mock.patch.dict("sys.modules", {"weasyprint": None}):
                write_insight_pdf(payload, "Review pagination", output)
            document = output.read_bytes()
            streams = re.findall(rb"stream\n(.*?)endstream", document, re.S)
        page_width = float(re.search(rb"/MediaBox \[0 0 ([\d.]+) [\d.]+\]", document)[1])
        pages = []
        for stream in streams:
            self.assertLessEqual(stream.count(b"T*\n"), 52)
            font_size = float(re.search(rb"/F1 ([\d.]+) Tf", stream)[1])
            left_margin = float(re.search(rb"([\d.]+) [\d.]+ Td", stream)[1])
            for value in re.findall(rb"<([0-9A-F]+)> Tj", stream):
                # No CID /W or /DW is supplied, so each UTF-16 code unit advances
                # the PDF default of 1000 font units: one font-size in points.
                right_edge = left_margin + len(value) // 4 * font_size
                self.assertLessEqual(right_edge, page_width - left_margin)
            pages.append("\n".join(
                bytes.fromhex(value.decode("ascii")).decode("utf-16-be")
                for value in re.findall(rb"<([0-9A-F]+)> Tj", stream)
            ))
        return pages

    def test_long_unicode_lines_stay_inside_page_margins(self):
        for text in ("界" * 160, "🙂" * 80, "🙂" * 26):
            with self.subTest(text=text):
                pages = self.export_pages({"action_tracks": [{"task": text, "needs_review": True}]})
                self.assertEqual("\n".join(pages).count(text[0]), len(text))

    def test_reviewed_items_move_together_at_every_page_boundary(self):
        for key, field in (("action_tracks", "task"), ("decision_ledger", "decision")):
            for body in (
                "Boundary item",
                "Boundary item " + "wrapped content " * 15,
                "Boundary item\n- Content with a list\n## Content with a heading",
            ):
                for padding in range(52):
                    with self.subTest(key=key, wrapped=len(body) > 20, padding=padding):
                        payload = {
                            "session_overview": {"overview": "\n".join(["padding"] * padding)},
                            key: [{field: body, "needs_review": True}],
                        }
                        pages = self.export_pages(payload)
                        item_page = next(page for page in pages if "Boundary item" in page)
                        self.assertIn("复核：待复核", item_page)
                        self.assertEqual(
                            " ".join(item_page.split()).count("wrapped content"),
                            body.count("wrapped content"),
                        )
                        if "\n" in body:
                            self.assertIn("Content with a list", item_page)
                            self.assertIn("Content with a heading", item_page)
                        self.assertEqual(sum(page.count("复核：待复核") for page in pages), 1)

    def test_oversized_reviewed_items_keep_content_and_notice_on_each_fragment(self):
        words = [f"word{index:04d}" for index in range(800)]
        for key, field in (("action_tracks", "task"), ("decision_ledger", "decision")):
            with self.subTest(key=key):
                pages = self.export_pages({key: [{field: " ".join(words), "needs_review": True}]})
                item_pages = [page for page in pages if re.search(r"word\d{4}", page)]
                self.assertGreater(len(item_pages), 1)
                for page in item_pages:
                    self.assertIn("复核：待复核", page)
                self.assertEqual(re.findall(r"word\d{4}", "\n".join(pages)), words)
                for page in pages:
                    if "复核：待复核" in page:
                        self.assertGreater(len(page.splitlines()), 1)

    def test_false_and_absent_review_flags_do_not_add_continuation_notices(self):
        for key, field in (("action_tracks", "task"), ("decision_ledger", "decision")):
            for flag in (False, None):
                with self.subTest(key=key, flag=flag):
                    item = {field: "word " * 800, "status": "open", "priority": "medium"}
                    if flag is not None:
                        item["needs_review"] = flag
                    pages = self.export_pages({key: [item]})
                    self.assertGreater(len(pages), 1)
                    text = "\n".join(pages)
                    self.assertNotIn("待复核", text)
                    self.assertEqual(text.count("word"), 800)
                    if key == "action_tracks":
                        self.assertIn("状态: open", text)
                        self.assertIn("优先级: medium", text)


if __name__ == "__main__":
    unittest.main()
