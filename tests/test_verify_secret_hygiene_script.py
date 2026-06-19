import tempfile
import unittest
from pathlib import Path

from scripts.verify_secret_hygiene import iter_scan_files, scan_paths, scan_text


class TestVerifySecretHygieneScript(unittest.TestCase):
    def test_scan_text_detects_high_confidence_token(self):
        token = "sk-" + ("A" * 40)

        findings = scan_text(f"OPENAI_API_KEY={token}\n", "settings.env")

        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0]["rule"], "openai_api_key")
        self.assertNotIn(token, findings[0]["match"])

    def test_scan_text_ignores_fake_secret_literals(self):
        findings = scan_text("api_key = 'fake-secret'\nraise RuntimeError('missing API key')\n", "test.py")

        self.assertEqual(findings, [])

    def test_iter_scan_files_excludes_logs_dist_and_binary_suffixes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "scripts").mkdir()
            (root / "logs").mkdir()
            (root / "dist").mkdir()
            source = root / "scripts" / "tool.py"
            log = root / "logs" / "proof.json"
            binary = root / "scripts" / "sample.m4a"
            dist = root / "dist" / "bundle.txt"
            source.write_text("print('ok')", encoding="utf-8")
            log.write_text("{}", encoding="utf-8")
            binary.write_bytes(b"audio")
            dist.write_text("artifact", encoding="utf-8")

            files = iter_scan_files(root, ["scripts", "logs", "dist"])

        self.assertEqual(files, [source.resolve()])

    def test_scan_paths_fails_when_secret_is_in_release_relevant_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "scripts").mkdir()
            token = "ghp_" + ("A" * 36)
            (root / "scripts" / "tool.py").write_text(f"TOKEN = '{token}'\n", encoding="utf-8")

            proof = scan_paths(root, ["scripts"])

        self.assertEqual(proof["status"], "failed")
        self.assertEqual(proof["findings"][0]["rule"], "github_token")

    def test_scan_paths_passes_clean_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "scripts").mkdir()
            (root / "scripts" / "tool.py").write_text("TOKEN_ENV = 'OPENAI_API_KEY'\n", encoding="utf-8")

            proof = scan_paths(root, ["scripts"])

        self.assertEqual(proof["status"], "passed")
        self.assertEqual(proof["findings"], [])


if __name__ == "__main__":
    unittest.main()
