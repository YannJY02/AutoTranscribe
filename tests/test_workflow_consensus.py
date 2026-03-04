import unittest

from scripts.workflow.consensus import run_two_round_consensus


class TestWorkflowConsensus(unittest.TestCase):
    def test_consensus_approved_when_no_blockers(self):
        gates = {
            "swift_test": {"ok": True},
            "python_test": {"ok": True},
            "package_smoke": {"ok": True},
            "runtime_smoke": {"ok": True},
            "compliance_scan": {"ok": True, "finding_count": 0},
            "fallback_review_items": 0,
        }
        target_results = [{"gap_id": "P0-G1", "severity": "P0", "status": "resolved", "notes": ""}]
        unresolved = {"P0": 0, "P1": 2, "P2": 0}

        findings, consensus = run_two_round_consensus(
            round_id=1,
            gates=gates,
            target_results=target_results,
            unresolved_after=unresolved,
        )

        self.assertTrue(isinstance(findings, list))
        self.assertFalse(consensus["blocking_in_round_2"])
        self.assertEqual(consensus["decision"], "approved")

    def test_consensus_blocked_when_compliance_fails(self):
        gates = {
            "swift_test": {"ok": True},
            "python_test": {"ok": True},
            "package_smoke": {"ok": True},
            "runtime_smoke": {"ok": True},
            "compliance_scan": {"ok": False, "finding_count": 2},
            "fallback_review_items": 1,
        }
        target_results = [{"gap_id": "P1-G3", "severity": "P1", "status": "resolved", "notes": ""}]
        unresolved = {"P0": 0, "P1": 1, "P2": 0}

        findings, consensus = run_two_round_consensus(
            round_id=2,
            gates=gates,
            target_results=target_results,
            unresolved_after=unresolved,
        )

        self.assertGreaterEqual(len(findings), 2)
        self.assertTrue(consensus["blocking_in_round_2"])
        self.assertEqual(consensus["decision"], "blocked")


if __name__ == "__main__":
    unittest.main()
