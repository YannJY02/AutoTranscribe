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


if __name__ == "__main__":
    unittest.main()
