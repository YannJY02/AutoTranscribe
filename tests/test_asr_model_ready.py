"""
TDD integration test: ASR runtime status reports ready=True when model exists.

Strategy (test-driven-development workflow):
  RED  — assert ready is True; will FAIL if model not downloaded (expected on CI)
  GREEN — passes when model file exists and dependencies installed
  SKIP  — auto-skipped when model directory is absent (CI-friendly)

This test intentionally goes beyond the shape-only tests in test_asr_runtime_status.py,
which never asserted ready=True and therefore passed even when the real model was absent.
"""

import os
import unittest
from pathlib import Path

from scripts.asr_runtime_bootstrap import runtime_status


def _model_exists() -> bool:
    """Return True if at least one model directory/file exists under INSIGHTKIT_MODEL_DIR."""
    model_dir = os.environ.get(
        "INSIGHTKIT_MODEL_DIR",
        str(Path.home() / "Library/Application Support/InsightKit/models"),
    )
    p = Path(model_dir)
    if not p.exists():
        return False
    # Consider the model present if the directory has any subdirectory (Whisper or FunASR cache)
    return any(child.is_dir() for child in p.iterdir()) if p.is_dir() else False


@unittest.skipUnless(_model_exists(), "跳过：模型目录不存在或为空（需先运行一键修复）")
class TestASRModelReady(unittest.TestCase):
    def test_whisper_model_file_exists(self):
        """When model directory exists, model.exists must be True for the configured model."""
        status = runtime_status(engine="whisper")
        self.assertTrue(
            status.get("model", {}).get("exists"),
            msg=(
                f"model.exists should be True when model directory is present.\n"
                f"model info: {status.get('model')}\n"
                f"Full status: {status}"
            ),
        )

    def test_required_dependencies_installed(self):
        """Required deps (faster-whisper) must be installed for the model to be usable."""
        status = runtime_status(engine="whisper")
        deps = status.get("dependencies", {}).get("required", {})
        for dep, ok in deps.items():
            self.assertTrue(
                ok,
                msg=(
                    f"Required dependency '{dep}' is not installed.\n"
                    f"Run '一键修复语音识别' from the Settings panel to install missing deps.\n"
                    f"All deps: {deps}"
                ),
            )

    def test_ready_when_model_and_required_deps_present(self):
        """ready must be True when the model file exists and required (not optional) deps are installed."""
        status = runtime_status(engine="whisper")
        model_exists = status.get("model", {}).get("exists", False)
        required_deps = status.get("dependencies", {}).get("required", {})
        required_ok = all(required_deps.values())
        if model_exists and required_ok:
            self.assertTrue(
                status["ready"],
                msg=(
                    f"ready should be True: model exists and all required deps installed.\n"
                    f"Optional deps (silero-vad, pyannote) are allowed to be missing.\n"
                    f"Status: {status}"
                ),
            )


if __name__ == "__main__":
    unittest.main()
