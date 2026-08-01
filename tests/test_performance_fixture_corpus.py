import json
from pathlib import Path

import pytest

from scripts.performance_fixture_corpus import (
    build_inventory,
    expand_segments,
    sha256_file,
    tempo_filter,
    validate_output_root,
    validate_reference,
    validate_record_folder,
    verify_file_pin,
    write_record_collection,
    write_scenario_parameters,
)


def test_expand_segments_repeats_with_stable_offsets():
    fixture = {
        "duration_seconds": 30,
        "repeat": 3,
        "cycle_duration_seconds": 10,
        "segments": [
            {"start_ms": 1000, "end_ms": 3000, "speaker": "A", "text": "First"},
            {"start_ms": 6000, "end_ms": 8000, "speaker": "B", "text": "Second"},
        ],
    }

    expanded = expand_segments(fixture)

    assert [row["start_ms"] for row in expanded] == [1000, 6000, 11000, 16000, 21000, 26000]
    assert expanded[-1]["end_ms"] == 28000


def test_tempo_filter_fits_speech_without_truncating_words():
    assert tempo_filter(4.0, 5.0) == ""
    assert tempo_filter(5.5, 5.0) == "atempo=1.100000,"
    with pytest.raises(ValueError, match="twice"):
        tempo_filter(10.1, 5.0)


def test_validate_reference_rejects_private_or_unbounded_content():
    safe = {
        "fixture_id": "short-en",
        "duration_seconds": 10,
        "language": "English",
        "speaker_count": 1,
        "segments": [{"start_ms": 0, "end_ms": 1000, "speaker": "A", "text": "Safe synthetic text"}],
        "smart_minutes_expectations": {"decisions": [], "actions": [], "evidence_spans": []},
        "safety": {"synthetic": True, "private_record_folder": False},
    }
    validate_reference(safe)

    unsafe = json.loads(json.dumps(safe))
    unsafe["segments"][0]["text"] = "Email private.person@example.com"
    with pytest.raises(ValueError, match="safety"):
        validate_reference(unsafe)


def test_inventory_is_root_independent_and_detects_drift(tmp_path: Path):
    first = tmp_path / "first"
    second = tmp_path / "second"
    for root in (first, second):
        (root / "nested").mkdir(parents=True)
        (root / "nested" / "a.txt").write_text("same", encoding="utf-8")

    first_inventory = build_inventory(first)
    second_inventory = build_inventory(second)
    assert first_inventory["collection_sha256"] == second_inventory["collection_sha256"]

    (second / "nested" / "a.txt").write_text("changed", encoding="utf-8")
    assert build_inventory(second)["collection_sha256"] != first_inventory["collection_sha256"]


def test_file_pin_verification_checks_size_and_hash(tmp_path: Path):
    path = tmp_path / "asset.bin"
    path.write_bytes(b"frozen")
    pin = {"byte_size": path.stat().st_size, "sha256": sha256_file(path)}
    verify_file_pin(path, pin, "asset")

    pin["sha256"] = "0" * 64
    with pytest.raises(ValueError, match="asset hash drift"):
        verify_file_pin(path, pin, "asset")


def test_output_root_rejects_private_records_and_broad_targets(tmp_path: Path):
    validate_output_root(tmp_path / "generated" / "fixture" / "v1")

    with pytest.raises(ValueError, match="broad"):
        validate_output_root(Path.home())
    for records_root in (
        Path.home() / "Documents/InsightKit/Records/candidate",
        Path.home() / "Library/Application Support/InsightKit/Records/candidate",
    ):
        with pytest.raises(ValueError, match="private Record Folder"):
            validate_output_root(records_root)


def test_record_collections_are_deterministic_complete_and_parseable(tmp_path: Path):
    media = {}
    references = {}
    for fixture_id in ("short-mixed", "long-mixed"):
        media_path = tmp_path / f"{fixture_id}.mp4"
        media_path.write_bytes(fixture_id.encode())
        media[fixture_id] = media_path
        reference_path = tmp_path / f"{fixture_id}.reference.json"
        reference_path.write_text(
            json.dumps(
                {
                    "fixture_id": fixture_id,
                    "duration_seconds": 300 if fixture_id == "short-mixed" else 3600,
                    "language": "Chinese/English",
                    "speaker_count": 2 if fixture_id == "short-mixed" else 3,
                    "segments": [
                        {
                            "start_ms": 1000 + index * 4000,
                            "end_ms": 4000 + index * 4000,
                            "speaker": chr(ord("A") + index),
                            "text": "Benchmark focus token",
                        }
                        for index in range(2 if fixture_id == "short-mixed" else 3)
                    ],
                    "smart_minutes_expectations": {
                        "decisions": [
                            {"text": "Use the frozen plan", "evidence_span": {"start_ms": 1000, "end_ms": 4000}}
                        ],
                        "actions": [
                            {"text": "Run the next check", "evidence_span": {"start_ms": 1000, "end_ms": 4000}}
                        ],
                        "evidence_spans": [{"start_ms": 1000, "end_ms": 4000}],
                    },
                    "safety": {"synthetic": True, "private_record_folder": False},
                },
                sort_keys=True,
            ),
            encoding="utf-8",
        )
        references[fixture_id] = reference_path

    first = write_record_collection(
        tmp_path / "first",
        count=5,
        seed=20260801,
        media=media,
        references=references,
        generator_revision="test-revision",
    )
    second = write_record_collection(
        tmp_path / "second",
        count=5,
        seed=20260801,
        media=media,
        references=references,
        generator_revision="test-revision",
    )

    assert first["collection_sha256"] == second["collection_sha256"]
    assert first["record_count"] == 5
    folders = sorted(path for path in (tmp_path / "first").iterdir() if path.is_dir())
    assert len(folders) == 5
    for folder in folders:
        validate_record_folder(folder)
        assert {path.name for path in folder.iterdir()} == {
            "insight_package.json",
            "metadata.json",
            "minutes.json",
            "notes.md",
            "recording.mp4",
            "transcript.json",
        }

    broken = folders[0]
    package_path = broken / "insight_package.json"
    package = json.loads(package_path.read_text(encoding="utf-8"))
    package["decision_ledger"][0]["evidence_span"]["start_ms"] = "not-an-integer"
    package_path.write_text(json.dumps(package), encoding="utf-8")
    with pytest.raises(ValueError, match="insight package"):
        validate_record_folder(broken)


def test_scenario_parameters_pin_every_replay_input(tmp_path: Path):
    scenario = write_scenario_parameters(tmp_path, search_query="benchmark-focus-token")

    assert scenario["workspace_navigation_order"] == ["home", "live", "import", "records", "settings"]
    assert scenario["playback_window_seconds"] == 60
    assert scenario["seek_target_fraction"] == 0.6
    assert scenario["post_workload_recovery_seconds"] == 300
    assert set(scenario["input_traces"]) == {"keyboard", "pointer", "resize", "scroll"}
    for trace in scenario["input_traces"].values():
        assert Path(trace["absolute_path"]).is_absolute()
        assert len(trace["sha256"]) == 64
