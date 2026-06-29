import json
from pathlib import Path
from unittest import mock

from insightkit.data.store import InsightStore
from insightkit.ipc.server import COMPATIBILITY_ROUTES, InsightRPCServer


SAMPLE_PACKAGE = {
    "session_overview": {
        "title": "Compatibility Test",
        "overview": "Compatibility shim result.",
        "topics": ["compatibility"],
    },
    "highlight_insights": [],
    "speaker_perspectives": [],
    "decision_ledger": [],
    "action_tracks": [],
    "timeline_beats": [],
    "provenance_links": [],
}


class FakeInsightService:
    last_call_meta = {
        "vendor": "fake",
        "model": "test-model",
        "strict_mode": True,
    }

    def build_final(self, segments, **kwargs):
        self.last_call_meta = {
            "vendor": "fake",
            "model": "test-model",
            "strict_mode": True,
        }
        return SAMPLE_PACKAGE

    def build_local_extractive(self, segments):
        self.last_call_meta = {
            "vendor": "local-extractive",
            "model": "heuristic-v1",
            "strict_mode": False,
        }
        return SAMPLE_PACKAGE


def make_server(tmp_path: Path) -> InsightRPCServer:
    return InsightRPCServer(
        store=InsightStore(db_path=tmp_path / "insightkit.db"),
        insight_service=FakeInsightService(),
    )


def dispatch(server: InsightRPCServer, method: str, params: dict) -> dict:
    response = server._dispatch({"id": 41, "method": method, "params": params})
    assert "error" not in response, response
    return response["result"]


def test_compatibility_routes_are_quarantined_in_version_and_endpoint(tmp_path):
    server = make_server(tmp_path)
    try:
        version = server._sidecar_version({})
        routes = version["compatibility_routes"]["routes"]
        route_map = {route["legacy_method"]: route for route in routes}
        expected = {route["legacy_method"]: route["replacement"] for route in COMPATIBILITY_ROUTES}

        assert version["compatibility_routes"]["policy"]
        assert "sidecar.compatibility_routes" in version["capabilities"]
        assert {name: route["replacement"] for name, route in route_map.items()} == expected
        assert {route["state"] for route in routes} == {"compatibility_shim"}

        registry_names = {entry["name"] for entry in version["action_registry"]["actions"]}
        assert registry_names.isdisjoint(route_map)

        endpoint = dispatch(server, "sidecar.compatibility_routes", {})
        assert endpoint["routes"] == routes
    finally:
        server.shutdown()


def test_legacy_methods_remain_dispatchable_while_product_actions_are_primary(tmp_path, monkeypatch):
    records_root = tmp_path / "Records"
    monkeypatch.setenv("INSIGHTKIT_RECORDS_ROOT", str(records_root))
    media = tmp_path / "sample.m4a"
    media.write_bytes(b"fake media")

    server = make_server(tmp_path)
    try:
        legacy_record = dispatch(server, "records.save", {
            "meeting_id": "legacy-record",
            "source_path": str(media),
            "segments": [{"start_ms": 0, "end_ms": 1000, "text": "legacy"}],
        })
        product_record = dispatch(server, "record.save", {
            "meeting_id": "product-record",
            "source_path": str(media),
            "segments": [{"start_ms": 0, "end_ms": 1000, "text": "product"}],
        })
        assert Path(legacy_record["record_path"]).exists()
        assert Path(product_record["record_path"]).exists()
        assert json.loads((Path(product_record["record_path"]) / "transcript.json").read_text())[0]["text"] == "product"

        media_result = {
            "duration": 1.0,
            "lang": "en",
            "segments": [{"start": 0, "end": 1000, "text": "media text", "speaker": "A"}],
        }
        with mock.patch("insightkit.ipc.asr_dispatcher.transcribe", return_value=media_result):
            legacy_media = dispatch(server, "asr.transcribe_media", {"media_path": str(media)})
            product_media = dispatch(server, "media.transcribe_final", {"media_path": str(media)})
        assert legacy_media["segments"][0]["text"] == product_media["segments"][0]["text"]

        legacy_replace = dispatch(server, "transcript.replace", {
            "meeting_id": "replace-compat",
            "segments": [{"start_ms": 0, "end_ms": 1000, "text": "legacy replace"}],
        })
        product_replace = dispatch(server, "runtime.transcript.replace", {
            "meeting_id": "replace-compat",
            "segments": [{"start_ms": 1000, "end_ms": 2000, "text": "product replace"}],
        })
        assert legacy_replace["replaced"] == 1
        assert product_replace["replaced"] == 1
        assert server.store.list_segments("replace-compat")[0]["text"] == "product replace"

        server._session_handler.transcript_delta({
            "meeting_id": "minutes-compat",
            "segments": [{"start_ms": 0, "end_ms": 1000, "text": "make minutes"}],
        })
        legacy_minutes = dispatch(server, "insight.build_final", {"meeting_id": "minutes-compat"})
        product_minutes = dispatch(server, "smart_minutes.generate", {"meeting_id": "minutes-compat"})
        assert legacy_minutes["insight_package"]["session_overview"]["title"] == "Compatibility Test"
        assert product_minutes["insight_package"]["session_overview"]["title"] == "Compatibility Test"
    finally:
        server.shutdown()
