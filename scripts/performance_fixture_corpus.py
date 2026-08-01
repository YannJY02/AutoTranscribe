#!/usr/bin/env python3
"""Materialize and verify the sanitized installed-app benchmark corpus."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


ROOT_DIR = Path(__file__).resolve().parent.parent
DEFAULT_SPEC = ROOT_DIR / "docs/performance/fixture-corpus-spec.json"
DEFAULT_MANIFEST = ROOT_DIR / "docs/performance/fixture-corpus-manifest.json"
DEFAULT_OUTPUT_ROOT = Path.home() / "Library/Application Support/InsightKit/BenchmarkFixtures/v1"
GENERATOR_VERSION = "1"
REQUIRED_RECORD_FILES = {
    "insight_package.json",
    "metadata.json",
    "minutes.json",
    "notes.md",
    "recording.mp4",
    "transcript.json",
}
PRIVATE_TEXT = re.compile(r"(?:[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}|/Users/|Documents/InsightKit/Records)")


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(command: list[str]) -> str:
    result = subprocess.run(command, check=False, capture_output=True, text=True)
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip()
        raise RuntimeError(f"command failed ({result.returncode}): {' '.join(command)}\n{detail}")
    return result.stdout.strip()


def expand_segments(fixture: dict[str, Any]) -> list[dict[str, Any]]:
    repeat = int(fixture.get("repeat", 1))
    cycle_ms = int(float(fixture.get("cycle_duration_seconds", fixture["duration_seconds"])) * 1000)
    expanded: list[dict[str, Any]] = []
    for occurrence in range(repeat):
        offset = occurrence * cycle_ms
        for segment in fixture["segments"]:
            row = dict(segment)
            row["start_ms"] = int(segment["start_ms"]) + offset
            row["end_ms"] = int(segment["end_ms"]) + offset
            row.pop("voice", None)
            expanded.append(row)
    return expanded


def expand_expectations(fixture: dict[str, Any]) -> dict[str, list[dict[str, Any]]]:
    repeat = int(fixture.get("repeat", 1))
    cycle_ms = int(float(fixture.get("cycle_duration_seconds", fixture["duration_seconds"])) * 1000)
    output: dict[str, list[dict[str, Any]]] = {"decisions": [], "actions": [], "evidence_spans": []}
    for occurrence in range(repeat):
        offset = occurrence * cycle_ms
        for kind in output:
            for item in fixture["smart_minutes_expectations"].get(kind, []):
                row = dict(item)
                span = dict(row.get("evidence_span", row))
                span["start_ms"] = int(span["start_ms"]) + offset
                span["end_ms"] = int(span["end_ms"]) + offset
                if "evidence_span" in row:
                    row["evidence_span"] = span
                else:
                    row = span
                row["occurrence"] = occurrence + 1
                output[kind].append(row)
    return output


def validate_reference(reference: dict[str, Any]) -> None:
    required = {
        "fixture_id",
        "duration_seconds",
        "language",
        "speaker_count",
        "segments",
        "smart_minutes_expectations",
        "safety",
    }
    missing = required - reference.keys()
    if missing:
        raise ValueError(f"reference missing keys: {sorted(missing)}")
    safety = reference["safety"]
    if safety.get("synthetic") is not True or safety.get("private_record_folder") is not False:
        raise ValueError("reference safety boundary is not explicit")
    duration_ms = int(float(reference["duration_seconds"]) * 1000)
    speakers: set[str] = set()
    for segment in reference["segments"]:
        start = int(segment["start_ms"])
        end = int(segment["end_ms"])
        text = str(segment["text"]).strip()
        if not text or start < 0 or end <= start or end > duration_ms:
            raise ValueError(f"invalid transcript segment in {reference['fixture_id']}")
        if PRIVATE_TEXT.search(text):
            raise ValueError(f"reference safety check failed for {reference['fixture_id']}")
        speakers.add(str(segment["speaker"]))
    if len(speakers) != int(reference["speaker_count"]):
        raise ValueError(f"speaker count mismatch for {reference['fixture_id']}")
    for kind in ("decisions", "actions", "evidence_spans"):
        for item in reference["smart_minutes_expectations"].get(kind, []):
            span = item.get("evidence_span", item)
            if int(span["start_ms"]) < 0 or int(span["end_ms"]) > duration_ms:
                raise ValueError(f"expectation span outside media for {reference['fixture_id']}")
            if PRIVATE_TEXT.search(str(item.get("text", ""))):
                raise ValueError(f"reference safety check failed for {reference['fixture_id']}")


def build_inventory(root: Path, inventory_path: Path | None = None) -> dict[str, Any]:
    if not root.is_dir():
        raise ValueError(f"inventory root is not a directory: {root}")
    inode_hashes: dict[tuple[int, int, int], str] = {}
    rows: list[dict[str, Any]] = []
    total_bytes = 0
    for path in sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()):
        relative = path.relative_to(root).as_posix()
        stat = path.lstat()
        if path.is_symlink():
            row = {"path": relative, "type": "symlink", "byte_size": stat.st_size, "sha256": None, "target": os.readlink(path)}
        elif path.is_dir():
            row = {"path": relative, "type": "directory", "byte_size": 0, "sha256": None}
        elif path.is_file():
            key = (stat.st_dev, stat.st_ino, stat.st_size)
            if key not in inode_hashes:
                inode_hashes[key] = sha256_file(path)
            content_hash = inode_hashes[key]
            row = {"path": relative, "type": "file", "byte_size": stat.st_size, "sha256": content_hash}
            total_bytes += stat.st_size
        else:
            raise ValueError(f"unsupported inventory entry: {path}")
        rows.append(row)
    encoded_rows = [json.dumps(row, ensure_ascii=False, sort_keys=True, separators=(",", ":")) for row in rows]
    collection_sha = hashlib.sha256(("\n".join(encoded_rows) + "\n").encode()).hexdigest()
    if inventory_path:
        inventory_path.parent.mkdir(parents=True, exist_ok=True)
        inventory_path.write_text("\n".join(encoded_rows) + "\n", encoding="utf-8")
    return {
        "collection_sha256": collection_sha,
        "directory_count": sum(row["type"] == "directory" for row in rows),
        "file_count": sum(row["type"] == "file" for row in rows),
        "logical_byte_size": total_bytes,
        "inventory_path": str(inventory_path.resolve()) if inventory_path else None,
        "inventory_sha256": sha256_file(inventory_path) if inventory_path else None,
    }


def _load_reference(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    validate_reference(value)
    return value


def _insight_package(record_id: str, reference: dict[str, Any], query_hit: bool) -> dict[str, Any]:
    segment = reference["segments"][0]
    expectations = reference["smart_minutes_expectations"]
    decision = expectations["decisions"][0]
    action = expectations["actions"][0]
    return {
        "session_overview": {
            "title": f"Synthetic benchmark record {record_id[-8:]}",
            "overview": "Deterministic synthetic meeting asset for performance testing.",
            "topics": ["benchmark-focus-token"] if query_hit else ["synthetic-corpus"],
        },
        "highlight_insights": [{
            "quote": segment["text"],
            "reason": "Pinned synthetic evidence span.",
            "speaker": segment["speaker"],
            "evidence_span": {"start_ms": segment["start_ms"], "end_ms": segment["end_ms"]},
        }],
        "speaker_perspectives": [{
            "speaker": segment["speaker"],
            "viewpoints": [segment["text"]],
            "evidence_spans": [{"start_ms": segment["start_ms"], "end_ms": segment["end_ms"]}],
        }],
        "decision_ledger": [{
            "problem": "Choose the benchmark procedure.",
            "options": ["change inputs", "use frozen inputs"],
            "decision": decision["text"],
            "rationale": "The fixture requires comparable runs.",
            "owner": segment["speaker"],
            "needs_review": False,
            "evidence_span": decision["evidence_span"],
        }],
        "action_tracks": [{
            "task": action["text"],
            "owner": segment["speaker"],
            "due_at": "",
            "priority": "medium",
            "status": "open",
            "needs_review": False,
            "evidence_span": action["evidence_span"],
        }],
        "timeline_beats": [{"timestamp": "00:01", "title": "Benchmark start", "summary": segment["text"]}],
        "provenance_links": [{"label": "Synthetic fixture", "url": f"insightkit://record/{record_id}"}],
    }


def validate_record_folder(folder: Path) -> None:
    names = {path.name for path in folder.iterdir()}
    if names != REQUIRED_RECORD_FILES:
        raise ValueError(f"incomplete Record Folder {folder}: {sorted(names ^ REQUIRED_RECORD_FILES)}")
    metadata = json.loads((folder / "metadata.json").read_text(encoding="utf-8"))
    for key in ("id", "createdAt", "duration", "mediaType", "source", "userTags", "autoTags", "summaryPreview"):
        if key not in metadata:
            raise ValueError(f"metadata missing {key}: {folder}")
    datetime.strptime(metadata["createdAt"], "%Y-%m-%dT%H:%M:%SZ")
    if metadata["mediaType"] != "video" or metadata["source"] != "imported" or float(metadata["duration"]) <= 0:
        raise ValueError(f"invalid metadata values: {folder}")
    transcript = json.loads((folder / "transcript.json").read_text(encoding="utf-8"))
    if not transcript or any(not {"start_ms", "end_ms", "speaker", "text"} <= row.keys() for row in transcript):
        raise ValueError(f"invalid transcript: {folder}")
    package = json.loads((folder / "insight_package.json").read_text(encoding="utf-8"))
    required_package = {
        "session_overview",
        "highlight_insights",
        "speaker_perspectives",
        "decision_ledger",
        "action_tracks",
        "timeline_beats",
        "provenance_links",
    }
    if not required_package <= package.keys():
        raise ValueError(f"invalid insight package: {folder}")
    json.loads((folder / "minutes.json").read_text(encoding="utf-8"))
    (folder / "notes.md").read_text(encoding="utf-8")
    if not (folder / "recording.mp4").is_file():
        raise ValueError(f"missing media: {folder}")


def write_record_collection(
    root: Path,
    *,
    count: int,
    seed: int,
    media: dict[str, Path],
    references: dict[str, Path],
    generator_revision: str,
    inventory_path: Path | None = None,
) -> dict[str, Any]:
    if root.exists() and any(root.iterdir()):
        raise ValueError(f"collection root is not empty: {root}")
    root.mkdir(parents=True, exist_ok=True)
    loaded = {fixture_id: _load_reference(path) for fixture_id, path in references.items()}
    collection_meta = {
        "generator_revision": generator_revision,
        "generator_version": GENERATOR_VERSION,
        "record_count": count,
        "seed": seed,
    }
    write_json(root / "_collection.json", collection_meta)
    base_time = datetime(2026, 1, 1, tzinfo=timezone.utc)
    query_hits = 0
    for index in range(count):
        fixture_id = "long-mixed" if index % 10 == 0 else "short-mixed"
        reference = loaded[fixture_id]
        record_id = str(uuid.uuid5(uuid.NAMESPACE_URL, f"insightkit-benchmark:{seed}:{index}"))
        created_at = base_time + timedelta(minutes=index)
        folder = root / f"{created_at:%Y%m%d-%H%M}-benchmark-{index:04d}-{record_id[:8]}"
        folder.mkdir()
        query_hit = index % 10 == 0
        query_hits += int(query_hit)
        package = _insight_package(record_id, reference, query_hit)
        metadata = {
            "id": record_id,
            "createdAt": created_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "duration": reference["duration_seconds"],
            "mediaType": "video",
            "source": "imported",
            "title": f"Benchmark focus review {index}" if query_hit else f"Synthetic benchmark record {index}",
            "userTags": [],
            "autoTags": package["session_overview"]["topics"],
            "summaryPreview": package["session_overview"]["overview"],
        }
        write_json(folder / "metadata.json", metadata)
        write_json(folder / "transcript.json", reference["segments"])
        write_json(folder / "insight_package.json", package)
        write_json(folder / "minutes.json", {
            "structured_summary": package["session_overview"]["overview"],
            "highlights": [package["highlight_insights"][0]["quote"]],
            "key_decisions": [package["decision_ledger"][0]["decision"]],
            "action_items": [package["action_tracks"][0]["task"]],
            "timeline_beats": package["timeline_beats"],
        })
        (folder / "notes.md").write_text("00:01 Synthetic benchmark note.\n", encoding="utf-8")
        os.link(media[fixture_id], folder / "recording.mp4")
        validate_record_folder(folder)
    inventory = build_inventory(root, inventory_path or root.parent / f"{root.name}.inventory.jsonl")
    return {**collection_meta, **inventory, "absolute_path": str(root.resolve()), "search_query_hit_count": query_hits}


def write_scenario_parameters(root: Path, *, search_query: str) -> dict[str, Any]:
    trace_root = root / "scenario-inputs"
    traces = {
        "keyboard": {"version": 1, "events": [{"at_ms": i * 80, "key": char} for i, char in enumerate(search_query)]},
        "pointer": {"version": 1, "coordinates": "normalized", "events": [{"at_ms": 0, "x": 0.5, "y": 0.5, "action": "click"}]},
        "scroll": {"version": 1, "events": [{"at_ms": i * 16, "delta_y": -24} for i in range(120)]},
        "resize": {"version": 1, "events": [{"at_ms": 0, "width": 1100, "height": 760}, {"at_ms": 1000, "width": 1440, "height": 900}]},
    }
    pinned: dict[str, dict[str, Any]] = {}
    for name, value in traces.items():
        path = trace_root / f"{name}.json"
        write_json(path, value)
        pinned[name] = {"absolute_path": str(path.resolve()), "byte_size": path.stat().st_size, "sha256": sha256_file(path)}
    return {
        "input_traces": pinned,
        "workspace_navigation_order": ["home", "live", "import", "records", "settings"],
        "generated_record_search_query": search_query,
        "playback_window_seconds": 60,
        "seek_target_fraction": 0.6,
        "post_workload_recovery_seconds": 300,
    }


def probe_media(path: Path) -> dict[str, Any]:
    payload = json.loads(run(["ffprobe", "-v", "error", "-show_entries", "format=duration,format_name:stream=codec_name,codec_type", "-of", "json", str(path)]))
    return {
        "container": payload["format"]["format_name"],
        "duration_seconds": float(payload["format"]["duration"]),
        "codecs": sorted(f"{stream['codec_type']}:{stream['codec_name']}" for stream in payload["streams"]),
    }


def audio_packet_sha256(path: Path) -> str:
    output = run(["ffmpeg", "-v", "error", "-i", str(path), "-map", "0:a:0", "-c", "copy", "-f", "hash", "-hash", "sha256", "-"])
    return output.rsplit("=", 1)[-1].strip().lower()


def tempo_filter(speech_seconds: float, slot_seconds: float) -> str:
    if speech_seconds <= slot_seconds:
        return ""
    ratio = speech_seconds / slot_seconds
    if ratio > 2:
        raise ValueError("speech is more than twice its transcript span")
    return f"atempo={ratio:.6f},"


def _synthesize_cycle(fixture: dict[str, Any], path: Path, work: Path) -> None:
    inputs: list[str] = []
    filters: list[str] = []
    labels: list[str] = []
    for index, segment in enumerate(fixture["segments"]):
        voice_path = work / f"voice-{index:02d}.aiff"
        run(["say", "-v", segment["voice"], "-r", "190", "-o", str(voice_path), segment["text"]])
        slot_seconds = (int(segment["end_ms"]) - int(segment["start_ms"])) / 1000
        fit = tempo_filter(probe_media(voice_path)["duration_seconds"], slot_seconds)
        inputs.extend(["-i", str(voice_path)])
        label = f"s{index}"
        labels.append(f"[{label}]")
        filters.append(
            f"[{index}:a]aresample=16000,{fit}atrim=0:{slot_seconds},asetpts=PTS-STARTPTS,"
            f"adelay={int(segment['start_ms'])}:all=1[{label}]"
        )
    duration = float(fixture["cycle_duration_seconds"])
    filters.append(
        f"{''.join(labels)}amix=inputs={len(labels)}:normalize=0:dropout_transition=0,"
        f"alimiter=limit=0.95,apad=whole_dur={duration},atrim=0:{duration}[out]"
    )
    run(["ffmpeg", "-v", "error", "-y", *inputs, "-filter_complex", ";".join(filters), "-map", "[out]", "-c:a", "pcm_s16le", str(path)])


def synthesize_media(fixture: dict[str, Any], media_root: Path) -> list[Path]:
    fixture_id = fixture["fixture_id"]
    duration = float(fixture["duration_seconds"])
    media_root.mkdir(parents=True, exist_ok=True)
    audio_path = media_root / f"{fixture_id}.m4a"
    with tempfile.TemporaryDirectory(prefix=f"insightkit-{fixture_id}-") as temp:
        cycle_path = Path(temp) / "cycle.wav"
        _synthesize_cycle(fixture, cycle_path, Path(temp))
        run([
            "ffmpeg", "-v", "error", "-y", "-stream_loop", str(int(fixture.get("repeat", 1)) - 1),
            "-i", str(cycle_path), "-t", str(duration), "-map", "0:a:0", "-c:a", "aac", "-b:a", "64k",
            "-ar", "16000", "-ac", "1", "-map_metadata", "-1", "-movflags", "+faststart", str(audio_path),
        ])
    paths = [audio_path]
    if fixture.get("video_companion"):
        video_path = media_root / f"{fixture_id}.mp4"
        run([
            "ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", f"color=c=0x20242b:s=640x360:r=1:d={duration}",
            "-i", str(audio_path), "-map", "0:v:0", "-map", "1:a:0", "-c:v", "libx264", "-preset", "ultrafast",
            "-tune", "stillimage", "-crf", "35", "-pix_fmt", "yuv420p", "-c:a", "copy", "-t", str(duration),
            "-map_metadata", "-1", "-movflags", "+faststart", str(video_path),
        ])
        if audio_packet_sha256(video_path) != audio_packet_sha256(audio_path):
            raise ValueError(f"MP4 companion audio differs from canonical M4A: {fixture_id}")
        paths.append(video_path)
    return paths


def _tool_version(command: list[str]) -> str:
    return run(command).splitlines()[0]


def _git_revision() -> str:
    return run(["git", "rev-parse", "HEAD"])


def materialize(*, spec_path: Path, output_root: Path, manifest_path: Path, generator_revision: str, force: bool) -> dict[str, Any]:
    records_root = Path.home() / "Documents/InsightKit/Records"
    if output_root.resolve().is_relative_to(records_root.resolve()):
        raise ValueError("benchmark corpus must not use the private Record Folder root")
    if output_root.exists():
        if not force:
            raise ValueError(f"output exists; pass --force to replace generated fixtures: {output_root}")
        shutil.rmtree(output_root)
    output_root.mkdir(parents=True)
    spec = json.loads(spec_path.read_text(encoding="utf-8"))
    media_root = output_root / "media"
    reference_root = output_root / "reference-transcripts"
    fixtures: list[dict[str, Any]] = []
    media_by_fixture: dict[str, list[Path]] = {}
    reference_paths: dict[str, Path] = {}
    for source in spec["fixtures"]:
        reference = {
            "fixture_id": source["fixture_id"],
            "duration_seconds": source["duration_seconds"],
            "language": source["language"],
            "speaker_count": source["speaker_count"],
            "segments": expand_segments(source),
            "smart_minutes_expectations": expand_expectations(source),
            "safety": {"synthetic": True, "private_record_folder": False, "approved_for_local_benchmark": True},
            "provenance": {
                "kind": "synthetic_apple_speech",
                "source_spec": str(spec_path.resolve()),
                "generator_revision": generator_revision,
                "generator_version": GENERATOR_VERSION,
            },
        }
        validate_reference(reference)
        reference_path = reference_root / f"{source['fixture_id']}.json"
        write_json(reference_path, reference)
        reference_paths[source["fixture_id"]] = reference_path
        media_paths = synthesize_media(source, media_root)
        media_by_fixture[source["fixture_id"]] = media_paths
        audio_hash = audio_packet_sha256(media_paths[0])
        media_assets = []
        for media_path in media_paths:
            probe = probe_media(media_path)
            media_assets.append({
                "role": "canonical_audio" if media_path.suffix == ".m4a" else "video_companion",
                "absolute_path": str(media_path.resolve()),
                "byte_size": media_path.stat().st_size,
                "sha256": sha256_file(media_path),
                "audio_packet_sha256": audio_hash,
                **probe,
            })
        expectations = reference["smart_minutes_expectations"]
        fixtures.append({
            "fixture_id": source["fixture_id"],
            "target_duration_seconds": source["duration_seconds"],
            "language": source["language"],
            "speaker_count": source["speaker_count"],
            "reference_transcript": {
                "absolute_path": str(reference_path.resolve()),
                "byte_size": reference_path.stat().st_size,
                "sha256": sha256_file(reference_path),
            },
            "smart_minutes_expectations": {
                "decision_count": len(expectations["decisions"]),
                "action_count": len(expectations["actions"]),
                "evidence_span_count": len(expectations["evidence_spans"]),
            },
            "media": media_assets,
            "provenance": reference["provenance"],
            "safety": reference["safety"],
        })
    scenario = write_scenario_parameters(output_root, search_query=spec["scenario_parameters"]["generated_record_search_query"])
    inventories_root = output_root / "inventories"
    collections = []
    record_media = {key: next(path for path in paths if path.suffix == ".mp4") for key, paths in media_by_fixture.items() if key in {"short-mixed", "long-mixed"}}
    record_references = {key: reference_paths[key] for key in ("short-mixed", "long-mixed")}
    for count in (100, 1000):
        collection = write_record_collection(
            output_root / f"records-{count}",
            count=count,
            seed=int(spec["record_collections"]["seed"]),
            media=record_media,
            references=record_references,
            generator_revision=generator_revision,
            inventory_path=inventories_root / f"records-{count}.jsonl",
        )
        collections.append(collection)
        scenario.setdefault("expected_search_results", {})[str(count)] = collection["search_query_hit_count"]
    manifest = {
        "schema_version": 1,
        "status": "frozen",
        "corpus_id": "insightkit-installed-app-benchmark-v1",
        "absolute_root": str(output_root.resolve()),
        "generator": {
            "revision": generator_revision,
            "version": GENERATOR_VERSION,
            "source": str(Path(__file__).resolve()),
            "source_sha256": sha256_file(Path(__file__)),
            "spec": str(spec_path.resolve()),
            "spec_sha256": sha256_file(spec_path),
            "record_seed": int(spec["record_collections"]["seed"]),
        },
        "tools": {
            "ffmpeg": _tool_version(["ffmpeg", "-version"]),
            "ffprobe": _tool_version(["ffprobe", "-version"]),
            "say_voices": sorted({segment["voice"] for fixture in spec["fixtures"] for segment in fixture["segments"]}),
        },
        "fixtures": fixtures,
        "record_collections": collections,
        "scenario_parameters": scenario,
        "safety": {
            "synthetic_only": True,
            "private_record_folders_used": False,
            "media_committed_to_git": False,
            "credentials_present": False,
        },
    }
    write_json(output_root / "manifest.json", manifest)
    write_json(manifest_path, manifest)
    verify_manifest(manifest_path)
    return manifest


def verify_manifest(manifest_path: Path) -> dict[str, Any]:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("status") != "frozen" or manifest.get("safety", {}).get("synthetic_only") is not True:
        raise ValueError("manifest is not frozen and synthetic")
    verified_assets = 0
    for fixture in manifest["fixtures"]:
        reference_pin = fixture["reference_transcript"]
        reference_path = Path(reference_pin["absolute_path"])
        if sha256_file(reference_path) != reference_pin["sha256"] or reference_path.stat().st_size != reference_pin["byte_size"]:
            raise ValueError(f"reference hash drift: {fixture['fixture_id']}")
        reference = _load_reference(reference_path)
        expectations = reference["smart_minutes_expectations"]
        expected_counts = fixture["smart_minutes_expectations"]
        if [len(expectations[key]) for key in ("decisions", "actions", "evidence_spans")] != [
            expected_counts["decision_count"], expected_counts["action_count"], expected_counts["evidence_span_count"]
        ]:
            raise ValueError(f"Smart Minutes expectation drift: {fixture['fixture_id']}")
        audio_hashes = set()
        for asset in fixture["media"]:
            path = Path(asset["absolute_path"])
            if sha256_file(path) != asset["sha256"] or path.stat().st_size != asset["byte_size"]:
                raise ValueError(f"media hash drift: {path}")
            probe = probe_media(path)
            if abs(probe["duration_seconds"] - float(fixture["target_duration_seconds"])) > 0.05:
                raise ValueError(f"media duration drift: {path}")
            if probe["container"] != asset["container"] or probe["codecs"] != asset["codecs"]:
                raise ValueError(f"media format drift: {path}")
            audio_hashes.add(audio_packet_sha256(path))
            verified_assets += 1
        if len(audio_hashes) != 1:
            raise ValueError(f"companion audio mismatch: {fixture['fixture_id']}")
    verified_records = 0
    for collection in manifest["record_collections"]:
        root = Path(collection["absolute_path"])
        folders = sorted(path for path in root.iterdir() if path.is_dir())
        if len(folders) != int(collection["record_count"]):
            raise ValueError(f"record count drift: {root}")
        for folder in folders:
            validate_record_folder(folder)
            verified_records += 1
        inventory = build_inventory(root)
        if inventory["collection_sha256"] != collection["collection_sha256"]:
            raise ValueError(f"collection hash drift: {root}")
        inventory_path = Path(collection["inventory_path"])
        if sha256_file(inventory_path) != collection["inventory_sha256"]:
            raise ValueError(f"inventory hash drift: {root}")
    for trace in manifest["scenario_parameters"]["input_traces"].values():
        path = Path(trace["absolute_path"])
        if sha256_file(path) != trace["sha256"] or path.stat().st_size != trace["byte_size"]:
            raise ValueError(f"scenario trace drift: {path}")
    return {"fixture_assets_verified": verified_assets, "record_folders_verified": verified_records, "status": "passed"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    create = subparsers.add_parser("materialize")
    create.add_argument("--spec", type=Path, default=DEFAULT_SPEC)
    create.add_argument("--output-root", type=Path, default=DEFAULT_OUTPUT_ROOT)
    create.add_argument("--manifest-out", type=Path, default=DEFAULT_MANIFEST)
    create.add_argument("--generator-revision", default=None)
    create.add_argument("--force", action="store_true")
    verify = subparsers.add_parser("verify")
    verify.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.command == "materialize":
        result = materialize(
            spec_path=args.spec.resolve(),
            output_root=args.output_root.expanduser().resolve(),
            manifest_path=args.manifest_out.resolve(),
            generator_revision=args.generator_revision or _git_revision(),
            force=args.force,
        )
        print(json.dumps({"manifest": str(args.manifest_out.resolve()), "corpus_id": result["corpus_id"]}, sort_keys=True))
    else:
        print(json.dumps(verify_manifest(args.manifest.resolve()), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
