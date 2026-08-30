import json
from pathlib import Path
from unittest import mock

from insightkit.data.store import InsightStore
from insightkit.ipc.server import InsightRPCServer
from insightkit.insights.service import InsightService


SAMPLE_PACKAGE = {
    "session_overview": {
        "title": "Boundary Test",
        "overview": "Runtime action boundary result.",
        "topics": ["boundary"],
    },
    "highlight_insights": [],
    "speaker_perspectives": [],
    "decision_ledger": [],
    "action_tracks": [],
    "timeline_beats": [],
    "provenance_links": [],
}


class FakeInsightService:
    def __init__(self, fail_provider: bool = False, fail_fallback: bool = False):
        self.fail_provider = fail_provider
        self.fail_fallback = fail_fallback
        self.final_inputs = []
        self.last_call_meta = {
            "vendor": "fake",
            "model": "test-model",
            "strict_mode": True,
        }

    def build_final(self, segments, **kwargs):
        self.final_inputs.append(list(segments))
        if self.fail_provider:
            raise RuntimeError("provider unavailable")
        return SAMPLE_PACKAGE

    def build_local_extractive(self, segments):
        if self.fail_fallback:
            raise RuntimeError("local fallback unavailable")
        self.last_call_meta = {
            "vendor": "local-extractive",
            "model": "heuristic-v1",
            "strict_mode": False,
        }
        return SAMPLE_PACKAGE


def make_server(tmp_path: Path, insight_service=None) -> InsightRPCServer:
    return InsightRPCServer(
        store=InsightStore(db_path=tmp_path / "insightkit.db"),
        insight_service=insight_service,
    )


def dispatch(server: InsightRPCServer, method: str, params: dict) -> dict:
    return server._dispatch({"id": 7, "method": method, "params": params})


def assert_error(response: dict, text: str) -> None:
    assert response["id"] == 7
    assert "error" in response
    assert text in response["error"]["message"]


def test_product_action_names_are_dispatchable_and_advertised(tmp_path):
    server = make_server(tmp_path)
    try:
        version = server._sidecar_version({})
        capabilities = set(version["capabilities"])
        for action in {
            "record.save",
            "transcript.recover",
            "media.transcribe_final",
            "runtime.transcript.replace",
            "smart_minutes.generate",
        }:
            assert action in capabilities

        response = dispatch(server, "module.run", {
            "action": "runtime.transcript.replace",
            "meeting_id": "m-1",
            "payload": {"segments": []},
        })
        assert response["result"]["meeting_id"] == "m-1"
        assert response["result"]["replaced"] == 0
        assert response["result"]["status"] == "available"
    finally:
        server.shutdown()


def test_record_save_contract_success_invalid_input_and_write_failure(tmp_path, monkeypatch):
    records_root = tmp_path / "Records"
    monkeypatch.setenv("INSIGHTKIT_RECORDS_ROOT", str(records_root))
    source = tmp_path / "sample.m4a"
    source.write_bytes(b"fake audio")
    server = make_server(tmp_path)
    try:
        response = dispatch(server, "record.save", {
            "meeting_id": "record-save-contract",
            "title": "Record Save Contract",
            "source_path": str(source),
            "segments": [{"start_ms": 0, "end_ms": 1000, "speaker": "A", "text": "saved"}],
            "media_type": "audio",
            "record_source": "imported",
            "duration_sec": 1.0,
            "presentation_status": "presenterOverlayCaptured",
        })
        record_path = Path(response["result"]["record_path"])
        assert response["result"]["ok"] is True
        assert record_path.exists()
        assert json.loads((record_path / "transcript.json").read_text())[0]["text"] == "saved"
        assert json.loads((record_path / "metadata.json").read_text())["presentationStatus"] == "presenterOverlayCaptured"

        assert_error(dispatch(server, "record.save", {}), "meeting_id is required")
    finally:
        server.shutdown()

    bad_root = tmp_path / "not-a-directory"
    bad_root.write_text("blocks mkdir")
    monkeypatch.setenv("INSIGHTKIT_RECORDS_ROOT", str(bad_root))
    server = make_server(tmp_path / "failure-db")
    try:
        assert_error(
            dispatch(server, "record.save", {
                "meeting_id": "record-save-write-failure",
                "segments": [{"start_ms": 0, "end_ms": 1000, "text": "x"}],
            }),
            "File exists",
        )
    finally:
        server.shutdown()


def test_final_media_and_transcript_recovery_contracts(tmp_path):
    media_result = {
        "duration": 3.0,
        "lang": "en",
        "segments": [
            {
                "start": 100,
                "end": 1300,
                "speaker": "SPEAKER_00",
                "text": "media transcript",
                "confidence": 0.8,
            }
        ],
    }
    server = make_server(tmp_path)
    try:
        assert_error(dispatch(server, "transcript.recover", {}), "media_path is required")

        with mock.patch("insightkit.ipc.asr_dispatcher.transcribe", return_value=media_result):
            final_media = dispatch(server, "media.transcribe_final", {
                "media_path": "/tmp/final.m4a",
                "source": "media",
            })
            recovered = dispatch(server, "transcript.recover", {
                "record_media": "/tmp/final.m4a",
                "meeting_id": "recover-contract",
                "source": "media",
            })

        assert final_media["result"]["status"] == "available"
        assert final_media["result"]["segments"][0]["text"] == "media transcript"
        assert recovered["result"]["replaced"] == 1
        assert recovered["result"]["segments"][0]["source"] == "media"
        assert server.store.list_segments("recover-contract")[0]["text"] == "media transcript"

        with mock.patch("insightkit.ipc.asr_dispatcher.transcribe", side_effect=RuntimeError("ASR unavailable")):
            assert_error(
                dispatch(server, "media.transcribe_final", {"media_path": "/tmp/final.m4a"}),
                "ASR unavailable",
            )
        with mock.patch("insightkit.ipc.asr_dispatcher.transcribe", side_effect=RuntimeError("runtime busy")):
            assert_error(
                dispatch(server, "media.transcribe_final", {"media_path": "/tmp/final.m4a"}),
                "runtime busy",
            )
        with mock.patch("insightkit.ipc.asr_dispatcher.transcribe", side_effect=RuntimeError("temporary runtime failure")):
            assert_error(
                dispatch(server, "transcript.recover", {"media_path": "/tmp/final.m4a"}),
                "temporary runtime failure",
            )
        with mock.patch("insightkit.ipc.asr_dispatcher.transcribe", return_value=media_result), \
                mock.patch.object(server.store, "replace_segments", side_effect=OSError("write failed")):
            assert_error(
                dispatch(server, "transcript.recover", {
                    "media_path": "/tmp/final.m4a",
                    "meeting_id": "recover-write-failure",
                }),
                "write failed",
            )
    finally:
        server.shutdown()


def test_runtime_transcript_replace_contract_success_unsupported_and_invalid_segments(tmp_path):
    server = make_server(tmp_path)
    try:
        response = dispatch(server, "runtime.transcript.replace", {
            "meeting_id": "replace-contract",
            "segments": [
                {
                    "start_ms": 2000,
                    "end_ms": 3200,
                    "speaker": "SPEAKER_00",
                    "source": "media",
                    "text": "official transcript",
                }
            ],
        })
        assert response["result"]["meeting_id"] == "replace-contract"
        assert response["result"]["replaced"] == 1
        assert response["result"]["status"] == "available"
        assert server.store.list_segments("replace-contract")[0]["text"] == "official transcript"

        assert_error(
            dispatch(server, "runtime.transcript.replace", {
                "meeting_id": "replace-contract",
                "segments": "not valid segments",
            }),
            "segments must be a list",
        )

        with mock.patch.object(server._session_handler, "transcript_replace", None):
            assert_error(
                dispatch(server, "runtime.transcript.replace", {
                    "meeting_id": "replace-contract",
                    "segments": [],
                }),
                "runtime transcript replacement unsupported",
            )
        assert_error(
            dispatch(server, "runtime.transcript.replace", {
                "meeting_id": "replace-contract",
                "segments": ["not a segment object"],
            }),
            "segments must be a list of objects",
        )
    finally:
        server.shutdown()


def test_smart_minutes_generate_contract_success_provider_fallback_and_empty_transcript(tmp_path):
    service = FakeInsightService()
    server = make_server(tmp_path, insight_service=service)
    try:
        server._session_handler.transcript_delta({
            "meeting_id": "minutes-contract",
            "segments": [{"start_ms": 0, "end_ms": 1000, "text": "make minutes"}],
        })
        response = dispatch(server, "smart_minutes.generate", {"meeting_id": "minutes-contract"})
        assert response["result"]["mode"] == "final"
        assert response["result"]["insight_package"]["session_overview"]["title"] == "Boundary Test"
        assert service.final_inputs[0][0]["text"] == "make minutes"
    finally:
        server.shutdown()

    fallback_server = make_server(tmp_path / "fallback", insight_service=FakeInsightService(fail_provider=True))
    try:
        response = dispatch(fallback_server, "smart_minutes.generate", {"meeting_id": "provider-down"})
        assert response["result"]["status"] == "degraded"
        assert response["result"]["provider_vendor"] == "local-extractive"
        assert response["result"]["degradation_reason"]
        assert response["result"]["insight_package"]["session_overview"]["title"] == "Boundary Test"
    finally:
        fallback_server.shutdown()

    empty_server = make_server(tmp_path / "empty", insight_service=FakeInsightService())
    try:
        response = dispatch(empty_server, "smart_minutes.generate", {"meeting_id": "empty-transcript"})
        assert response["result"]["mode"] == "final"
        assert response["result"]["transcript_state"] == "insufficient"
        assert response["result"]["insight_package"]
    finally:
        empty_server.shutdown()

    failed_server = make_server(
        tmp_path / "failed",
        insight_service=FakeInsightService(fail_provider=True, fail_fallback=True),
    )
    try:
        assert_error(
            dispatch(failed_server, "smart_minutes.generate", {"meeting_id": "retryable-failure"}),
            "retryable failure",
        )
    finally:
        failed_server.shutdown()


def test_no_network_local_smart_minutes_rpc_to_canonical_record(tmp_path, monkeypatch):
    monkeypatch.setenv("INSIGHTKIT_RECORDS_ROOT", str(tmp_path / "Records"))
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    monkeypatch.delenv("DEEPSEEK_API_KEY", raising=False)
    source = tmp_path / "synthetic.m4a"
    source.write_bytes(b"synthetic audio fixture")
    server = make_server(tmp_path, insight_service=InsightService())
    try:
        server._session_handler.transcript_delta({
            "meeting_id": "offline-e2e",
            "segments": [
                {"start_ms": 0, "end_ms": 2000, "speaker": "Speaker 1", "text": "We decided on a local launch."},
                {"start_ms": 2000, "end_ms": 4000, "speaker": "Speaker 2", "text": "Speaker 2 owns the review by Friday."},
            ],
        })
        with mock.patch("urllib.request.urlopen", side_effect=AssertionError("network disabled")), \
                mock.patch("socket.create_connection", side_effect=AssertionError("network disabled")):
            minutes = dispatch(server, "smart_minutes.generate", {
                "meeting_id": "offline-e2e",
                "provider_vendor": "local",
            })["result"]
            saved = dispatch(server, "record.save", {
                "meeting_id": "offline-e2e",
                "title": "Offline E2E",
                "source_path": str(source),
                "segments": server.store.list_segments("offline-e2e"),
                "insight_package": minutes["insight_package"],
                "analysis_meta": {"provider": minutes["provider_vendor"]},
                "media_type": "audio",
                "record_source": "imported",
                "duration_sec": 4.0,
            })["result"]

        record = Path(saved["record_path"])
        assert minutes["provider_vendor"] == "local"
        assert minutes["status"] == "available"
        assert (record / "minutes.json").exists()
        assert (record / "insight_package.json").exists()
        assert json.loads((record / "metadata.json").read_text())["analysis"]["provider"] == "local"
    finally:
        server.shutdown()


def test_module_export_forwards_explicit_analysis_choice(tmp_path):
    server = make_server(tmp_path)
    try:
        with mock.patch.object(server, "_document_export", return_value={"path": "minutes.md"}) as export:
            result = server._module_run({
                "action": "document.export",
                "meeting_id": "module-local-export",
                "payload": {
                    "format": "markdown",
                    "provider_vendor": "local",
                    "provider_model": "extractive-v1",
                    "strict_mode": False,
                },
            })

        assert result == {"path": "minutes.md"}
        export.assert_called_once_with({
            "meeting_id": "module-local-export",
            "format": "markdown",
            "output_dir": "",
            "provider_vendor": "local",
            "provider_model": "extractive-v1",
            "strict_mode": False,
        })
    finally:
        server.shutdown()
