import tempfile
import unittest
from pathlib import Path

from insightkit.data.store import InsightStore
from insightkit.ipc.server import InsightRPCServer


class TestSidecarActionRegistry(unittest.TestCase):
    def test_registry_lists_product_actions_with_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            server = InsightRPCServer(store=InsightStore(db_path=Path(tmp) / "insightkit.db"))
            registry = server._sidecar_action_registry({})
            actions = {entry["name"]: entry for entry in registry["actions"]}

            self.assertEqual(registry["registry_version"], "2026-06-29")
            self.assertIn("available", registry["state_model"])
            self.assertEqual(actions["record.save"]["state"], "available")
            self.assertEqual(actions["media.transcribe_final"]["state"], "available")
            self.assertEqual(actions["runtime.transcript.replace"]["state"], "available")
            self.assertEqual(actions["smart_minutes.generate"]["state"], "available")
            self.assertEqual(actions["transcript.recover"]["state"], "available")
            self.assertEqual(actions["transcript.recover"]["reason"], "")
            self.assertNotIn("_transcript_replace", actions)
            server.shutdown()

    def test_sidecar_version_embeds_action_registry_without_replacing_capabilities(self):
        with tempfile.TemporaryDirectory() as tmp:
            server = InsightRPCServer(store=InsightStore(db_path=Path(tmp) / "insightkit.db"))
            version = server._sidecar_version({})

            self.assertIn("capabilities", version)
            self.assertIn("transcript.replace", version["capabilities"])
            self.assertIn("sidecar.action_registry", version["capabilities"])
            self.assertIn("action_registry", version)
            action_names = {entry["name"] for entry in version["action_registry"]["actions"]}
            self.assertIn("record.save", action_names)
            self.assertIn("transcript.recover", action_names)
            server.shutdown()

    def test_dispatch_exposes_stable_action_registry_method(self):
        with tempfile.TemporaryDirectory() as tmp:
            server = InsightRPCServer(store=InsightStore(db_path=Path(tmp) / "insightkit.db"))
            response = server._dispatch({
                "id": 1,
                "method": "sidecar.action_registry",
                "params": {},
            })

            self.assertEqual(response["id"], 1)
            self.assertIn("result", response)
            actions = {entry["name"] for entry in response["result"]["actions"]}
            self.assertIn("smart_minutes.generate", actions)
            server.shutdown()


if __name__ == "__main__":
    unittest.main()
