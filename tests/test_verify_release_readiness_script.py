import json
import tempfile
import unittest
from pathlib import Path

from scripts.verify_release_readiness import (
    classify_preflight,
    latest_path,
    parse_codesigning_identities,
    parse_preflight_output,
    summarize_url_import_proof,
)


class TestVerifyReleaseReadinessScript(unittest.TestCase):
    def test_parse_codesigning_identities_keeps_distribution_blockers_visible(self):
        output = """
  1) ABC "Apple Development: yann.jy@icloud.com (LMWQNG6538)"
  2) DEF "Apple Development: yann.jyal@gmail.com (3LLL255758)"
     2 valid identities found
"""

        parsed = parse_codesigning_identities(output)

        self.assertFalse(parsed["developer_id_application_present"])
        self.assertFalse(parsed["mac_app_store_distribution_present"])
        self.assertEqual(
            parsed["apple_development_identities"],
            [
                "Apple Development: yann.jy@icloud.com (LMWQNG6538)",
                "Apple Development: yann.jyal@gmail.com (3LLL255758)",
            ],
        )

    def test_classify_preflight_separates_local_ready_from_external_blockers(self):
        local = classify_preflight(
            "local",
            0,
            "\n".join(
                [
                    "PASS preflight channel: local",
                    "PASS codesign strict verification passed",
                    "WARN Developer ID Application identity is missing; direct notarized distribution is blocked",
                ]
            ),
        )
        developer_id = classify_preflight(
            "developer-id",
            1,
            "\n".join(
                [
                    "PASS preflight channel: developer-id",
                    "FAIL Developer ID Application identity is missing; direct notarized distribution is blocked",
                    "FAIL hardened runtime is not present; notarization will require Developer ID signing with --options runtime",
                ]
            ),
        )

        self.assertEqual(local["status"], "local-release-ready")
        self.assertEqual(local["warning_count"], 1)
        self.assertEqual(developer_id["status"], "externally-blocked")
        self.assertEqual(developer_id["failure_count"], 2)

    def test_parse_preflight_output_counts_status_lines_only(self):
        parsed = parse_preflight_output(
            "\n".join(
                [
                    "PASS app exists: /tmp/InsightKit.app",
                    "some tool detail",
                    "WARN hardened runtime is not present",
                    "FAIL privacy policy URL is not configured",
                ]
            )
        )

        self.assertEqual(parsed["pass_count"], 1)
        self.assertEqual(parsed["warning_count"], 1)
        self.assertEqual(parsed["failure_count"], 1)

    def test_latest_path_returns_newest_matching_diagnostic_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            older = root / "2026-05-25" / "packaged-app-url-import-smoke-old" / "proof.json"
            newer = root / "2026-05-26" / "packaged-app-url-import-smoke-new" / "proof.json"
            older.parent.mkdir(parents=True)
            newer.parent.mkdir(parents=True)
            older.write_text("{}", encoding="utf-8")
            newer.write_text("{}", encoding="utf-8")

            import scripts.verify_release_readiness as verifier

            original_root = verifier.DEFAULT_DIAGNOSTICS_ROOT
            verifier.DEFAULT_DIAGNOSTICS_ROOT = root
            try:
                self.assertEqual(latest_path("*/packaged-app-url-import-smoke-*/proof.json"), newer)
            finally:
                verifier.DEFAULT_DIAGNOSTICS_ROOT = original_root

    def test_url_import_summary_does_not_treat_missing_export_paths_as_existing(self):
        with tempfile.TemporaryDirectory() as tmp:
            proof_path = Path(tmp) / "proof.json"
            proof_path.write_text(
                json.dumps(
                    {
                        "status": "passed",
                        "app_info": {"build": "20260526120000"},
                        "sidecar_version": {"build": "20260526120000"},
                        "job": {"state": "completed"},
                        "record_validation": {
                            "insight_schema_ok": True,
                            "timestamped_rows": 1,
                            "speaker_labels": ["spk0"],
                        },
                        "fts_validation": {"result_count": 1},
                        "process_cleanup": {"clean": True},
                    }
                ),
                encoding="utf-8",
            )

            summary = summarize_url_import_proof(proof_path, "20260526120000")

        self.assertEqual(summary["status"], "incomplete")
        self.assertFalse(summary["checks"]["markdown_exists"])
        self.assertFalse(summary["checks"]["pdf_exists"])


if __name__ == "__main__":
    unittest.main()
