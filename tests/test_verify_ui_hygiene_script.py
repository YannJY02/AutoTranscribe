import tempfile
import unittest
from pathlib import Path

from scripts.verify_ui_hygiene import iter_scan_files, scan_paths, scan_text


class TestVerifyUIHygieneScript(unittest.TestCase):
    def test_scan_text_detects_empty_button_action(self):
        findings = scan_text('Button("导出 PDF") { }\n', "View.swift")

        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0]["rule"], "empty_button_action")

    def test_scan_text_detects_release_placeholder_copy(self):
        findings = scan_text('Text("功能开发中，敬请期待")\n', "View.swift")
        rules = {item["rule"] for item in findings}

        self.assertIn("unimplemented_text", rules)

    def test_scan_text_allows_normal_textfield_placeholder(self):
        findings = scan_text('TimestampTextView(text: $text, placeholder: "输入笔记...")\n', "TimestampNotesEditor.swift")

        self.assertEqual(findings, [])

    def test_scan_paths_fails_when_ui_source_has_release_blocker(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source_dir = root / "macos" / "InsightKitApp" / "Sources" / "InsightKitApp"
            source_dir.mkdir(parents=True)
            (source_dir / "View.swift").write_text('Button("未接通") { }\n', encoding="utf-8")

            proof = scan_paths(root, ["macos/InsightKitApp/Sources/InsightKitApp"])

        self.assertEqual(proof["status"], "failed")
        self.assertEqual(proof["findings"][0]["rule"], "empty_button_action")

    def test_iter_scan_files_excludes_tests(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source_dir = root / "macos" / "InsightKitApp" / "Sources" / "InsightKitApp"
            test_dir = root / "macos" / "InsightKitApp" / "Tests" / "InsightKitAppTests"
            source_dir.mkdir(parents=True)
            test_dir.mkdir(parents=True)
            source = source_dir / "View.swift"
            test_file = test_dir / "ViewTests.swift"
            source.write_text("Text(\"ok\")\n", encoding="utf-8")
            test_file.write_text("// TODO is fine in tests for this verifier\n", encoding="utf-8")

            files = iter_scan_files(root, ["macos/InsightKitApp"])

        self.assertEqual(files, [source.resolve()])


if __name__ == "__main__":
    unittest.main()
