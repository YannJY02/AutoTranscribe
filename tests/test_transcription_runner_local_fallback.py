from __future__ import annotations

import json
from pathlib import Path
from unittest import mock

from insightkit.data.store import InsightStore
from insightkit.insights.service import InsightService
from insightkit.ipc.insight_coord import InsightCoordinator
from scripts.transcription_runner import run_transcription_job


class BrokenProvider:
    def complete(self, system_prompt: str, user_prompt: str, model: str) -> str:
        raise RuntimeError("missing API key in TEST_PROVIDER")


def test_runner_persists_record_and_local_insights_when_provider_missing(tmp_path, monkeypatch):
    media = tmp_path / "sample.wav"
    media.write_bytes(b"fake media")
    records_root = tmp_path / "Records"
    monkeypatch.setenv("INSIGHTKIT_RECORDS_ROOT", str(records_root))

    store = InsightStore(tmp_path / "insightkit.db")
    store.init_schema()
    service = InsightService(provider=BrokenProvider(), model="broken")

    segments = [
        {
            "start": 0,
            "end": 1900,
            "speaker": "Speaker A",
            "text": "Today we confirm the product milestone.",
            "confidence": 0.9,
        },
        {
            "start": 2000,
            "end": 5200,
            "speaker": "Speaker B",
            "text": "The decision is to ship the local meeting record first.",
            "confidence": 0.9,
        },
        {
            "start": 5600,
            "end": 7600,
            "speaker": "Speaker A",
            "text": "Yann owns the export check by Friday.",
            "confidence": 0.9,
        },
    ]

    with mock.patch("scripts.transcription_runner.transcribe", return_value={"segments": segments}):
        result = run_transcription_job(
            file_path=str(media),
            meeting_id="fallback-meeting",
            store=store,
            insight_service=service,
        )

    record_path = Path(result["record_path"])
    assert record_path.exists()
    assert (record_path / "recording.wav").exists()
    assert "product milestone" in (record_path / "transcript.json").read_text()
    assert "ship the local meeting record" in (record_path / "minutes.json").read_text()
    metadata = json.loads((record_path / "metadata.json").read_text())
    assert metadata["analysis"]["provider"] == "local-extractive"
    assert metadata["analysis"]["model"] == "heuristic-v1"
    assert metadata["analysis"]["source"] == "final"

    stored = store.get_insight_package("fallback-meeting")
    assert stored is not None
    assert stored["payload"]["session_overview"]["title"] == "本地转写会话"

    export_dir = tmp_path / "exports"
    coordinator = InsightCoordinator(store=store, insight_service=service)
    export = coordinator.document_export(
        {
            "meeting_id": "fallback-meeting",
            "format": "markdown",
            "output_dir": str(export_dir),
        }
    )
    exported = Path(export["path"])
    assert exported.exists()
    exported_text = exported.read_text(encoding="utf-8")
    assert "## 关键决策" in exported_text
    assert "## 相关链接" in exported_text
    assert "交互占位提示" not in exported_text

    store.close()
