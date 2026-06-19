"""End-to-end integration tests for the record persistence pipeline."""

from __future__ import annotations

import json
import pytest

from insightkit.records.record_writer import RecordWriter, detect_duration, detect_media_type


SAMPLE_SEGMENTS = [
    {"start_ms": 0, "end_ms": 3000, "speaker": "A", "text": "Hello world."},
    {"start_ms": 3000, "end_ms": 8500, "speaker": "B", "text": "This is a test."},
]

SAMPLE_INSIGHT = {
    "session_overview": {
        "title": "E2E Test Session",
        "overview": "An end-to-end test session for record persistence.",
        "topics": ["testing", "e2e"],
    },
    "highlight_insights": [
        {"quote": "Hello world.", "reason": "test", "speaker": "A",
         "evidence_span": {"start_ms": 0, "end_ms": 3000}},
    ],
    "decision_ledger": [
        {"problem": "test problem", "options": [], "decision": "test decision",
         "rationale": "test", "owner": "", "needs_review": False,
         "evidence_span": {"start_ms": 0, "end_ms": 0}},
    ],
    "action_tracks": [
        {"task": "test task", "owner": "A", "due_at": "", "priority": "medium",
         "status": "open", "needs_review": False,
         "evidence_span": {"start_ms": 0, "end_ms": 0}},
    ],
    "timeline_beats": [
        {"timestamp": "00:00", "title": "Greeting", "summary": "Hello world."},
    ],
    "provenance_links": [],
    "speaker_perspectives": [],
}


class TestRecordE2E:
    """End-to-end tests verifying the full record persistence pipeline."""

    def test_full_pipeline_creates_valid_record_folder(self, tmp_path):
        """Simulate a complete transcription job and verify record folder structure."""
        # Create a fake source audio file
        source_file = tmp_path / "test_audio.m4a"
        source_file.write_bytes(b"fake audio data")

        records_root = tmp_path / "Records"
        meeting_id = "e2e-test-001"

        writer = RecordWriter()
        record_path = writer.write_record(
            root_dir=records_root,
            meeting_id=meeting_id,
            title="E2E Test",
            source_path=str(source_file),
            segments=SAMPLE_SEGMENTS,
            insight_package=SAMPLE_INSIGHT,
            media_type="audio",
            record_source="imported",
            duration_sec=detect_duration(segs=SAMPLE_SEGMENTS),
        )

        # Verify folder structure
        assert record_path.exists()
        assert (record_path / "metadata.json").exists()
        assert (record_path / "transcript.json").exists()
        assert (record_path / "minutes.json").exists()
        assert (record_path / "notes.md").exists()
        assert (record_path / "recording.m4a").exists()

    def test_metadata_json_swift_compatible(self, tmp_path):
        """Verify metadata.json is compatible with Swift JSONDecoder .iso8601 strategy."""
        source_file = tmp_path / "audio.wav"
        source_file.write_bytes(b"fake")

        writer = RecordWriter()
        record_path = writer.write_record(
            root_dir=tmp_path / "Records",
            meeting_id="e2e-test-002",
            title="Swift Compat Test",
            source_path=str(source_file),
            segments=SAMPLE_SEGMENTS,
            insight_package=SAMPLE_INSIGHT,
            media_type="audio",
            record_source="imported",
            duration_sec=8.5,
        )

        metadata = json.loads((record_path / "metadata.json").read_text())

        # CRITICAL: createdAt must end with Z, not +00:00
        assert metadata["createdAt"].endswith("Z"), \
            f"createdAt must end with Z for Swift .iso8601 compatibility, got: {metadata['createdAt']}"
        assert "+" not in metadata["createdAt"], \
            "createdAt must not contain +00:00 offset"

        # Required fields for Swift RecordMetadata
        required_fields = ["id", "createdAt", "duration", "mediaType", "source",
                           "userTags", "autoTags", "summaryPreview"]
        for field in required_fields:
            assert field in metadata, f"Missing required field: {field}"

        assert metadata["id"] == "e2e-test-002"
        assert metadata["mediaType"] == "audio"
        assert metadata["source"] == "imported"
        assert isinstance(metadata["userTags"], list)
        assert isinstance(metadata["autoTags"], list)
        assert "testing" in metadata["autoTags"]

    def test_transcript_json_format_matches_frontend(self, tmp_path):
        """Verify transcript.json format matches Swift RecordReviewDataSource expectations."""
        source_file = tmp_path / "audio.mp3"
        source_file.write_bytes(b"fake")

        writer = RecordWriter()
        record_path = writer.write_record(
            root_dir=tmp_path / "Records",
            meeting_id="e2e-test-003",
            title="Transcript Test",
            source_path=str(source_file),
            segments=SAMPLE_SEGMENTS,
            insight_package=SAMPLE_INSIGHT,
            media_type="audio",
            record_source="imported",
            duration_sec=8.5,
        )

        transcript = json.loads((record_path / "transcript.json").read_text())
        assert isinstance(transcript, list)
        assert len(transcript) == len(SAMPLE_SEGMENTS)

        for entry in transcript:
            assert "start_ms" in entry
            assert "end_ms" in entry
            assert "speaker" in entry
            assert "text" in entry
            assert isinstance(entry["start_ms"], int)
            assert isinstance(entry["end_ms"], int)

    def test_minutes_json_format_matches_frontend(self, tmp_path):
        """Verify minutes.json format matches Swift RecordReviewDataSource expectations."""
        source_file = tmp_path / "audio.mp3"
        source_file.write_bytes(b"fake")

        writer = RecordWriter()
        record_path = writer.write_record(
            root_dir=tmp_path / "Records",
            meeting_id="e2e-test-004",
            title="Minutes Test",
            source_path=str(source_file),
            segments=SAMPLE_SEGMENTS,
            insight_package=SAMPLE_INSIGHT,
            media_type="audio",
            record_source="imported",
            duration_sec=8.5,
        )

        minutes = json.loads((record_path / "minutes.json").read_text())
        assert "structured_summary" in minutes
        assert "highlights" in minutes
        assert "key_decisions" in minutes
        assert "action_items" in minutes
        assert isinstance(minutes["highlights"], list)
        assert isinstance(minutes["key_decisions"], list)
        assert isinstance(minutes["action_items"], list)
        assert "Hello world." in minutes["highlights"]
        assert "test decision" in minutes["key_decisions"]
        assert "test task" in minutes["action_items"]
        assert minutes["timeline_beats"][0]["timestamp"] == "00:00"

    def test_records_save_rpc_registered(self):
        """Verify records.save RPC handler is registered in the server."""
        from insightkit.ipc.server import InsightRPCServer
        assert hasattr(InsightRPCServer, "_records_save"), \
            "records.save RPC handler must be registered on InsightRPCServer"

    def test_duration_detection_from_segments(self):
        """Verify duration is correctly derived from segment end_ms."""
        duration = detect_duration(segs=SAMPLE_SEGMENTS)
        assert duration == pytest.approx(8.5)  # max end_ms = 8500ms = 8.5s

    def test_media_type_detection(self):
        """Verify media type detection for common extensions."""
        assert detect_media_type("recording.mp4") == "video"
        assert detect_media_type("recording.mov") == "video"
        assert detect_media_type("recording.m4a") == "audio"
        assert detect_media_type("recording.wav") == "audio"
        assert detect_media_type("recording.mp3") == "audio"

    def test_notes_md_written_and_readable(self, tmp_path):
        """Verify notes.md is written and can be read back."""
        source_file = tmp_path / "audio.m4a"
        source_file.write_bytes(b"fake")

        writer = RecordWriter()
        record_path = writer.write_record(
            root_dir=tmp_path / "Records",
            meeting_id="e2e-test-005",
            title="Notes Test",
            source_path=str(source_file),
            segments=SAMPLE_SEGMENTS,
            insight_package=SAMPLE_INSIGHT,
            media_type="audio",
            record_source="imported",
            duration_sec=8.5,
            notes_md="00:01 First note\n00:30 Second note",
        )

        notes_content = (record_path / "notes.md").read_text()
        assert "First note" in notes_content
        assert "Second note" in notes_content

    def test_insight_package_none_graceful(self, tmp_path):
        """Verify graceful handling when insight_package is None."""
        source_file = tmp_path / "audio.m4a"
        source_file.write_bytes(b"fake")

        writer = RecordWriter()
        record_path = writer.write_record(
            root_dir=tmp_path / "Records",
            meeting_id="e2e-test-006",
            title="No Insight Test",
            source_path=str(source_file),
            segments=SAMPLE_SEGMENTS,
            insight_package=None,
            media_type="audio",
            record_source="imported",
            duration_sec=8.5,
        )

        metadata = json.loads((record_path / "metadata.json").read_text())
        assert metadata["autoTags"] == []
        assert metadata["summaryPreview"] == ""

        minutes = json.loads((record_path / "minutes.json").read_text())
        assert minutes == {}
