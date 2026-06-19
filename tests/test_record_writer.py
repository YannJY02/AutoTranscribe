"""Tests for RecordWriter — record folder persistence."""

from __future__ import annotations

import json
import os
from pathlib import Path
from unittest.mock import patch

import pytest

from insightkit.records.record_writer import RecordWriter, detect_media_type, detect_duration


SAMPLE_SEGMENTS = [
    {"start_ms": 0, "end_ms": 3000, "speaker": "A", "text": "Hello world."},
    {"start_ms": 3000, "end_ms": 6000, "speaker": "B", "text": "How are you?"},
]

SAMPLE_INSIGHT = {
    "session_overview": {
        "title": "Test Session",
        "overview": "A test session overview.",
        "topics": ["topic1", "topic2"],
    },
    "highlight_insights": [
        {"quote": "Hello world.", "reason": "test", "speaker": "A", "evidence_span": {"start_ms": 0, "end_ms": 3000}},
    ],
    "decision_ledger": [
        {"problem": "p", "options": [], "decision": "d1", "rationale": "r", "owner": "", "needs_review": False, "evidence_span": {"start_ms": 0, "end_ms": 0}},
    ],
    "action_tracks": [
        {"task": "task1", "owner": "A", "due_at": "", "priority": "medium", "status": "open", "needs_review": False, "evidence_span": {"start_ms": 0, "end_ms": 0}},
    ],
    "timeline_beats": [
        {"timestamp": "00:00", "title": "Opening", "summary": "Hello world."},
    ],
    "provenance_links": [],
    "speaker_perspectives": [],
}


@pytest.fixture
def tmp_root(tmp_path):
    return tmp_path / "Records"


@pytest.fixture
def sample_audio(tmp_path):
    f = tmp_path / "sample.m4a"
    f.write_bytes(b"fake audio data")
    return f


class TestRecordWriter:
    def test_write_record_creates_folder_structure(self, tmp_root, sample_audio):
        writer = RecordWriter()
        record_path = writer.write_record(
            root_dir=tmp_root,
            meeting_id="test-meeting-001",
            title="Test Meeting",
            source_path=str(sample_audio),
            segments=SAMPLE_SEGMENTS,
            insight_package=SAMPLE_INSIGHT,
            media_type="audio",
            record_source="imported",
            duration_sec=6.0,
        )
        assert record_path.exists()
        assert (record_path / "metadata.json").exists()
        assert (record_path / "transcript.json").exists()
        assert (record_path / "minutes.json").exists()
        assert (record_path / "notes.md").exists()

    def test_metadata_created_at_uses_z_suffix(self, tmp_root, sample_audio):
        writer = RecordWriter()
        record_path = writer.write_record(
            root_dir=tmp_root,
            meeting_id="test-meeting-002",
            title="Test",
            source_path=str(sample_audio),
            segments=SAMPLE_SEGMENTS,
            insight_package=SAMPLE_INSIGHT,
            media_type="audio",
            record_source="imported",
            duration_sec=6.0,
        )
        metadata = json.loads((record_path / "metadata.json").read_text())
        assert metadata["createdAt"].endswith("Z"), f"Expected Z suffix, got: {metadata['createdAt']}"
        assert "+" not in metadata["createdAt"], "Must not contain +00:00"

    def test_metadata_fields_match_swift_record_metadata(self, tmp_root, sample_audio):
        writer = RecordWriter()
        record_path = writer.write_record(
            root_dir=tmp_root,
            meeting_id="test-meeting-003",
            title="Test",
            source_path=str(sample_audio),
            segments=SAMPLE_SEGMENTS,
            insight_package=SAMPLE_INSIGHT,
            media_type="audio",
            record_source="imported",
            duration_sec=6.0,
        )
        metadata = json.loads((record_path / "metadata.json").read_text())
        assert metadata["id"] == "test-meeting-003"
        assert metadata["mediaType"] == "audio"
        assert metadata["source"] == "imported"
        assert isinstance(metadata["userTags"], list)
        assert isinstance(metadata["autoTags"], list)
        assert "topic1" in metadata["autoTags"]
        assert "A test session overview." in metadata["summaryPreview"]
        assert metadata["duration"] == 6.0

    def test_metadata_includes_analysis_source_without_secrets(self, tmp_root, sample_audio):
        writer = RecordWriter()
        record_path = writer.write_record(
            root_dir=tmp_root,
            meeting_id="test-meeting-analysis-meta",
            title="Test",
            source_path=str(sample_audio),
            segments=SAMPLE_SEGMENTS,
            insight_package=SAMPLE_INSIGHT,
            media_type="audio",
            record_source="imported",
            duration_sec=6.0,
            analysis_meta={
                "provider": "deepseek",
                "model": "deepseek-v4-flash",
                "source": "final",
                "strict_mode": True,
                "api_key": "must-not-be-written",
            },
        )

        metadata = json.loads((record_path / "metadata.json").read_text())

        assert metadata["analysis"] == {
            "provider": "deepseek",
            "model": "deepseek-v4-flash",
            "source": "final",
            "strictMode": True,
        }
        assert "must-not-be-written" not in json.dumps(metadata)

    def test_transcript_json_format(self, tmp_root, sample_audio):
        writer = RecordWriter()
        record_path = writer.write_record(
            root_dir=tmp_root,
            meeting_id="test-meeting-004",
            title="Test",
            source_path=str(sample_audio),
            segments=SAMPLE_SEGMENTS,
            insight_package=SAMPLE_INSIGHT,
            media_type="audio",
            record_source="imported",
            duration_sec=6.0,
        )
        transcript = json.loads((record_path / "transcript.json").read_text())
        assert isinstance(transcript, list)
        assert len(transcript) == 2
        assert transcript[0]["start_ms"] == 0
        assert transcript[0]["end_ms"] == 3000
        assert transcript[0]["speaker"] == "A"
        assert transcript[0]["text"] == "Hello world."

    def test_minutes_json_extracted_from_insight_package(self, tmp_root, sample_audio):
        writer = RecordWriter()
        record_path = writer.write_record(
            root_dir=tmp_root,
            meeting_id="test-meeting-005",
            title="Test",
            source_path=str(sample_audio),
            segments=SAMPLE_SEGMENTS,
            insight_package=SAMPLE_INSIGHT,
            media_type="audio",
            record_source="imported",
            duration_sec=6.0,
        )
        minutes = json.loads((record_path / "minutes.json").read_text())
        assert minutes["structured_summary"] == "A test session overview."
        assert "Hello world." in minutes["highlights"]
        assert "d1" in minutes["key_decisions"]
        assert "task1" in minutes["action_items"]
        assert minutes["timeline_beats"][0]["title"] == "Opening"

    def test_full_insight_package_json_written(self, tmp_root, sample_audio):
        writer = RecordWriter()
        record_path = writer.write_record(
            root_dir=tmp_root,
            meeting_id="test-meeting-005b",
            title="Test",
            source_path=str(sample_audio),
            segments=SAMPLE_SEGMENTS,
            insight_package=SAMPLE_INSIGHT,
            media_type="audio",
            record_source="imported",
            duration_sec=6.0,
        )
        package = json.loads((record_path / "insight_package.json").read_text())
        assert package["session_overview"]["title"] == "Test Session"

    def test_insight_package_none_writes_empty_minutes(self, tmp_root, sample_audio):
        writer = RecordWriter()
        record_path = writer.write_record(
            root_dir=tmp_root,
            meeting_id="test-meeting-006",
            title="Test",
            source_path=str(sample_audio),
            segments=SAMPLE_SEGMENTS,
            insight_package=None,
            media_type="audio",
            record_source="imported",
            duration_sec=6.0,
        )
        metadata = json.loads((record_path / "metadata.json").read_text())
        assert metadata["autoTags"] == []
        assert metadata["summaryPreview"] == ""
        minutes = json.loads((record_path / "minutes.json").read_text())
        assert minutes == {}

    def test_media_file_copied_to_record_folder(self, tmp_root, sample_audio):
        writer = RecordWriter()
        record_path = writer.write_record(
            root_dir=tmp_root,
            meeting_id="test-meeting-007",
            title="Test",
            source_path=str(sample_audio),
            segments=SAMPLE_SEGMENTS,
            insight_package=SAMPLE_INSIGHT,
            media_type="audio",
            record_source="imported",
            duration_sec=6.0,
        )
        assert (record_path / "recording.m4a").exists()

    def test_repeated_write_skips_already_hardlinked_media(self, tmp_root, tmp_path):
        source_audio = tmp_path / "live" / "recording.wav"
        source_audio.parent.mkdir()
        source_audio.write_bytes(b"fake live wav data")

        writer = RecordWriter()
        record_path = writer.write_record(
            root_dir=tmp_root,
            meeting_id="test-meeting-live",
            title="Live",
            source_path=str(source_audio),
            segments=[],
            insight_package=None,
            media_type="audio",
            record_source="live",
            duration_sec=12.0,
            notes_md="00:05 First note",
        )
        persisted_audio = record_path / "recording.wav"
        assert os.path.samefile(source_audio, persisted_audio)

        record_path = writer.write_record(
            root_dir=tmp_root,
            meeting_id="test-meeting-live",
            title="Live",
            source_path=str(source_audio),
            segments=[],
            insight_package=SAMPLE_INSIGHT,
            media_type="audio",
            record_source="live",
            duration_sec=12.0,
            notes_md="00:05 First note\n00:08 Follow-up",
        )

        assert os.path.samefile(source_audio, record_path / "recording.wav")
        assert "Follow-up" in (record_path / "notes.md").read_text(encoding="utf-8")
        minutes = json.loads((record_path / "minutes.json").read_text(encoding="utf-8"))
        assert minutes["structured_summary"] == "A test session overview."

    def test_hardlink_fallback_to_copy(self, tmp_root, sample_audio):
        writer = RecordWriter()
        with patch("os.link", side_effect=OSError("cross-device")):
            record_path = writer.write_record(
                root_dir=tmp_root,
                meeting_id="test-meeting-008",
                title="Test",
                source_path=str(sample_audio),
                segments=SAMPLE_SEGMENTS,
                insight_package=SAMPLE_INSIGHT,
                media_type="audio",
                record_source="imported",
                duration_sec=6.0,
            )
        assert (record_path / "recording.m4a").exists()

    def test_returns_record_path(self, tmp_root, sample_audio):
        writer = RecordWriter()
        record_path = writer.write_record(
            root_dir=tmp_root,
            meeting_id="test-meeting-009",
            title="Test",
            source_path=str(sample_audio),
            segments=SAMPLE_SEGMENTS,
            insight_package=SAMPLE_INSIGHT,
            media_type="audio",
            record_source="imported",
            duration_sec=6.0,
        )
        assert isinstance(record_path, Path)
        assert record_path.name == "test-meeting-009"

    def test_notes_md_created_empty(self, tmp_root, sample_audio):
        writer = RecordWriter()
        record_path = writer.write_record(
            root_dir=tmp_root,
            meeting_id="test-meeting-010",
            title="Test",
            source_path=str(sample_audio),
            segments=SAMPLE_SEGMENTS,
            insight_package=SAMPLE_INSIGHT,
            media_type="audio",
            record_source="imported",
            duration_sec=6.0,
        )
        notes = (record_path / "notes.md").read_text()
        assert notes == ""

    def test_notes_md_written_when_provided(self, tmp_root, sample_audio):
        writer = RecordWriter()
        record_path = writer.write_record(
            root_dir=tmp_root,
            meeting_id="test-meeting-011",
            title="Test",
            source_path=str(sample_audio),
            segments=SAMPLE_SEGMENTS,
            insight_package=SAMPLE_INSIGHT,
            media_type="audio",
            record_source="imported",
            duration_sec=6.0,
            notes_md="00:01 First note\n00:30 Second note",
        )
        notes = (record_path / "notes.md").read_text()
        assert "First note" in notes


class TestDetectMediaType:
    def test_video_extensions(self):
        for ext in [".mp4", ".mov", ".mkv", ".avi", ".webm"]:
            assert detect_media_type(f"file{ext}") == "video"

    def test_audio_extensions(self):
        for ext in [".m4a", ".mp3", ".wav", ".aac", ".flac"]:
            assert detect_media_type(f"file{ext}") == "audio"

    def test_unknown_defaults_to_audio(self):
        assert detect_media_type("file.xyz") == "audio"


class TestDetectDuration:
    def test_duration_from_segments(self):
        segs = [{"end_ms": 5000}, {"end_ms": 10000}]
        assert detect_duration(segs=segs) == pytest.approx(10.0)

    def test_duration_empty_segments_returns_zero(self):
        assert detect_duration(segs=[]) == 0.0
