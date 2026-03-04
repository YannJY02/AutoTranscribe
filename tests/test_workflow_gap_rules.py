import unittest

from scripts.workflow.release_loop import GAP_RULES


class TestWorkflowGapRules(unittest.TestCase):
    def test_all_expected_gap_rules_present(self):
        expected = {
            "P0-G1",
            "P0-G2",
            "P0-G3",
            "P0-G4",
            "P1-G1",
            "P1-G2",
            "P1-G3",
            "P1-G4",
            "P1-G5",
            "P1-G6",
        }
        self.assertEqual(set(GAP_RULES.keys()), expected)


if __name__ == "__main__":
    unittest.main()
