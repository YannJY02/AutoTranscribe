import unittest
import tempfile
from pathlib import Path

from scripts.workflow.gaps import BASELINE_GAPS, GapItem, current_phase, load_registry, select_targets


class TestWorkflowGapSelection(unittest.TestCase):
    def test_p1_phase_selects_only_p1(self):
        items = [
            GapItem("P0-GX", "P0", "p0", status="open"),
            GapItem("P1-GX", "P1", "p1", status="open"),
        ]
        targets = select_targets(items, "P1")
        self.assertEqual([x.gap_id for x in targets], ["P1-GX"])

    def test_in_progress_has_priority(self):
        items = [
            GapItem("P0-G1", "P0", "a", status="open"),
            GapItem("P0-G2", "P0", "b", status="in_progress"),
        ]
        targets = select_targets(items, "P0")
        self.assertEqual(targets[0].gap_id, "P0-G2")

    def test_phase_defaults_to_p1_when_no_p0(self):
        items = [
            GapItem("P0-G1", "P0", "a", status="resolved"),
            GapItem("P1-G1", "P1", "b", status="resolved"),
            GapItem("P2-G1", "P2", "c", status="open"),
        ]
        self.assertEqual(current_phase(items), "P1")

    def test_load_registry_backfills_baseline(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "gaps.json"
            path.write_text("[]", encoding="utf-8")
            items = load_registry(path)
            self.assertGreaterEqual(len(items), len(BASELINE_GAPS))


if __name__ == "__main__":
    unittest.main()
