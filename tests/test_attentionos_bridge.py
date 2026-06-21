import tempfile
import unittest
from pathlib import Path

from insightkit.integration.attentionos_bridge import export_module


class TestAttentionOSBridge(unittest.TestCase):
    def test_export_module_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = export_module(Path(tmp) / "module")
            self.assertTrue((out / "manifest.json").exists())
            self.assertTrue((out / "index.py").exists())
            self.assertTrue((out / "README.md").exists())
            self.assertTrue((out / "state.txt").exists())

    def test_export_module_readme_contains_contract_markers(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = export_module(Path(tmp) / "module")
            readme = (out / "README.md").read_text(encoding="utf-8")
            for marker in [
                "External Host Contract",
                "Host Call",
                "Bridge Action",
                "Bridge Payload",
                "Module State",
                "meeting-asset",
            ]:
                self.assertIn(marker, readme)


if __name__ == "__main__":
    unittest.main()
