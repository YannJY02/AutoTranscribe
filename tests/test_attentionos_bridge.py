import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
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
                "smart_minutes.generate",
                "Compatibility Bridge Aliases",
            ]:
                self.assertIn(marker, readme)

    def test_exported_entry_maps_legacy_bridge_actions_to_product_actions(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = export_module(Path(tmp) / "module")
            index = (out / "index.py").read_text(encoding="utf-8")

            self.assertIn('payload.get("action", "smart_minutes.generate")', index)
            self.assertIn('"insight.build_final": "smart_minutes.generate"', index)
            self.assertIn('rpc_call("smart_minutes.generate"', index)
            self.assertNotIn('rpc_call("insight.build_final"', index)
            self.assertIn('+ "\\n").encode("utf-8")', index)

    def test_exported_entry_forwards_legacy_host_call_to_product_action(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            out = export_module(tmp_path / "module")
            socket_path = tmp_path / "fake-sidecar.sock"
            ready = threading.Event()
            received: dict[str, object] = {}

            def serve_once() -> None:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                    server.bind(str(socket_path))
                    server.listen(1)
                    ready.set()
                    conn, _ = server.accept()
                    with conn:
                        request = json.loads(conn.makefile("rb").readline().decode("utf-8"))
                        received["method"] = request["method"]
                        response = {
                            "id": request["id"],
                            "result": {"forwarded_method": request["method"]},
                        }
                        conn.sendall(json.dumps(response).encode("utf-8"))

            thread = threading.Thread(target=serve_once, daemon=True)
            thread.start()
            self.assertTrue(ready.wait(timeout=2))

            env = dict(os.environ)
            env["INSIGHTKIT_SOCKET"] = str(socket_path)
            proc = subprocess.run(
                [sys.executable, str(out / "index.py")],
                input=json.dumps({
                    "action": "insight.build_final",
                    "meeting_id": "bridge-meeting",
                    "payload": {},
                }),
                text=True,
                capture_output=True,
                env=env,
                timeout=5,
                check=False,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            output = json.loads(proc.stdout)
            self.assertTrue(output["ok"])
            self.assertEqual(received["method"], "smart_minutes.generate")
            self.assertEqual(output["result"]["forwarded_method"], "smart_minutes.generate")
            self.assertIn("insight.build_final -> smart_minutes.generate", output["summary"])

    def test_exported_entry_forwards_explicit_analysis_choice(self):
        with tempfile.TemporaryDirectory() as tmp:
            index = (export_module(Path(tmp) / "module") / "index.py").read_text(encoding="utf-8")

            for action in (
                "insight.refresh_live",
                "smart_minutes.generate",
                "document.export",
                "transcription.import_file",
            ):
                start = index.index(f'elif action == "{action}"')
                end = index.find('    elif action == "', start + 1)
                block = index[start:end if end >= 0 else None]
                self.assertIn('"provider_vendor": ext_payload.get("provider_vendor", "")', block)
                self.assertIn('"provider_model": ext_payload.get("provider_model", "")', block)
                self.assertIn('"strict_mode": ext_payload.get("strict_mode")', block)


if __name__ == "__main__":
    unittest.main()
