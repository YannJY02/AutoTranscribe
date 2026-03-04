import unittest
import tempfile
from pathlib import Path

from insightkit.compliance.scan_terms import scan_paths, scan_text


class TestComplianceScanner(unittest.TestCase):
    def test_detects_banned_terms(self):
        text = "这里不应出现妙记或关键决策等词"
        hits = scan_text(text)
        self.assertIn("妙记", hits)
        self.assertIn("关键决策", hits)

    def test_passes_clean_text(self):
        text = "这是 InsightKit 的决策账本模块。"
        self.assertEqual(scan_text(text), [])

    def test_scan_paths_respects_exclude_patterns(self):
        with tempfile.TemporaryDirectory() as tmp:
            hit_file = Path(tmp) / "hit.md"
            hit_file.write_text("这里出现了妙记", encoding="utf-8")
            findings = scan_paths([hit_file], exclude_patterns=["*hit.md"])
            self.assertEqual(findings, {})


if __name__ == "__main__":
    unittest.main()
