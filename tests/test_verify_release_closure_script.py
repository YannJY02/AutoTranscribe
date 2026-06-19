import unittest

from scripts.verify_release_closure import (
    determine_closure_status,
    parse_proof_path,
    parse_status_line,
    process_check_clean,
)


def child(status: str, exit_code: int | None = 0, timed_out: bool = False, proof_exists: bool = True):
    return {
        "exit_code": exit_code,
        "timed_out": timed_out,
        "proof_exists": proof_exists,
        "proof_status": status,
    }


def clean_process():
    return {
        "exit_code": 0,
        "timed_out": False,
        "output": "\n".join(
            [
                "==> InsightKitApp processes",
                "==> InsightKit sidecar processes",
                "==> Sidecar socket",
                "No socket: /tmp/insightkit-app-501.sock",
            ]
        ),
    }


class TestVerifyReleaseClosureScript(unittest.TestCase):
    def test_parse_proof_path_uses_last_proof_line(self):
        output = "\n".join(
            [
                "wrote proof: /tmp/old/proof.json",
                "status: passed",
                "wrote proof: /tmp/new/proof.json",
            ]
        )

        self.assertEqual(str(parse_proof_path(output)), "/tmp/new/proof.json")

    def test_parse_status_line_uses_last_status(self):
        output = "\n".join(["status: failed", "details", "status: passed_with_external_blockers"])

        self.assertEqual(parse_status_line(output), "passed_with_external_blockers")

    def test_closure_status_accepts_local_loop_with_external_blockers(self):
        children = {
            "secret_hygiene": child("passed"),
            "ui_hygiene": child("passed"),
            "release_readiness": child("passed_with_external_blockers"),
            "goal_evidence": child("local_personal_loop_verified_with_external_distribution_blockers"),
            "process_check": clean_process(),
        }

        self.assertEqual(determine_closure_status(children), "passed_local_with_external_blockers")

    def test_closure_status_accepts_distribution_ready(self):
        children = {
            "secret_hygiene": child("passed"),
            "ui_hygiene": child("passed"),
            "release_readiness": child("passed_distribution_ready"),
            "goal_evidence": child("release_ready"),
            "process_check": clean_process(),
        }

        self.assertEqual(determine_closure_status(children), "passed_distribution_ready")

    def test_closure_status_fails_on_timeout_or_child_failure(self):
        children = {
            "secret_hygiene": child("passed"),
            "ui_hygiene": child("passed", exit_code=None, timed_out=True, proof_exists=False),
            "release_readiness": child("passed_with_external_blockers"),
            "goal_evidence": child("local_personal_loop_verified_with_external_distribution_blockers"),
            "process_check": clean_process(),
        }

        self.assertEqual(determine_closure_status(children), "failed")

    def test_process_check_rejects_residual_app_process(self):
        residual = {
            "exit_code": 0,
            "timed_out": False,
            "output": "\n".join(
                [
                    "==> InsightKitApp processes",
                    "123 1 /Applications/InsightKit.app/Contents/MacOS/InsightKitApp",
                    "==> InsightKit sidecar processes",
                    "==> Sidecar socket",
                    "No socket: /tmp/insightkit-app-501.sock",
                ]
            ),
        }

        self.assertFalse(process_check_clean(residual))


if __name__ == "__main__":
    unittest.main()
