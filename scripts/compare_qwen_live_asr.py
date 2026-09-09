#!/usr/bin/env python3
"""Bounded, offline Qwen live-core experiment; one fresh process per model.

Replays the first 58 seconds twice through the accepted runtime's foreground
transcriber (2 seconds, then seven 8-second chunks). This measures core service
time, not RPC/UI latency. Model acquisition and the shared performance lock are
the caller's responsibility. No installed configuration or vendor file changes.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
from functools import wraps
import hashlib
import importlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile
import time
import traceback
import unicodedata
import wave


END_MS = 58_000
SAMPLE_RATE = 16_000
BOUNDARIES_MS = (0, 2_000, 10_000, 18_000, 26_000, 34_000, 42_000, 50_000, END_MS)
DEFAULT_MODEL_DIR = Path.home() / "Library/Application Support/InsightKit/models"
MODEL_KEYS = ("INSIGHTKIT_ASR_MODEL", "INSIGHTKIT_QWEN_MLX_MODEL", "INSIGHTKIT_QWEN_ASR_MODEL")
PASS_LABELS = ("first_pass_after_session_load", "same_process_repeat")
HAN = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\U00020000-\U0002fa1f]")
ENGLISH_WORD = re.compile(r"[a-z0-9]+(?:'[a-z0-9]+)*")


def sha256_file(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def write_report(path: Path, report: dict) -> None:
    """Replace only the result file atomically, including after failed chunks."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(report, stream, ensure_ascii=False, indent=2, allow_nan=False)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def error_info(error: BaseException) -> dict:
    return {"type": type(error).__name__, "message": str(error)}


def read_asr_config(path: Path | None) -> dict:
    if path is None:
        return {"engine": "qwen-mlx", "modelDir": str(DEFAULT_MODEL_DIR),
                "vadEnabled": True, "diarizationEnabled": True}
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError("runtime config must be an object")
    asr = data.get("asr", data)
    if not isinstance(asr, dict) or asr.get("engine", "qwen-mlx") != "qwen-mlx":
        raise ValueError("runtime config must select qwen-mlx")
    for key in ("vadEnabled", "diarizationEnabled"):
        if key in asr and not isinstance(asr[key], bool):
            raise ValueError(f"asr.{key} must be a boolean")
    return asr


def validate_local_model(path: Path) -> Path:
    path = path.expanduser().resolve()
    if not path.is_dir() or not (path / "config.json").is_file():
        raise ValueError(f"local model config is missing: {path}")
    if not any(path.glob("*.safetensors")):
        raise ValueError(f"local model weights are missing: {path}")
    if not isinstance(json.loads((path / "config.json").read_text()), dict):
        raise ValueError(f"local model config must be an object: {path}")
    return path


def resolve_model(model: str) -> Path:
    """Full repo IDs resolve only from their own HF cache, never by basename."""
    path = Path(model).expanduser()
    if path.is_absolute():
        return validate_local_model(path)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*", model):
        raise ValueError("--model must be an absolute local path or full owner/repo ID")
    from huggingface_hub import snapshot_download

    return validate_local_model(Path(snapshot_download(repo_id=model, local_files_only=True)))


def model_environment(asr: dict, model: Path, inherited: dict[str, str]) -> dict[str, str]:
    """Mirror the app's ASR environment, overriding the model only in the child."""
    env = dict(inherited)
    model_dir = Path(asr.get("modelDir") or DEFAULT_MODEL_DIR).expanduser().resolve()
    aligner = Path(env.get("INSIGHTKIT_QWEN_FORCED_ALIGNER_PATH") or
                   model_dir / "qwen3-asr/Qwen3-ForcedAligner-0.6B").expanduser().resolve()
    env.update({key: str(model) for key in MODEL_KEYS})
    env.update({
        "INSIGHTKIT_ASR_ENGINE": "qwen-mlx",
        "INSIGHTKIT_MODEL_DIR": str(model_dir),
        "INSIGHTKIT_QWEN_MLX_MODEL_PATH": str(model),
        "INSIGHTKIT_QWEN_FORCED_ALIGNER_MODEL": "Qwen3-ForcedAligner-0.6B",
        "INSIGHTKIT_QWEN_FORCED_ALIGNER_PATH": str(aligner),
        "INSIGHTKIT_ASR_STRICT_LOCAL_ONLY": "1",
        "INSIGHTKIT_QWEN_RETURN_TIMESTAMPS": "1",
        "INSIGHTKIT_VAD_ENABLED": "1" if asr.get("vadEnabled", True) else "0",
        "INSIGHTKIT_DIARIZATION_ENABLED": "1" if asr.get("diarizationEnabled", True) else "0",
        "HF_HUB_OFFLINE": "1",
        "TRANSFORMERS_OFFLINE": "1",
        "PYTHONDONTWRITEBYTECODE": "1",
    })
    return env


def prepare_input(audio: Path, reference: Path, directory: Path) -> tuple[dict, list[dict]]:
    data = json.loads(reference.read_text(encoding="utf-8"))
    segments = data.get("segments")
    if not isinstance(segments, list) or not segments:
        raise ValueError("reference must contain nonempty segments")
    selected = []
    for segment in segments:
        start, end = segment["start_ms"], segment["end_ms"]
        if start < 0 or end <= start or not isinstance(segment.get("text"), str):
            raise ValueError("reference has an invalid segment")
        if start >= END_MS:
            continue
        if end > END_MS:
            raise ValueError("reference segment crosses the 58-second boundary")
        selected.append(segment)
    selected.sort(key=lambda item: item["start_ms"])
    if not selected:
        raise ValueError("reference has no complete segment in the first 58 seconds")
    with wave.open(str(audio), "rb") as stream:
        if (stream.getnchannels(), stream.getsampwidth(), stream.getframerate(), stream.getcomptype()) != (1, 2, SAMPLE_RATE, "NONE"):
            raise ValueError("input must be mono 16-kHz PCM16 WAV; no implicit resampling")
        source_frames = stream.getnframes()
        if source_frames < END_MS * SAMPLE_RATE // 1000:
            raise ValueError("input is shorter than 58 seconds")
        pcm = stream.readframes(END_MS * SAMPLE_RATE // 1000)
    if len(pcm) != END_MS * SAMPLE_RATE * 2 // 1000:
        raise ValueError("input WAV contains fewer PCM bytes than its header claims")
    chunks = []
    for index, (start, end) in enumerate(zip(BOUNDARIES_MS, BOUNDARIES_MS[1:]), 1):
        frames = pcm[start * SAMPLE_RATE * 2 // 1000:end * SAMPLE_RATE * 2 // 1000]
        path = directory / f"chunk-{index:02}.wav"
        with wave.open(str(path), "wb") as stream:
            stream.setparams((1, 2, SAMPLE_RATE, 0, "NONE", "not compressed"))
            stream.writeframes(frames)
        chunks.append({"index": index, "start_ms": start, "end_ms": end,
                       "audio_ms": end - start, "pcm_sha256": hashlib.sha256(frames).hexdigest(),
                       "path": path})
    receipt = {
        "wav_sha256": sha256_file(audio), "reference_sha256": sha256_file(reference),
        "selected_pcm_sha256": hashlib.sha256(pcm).hexdigest(),
        "source_duration_ms": source_frames * 1000 / SAMPLE_RATE,
        "selected_duration_ms": END_MS, "reference_segments": selected,
        "reference_text": " ".join(item["text"] for item in selected),
        "fixture_id": data.get("fixture_id"), "safety": data.get("safety"),
        "provenance": data.get("provenance"),
    }
    return receipt, chunks


def edit_distance(reference: list[str], hypothesis: list[str]) -> int:
    previous = list(range(len(hypothesis) + 1))
    for i, expected in enumerate(reference, 1):
        current = [i]
        for j, actual in enumerate(hypothesis, 1):
            current.append(min(current[-1] + 1, previous[j] + 1,
                               previous[j - 1] + (expected != actual)))
        previous = current
    return previous[-1]


def quality_metrics(reference: str, hypothesis: str) -> dict:
    normalize = lambda value: unicodedata.normalize("NFKC", value).lower().replace("’", "'")
    result = {}
    for name, tokenizer in (("chinese_cer", HAN.findall), ("english_wer", ENGLISH_WORD.findall)):
        expected, actual = tokenizer(normalize(reference)), tokenizer(normalize(hypothesis))
        errors = edit_distance(expected, actual)
        result[name] = {"errors": errors, "reference_units": len(expected),
                        "hypothesis_units": len(actual),
                        "rate": errors / len(expected) if expected else None}
    return result


def queue_estimate(chunks: list[dict]) -> dict:
    available = 0.0
    rows = []
    first_text = None
    for chunk in chunks:
        arrival = float(chunk["end_ms"])
        start = max(arrival, available)
        available = start + chunk["call_wall_ms"]
        rows.append({"index": chunk["index"], "arrival_ms": arrival, "start_ms": start,
                     "finish_ms": available, "queue_wait_ms": start - arrival,
                     "result_after_chunk_end_ms": available - arrival})
        if first_text is None and chunk.get("text"):
            first_text = available
    return {
        "kind": "offline_serial_service_projection_not_ui_measurement",
        "assumption": "Model ready at t=0; chunks arrive at their audio end; measured offline service times reused; no enrichment, IPC, or UI work.",
        "first_text_at_ms": first_text,
        "max_queue_wait_ms": max((row["queue_wait_ms"] for row in rows), default=0.0),
        "finish_ms": available, "chunks": rows,
    }


class LibraryProbe:
    """Reversible wrappers for the installed mlx-qwen3-asr 0.3.5 boundaries.

    The runtime's sole MLX worker runs while the caller blocks. One active
    measurement spans both threads; no request is submitted concurrently. Spans
    are inclusive/nested and must not be added together as disjoint work.
    """

    def __init__(self, model: Path, aligner: Path, *, clock_ns=time.monotonic_ns):
        self.model, self.aligner, self.clock_ns = model, aligner, clock_ns
        self.active = None
        self.originals = []

    @contextmanager
    def measure(self):
        if self.active is not None:
            raise RuntimeError("library probe does not support concurrent requests")
        state = {"origin_ns": self.clock_ns(), "spans": [], "generation_chunks": [],
                 "session_options": [], "recognition": None}
        self.active = state
        try:
            yield state
        finally:
            self.finish_recognition("incomplete")
            self.active = None
            state.pop("origin_ns")
            state.pop("recognition")

    def start(self, phase: str) -> dict | None:
        if self.active is None:
            return None
        span = {"phase": phase, "start_offset_ns": self.clock_ns() - self.active["origin_ns"],
                "end_offset_ns": None, "outcome": "running"}
        self.active["spans"].append(span)
        return span

    def finish(self, span: dict | None, outcome: str) -> None:
        if span is None or self.active is None:
            return
        span["end_offset_ns"] = self.clock_ns() - self.active["origin_ns"]
        span["duration_ns"] = span["end_offset_ns"] - span["start_offset_ns"]
        span["outcome"] = outcome

    def finish_recognition(self, outcome: str) -> None:
        if self.active is not None:
            self.finish(self.active["recognition"], outcome)
            self.active["recognition"] = None

    def progress(self, event: dict) -> None:
        if self.active is None:
            return
        if event.get("event") == "chunk_started":
            self.finish_recognition("incomplete")
            self.active["recognition"] = self.start("asr_features_generation_parse")
        elif event.get("event") == "chunk_completed":
            self.finish_recognition("completed")

    def patch(self, target, name: str, replacement) -> None:
        self.originals.append((target, name, getattr(target, name)))
        setattr(target, name, replacement)

    def timed(self, target, name: str, phase):
        original = getattr(target, name)

        @wraps(original)
        def wrapped(*args, **kwargs):
            label = phase(*args, **kwargs) if callable(phase) else phase
            if label == "forced_alignment_total":
                self.finish_recognition("completed")
            span = self.start(label)
            try:
                result = original(*args, **kwargs)
            except BaseException:
                self.finish(span, "failed")
                raise
            self.finish(span, "completed")
            return result

        self.patch(target, name, wrapped)

    def install(self, session_type, aligner_type, backend_type, load_module) -> None:
        original_transcribe = session_type.transcribe

        @wraps(original_transcribe)
        def transcribe(session, *args, **kwargs):
            if self.active is None:
                return original_transcribe(session, *args, **kwargs)
            original_progress = kwargs.get("on_progress")

            def on_progress(event):
                self.progress(event)
                if original_progress is not None:
                    original_progress(event)

            self.active["session_options"].append({key: kwargs.get(key) for key in
                ("return_timestamps", "diarize", "return_chunks", "language", "max_new_tokens", "forced_aligner")})
            kwargs["on_progress"] = on_progress
            try:
                result = original_transcribe(session, *args, **kwargs)
            except BaseException:
                self.finish_recognition("failed")
                raise
            for chunk in getattr(result, "chunks", None) or []:
                self.active["generation_chunks"].append({key: chunk.get(key) for key in
                    ("text", "start", "end", "language", "finish_reason", "truncated", "generated_tokens", "max_new_tokens")})
            return result

        def load_phase(*args, **kwargs):
            source = Path(args[0] if args else kwargs["path_or_hf_repo"]).expanduser().resolve()
            return ("asr_model_load" if source == self.model else
                    "forced_aligner_model_load" if source == self.aligner else "other_model_load")

        self.patch(session_type, "transcribe", transcribe)
        self.timed(aligner_type, "align", "forced_alignment_total")
        self.timed(aligner_type, "_ensure_loaded", "forced_aligner_prepare")
        self.timed(backend_type, "align", "forced_alignment_inference")
        self.timed(load_module, "_load_model_with_resolved_path", load_phase)

    def restore(self) -> None:
        for target, name, original in reversed(self.originals):
            setattr(target, name, original)
        self.originals.clear()


def run_measurements(report: dict, chunks: list[dict], transcriber, timing, probe: LibraryProbe, output: Path) -> None:
    def measured(label, action):
        recorder = timing.TimingRecorder(label)
        result = {"ok": False}
        started = time.monotonic_ns()
        with probe.measure() as library_timing:
            try:
                with timing.timing_context(recorder):
                    value = action()
                result["ok"] = True
            except Exception as error:
                value = None
                result["error"] = error_info(error)
                traceback.print_exc()
            finally:
                result["call_wall_ms"] = (time.monotonic_ns() - started) / 1_000_000
                result["phase_timing"] = recorder.snapshot()
        result["library_timing"] = library_timing
        return value, result

    _, initialization = measured("session_initialization", transcriber._load_qwen_mlx_session)
    report["initialization"] = initialization
    write_report(output, report)
    if not initialization["ok"]:
        report["status"] = "failed"
        write_report(output, report)
        return
    for pass_index, label in enumerate(PASS_LABELS, 1):
        current = {"index": pass_index, "label": label, "chunks": []}
        report["passes"].append(current)
        for chunk in chunks:
            segments, result = measured(
                f"pass_{pass_index}_chunk_{chunk['index']}",
                lambda: transcriber.transcribe_audio_chunk(
                    chunk["path"], offset_ms=chunk["start_ms"],
                    attach_diarization=False, preserve_words=True),
            )
            result.update({key: value for key, value in chunk.items() if key != "path"})
            result["segments"] = segments if segments is not None else []
            result["text"] = " ".join(item["text"] for item in result["segments"])
            current["chunks"].append(result)
            write_report(output, report)
        current["hypothesis_text"] = " ".join(item["text"] for item in current["chunks"] if item["text"])
        current["quality"] = quality_metrics(report["input"]["reference_text"], current["hypothesis_text"])
        current["queue_estimate"] = queue_estimate(current["chunks"])
        current["service_total_ms"] = sum(item["call_wall_ms"] for item in current["chunks"])
        current["failed_chunks"] = sum(not item["ok"] for item in current["chunks"])
        write_report(output, report)
    report["status"] = "failed" if any(item["failed_chunks"] for item in report["passes"]) else "completed"
    write_report(output, report)


def worker(args) -> int:
    report = {
        "schema_version": 1, "experiment": "qwen_live_core_first_58s", "status": "running",
        "request": {key: str(getattr(args, key)) for key in ("runtime_root", "model", "input", "reference", "output")},
        "protocol": {"sample_rate": SAMPLE_RATE, "boundaries_ms": BOUNDARIES_MS, "passes": 2,
                     "attach_diarization": False, "preserve_words": True},
        "limitations": [
            "Core transcriber service only: no live capture, RPC, enrichment, summaries, database, or UI.",
            "First pass is process-fresh after model/session load; OS file caches are uncontrolled; first speech may still load VAD, aligner, and MLX graphs.",
            "Second pass immediately repeats identical chunks in the same process; it is not an independent cold run.",
            "Phase spans are inclusive and nested; do not sum all durations. No additional MLX synchronization is inserted.",
            "ASR phase covers features, generation, and parsing until alignment entry, or chunk completion if alignment is skipped.",
            "Chinese CER extracts NFKC Han characters. English WER extracts lowercase ASCII words and numbers, retaining apostrophes.",
            "Whole-pass quality preserves emission order without deduplication; this frozen synthetic slice is not a natural-meeting quality baseline.",
            "The first 2-second chunk of the supplied short-mixed fixture is silence; no text in that chunk is expected.",
        ],
        "passes": [],
    }
    write_report(args.output, report)
    probe = None
    try:
        os.environ.update({"HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1"})
        asr = read_asr_config(args.runtime_config)
        model = resolve_model(args.model)
        environment = model_environment(asr, model, dict(os.environ))
        aligner = validate_local_model(Path(environment["INSIGHTKIT_QWEN_FORCED_ALIGNER_PATH"]))
        os.environ.update(environment)
        with tempfile.TemporaryDirectory(prefix="insightkit-qwen-58s-") as temporary:
            report["input"], chunks = prepare_input(args.input, args.reference, Path(temporary))
            root = args.runtime_root.resolve()
            sys.path.insert(0, str(root))
            started = time.monotonic_ns()
            transcriber = importlib.import_module("scripts.transcriber")
            timing = importlib.import_module("insightkit.phase_timing")
            import_ms = (time.monotonic_ns() - started) / 1_000_000
            for module, relative in ((transcriber, "scripts/transcriber.py"), (timing, "insightkit/phase_timing.py")):
                if Path(module.__file__).resolve() != (root / relative).resolve():
                    raise RuntimeError(f"runtime import did not resolve --runtime-root: {relative}")
            if Path(transcriber._resolve_qwen_mlx_source()).resolve() != model:
                raise RuntimeError("runtime resolved a different ASR model")
            if Path(transcriber._resolve_qwen_forced_aligner_source() or "").resolve() != aligner:
                raise RuntimeError("runtime resolved a different forced aligner")
            started = time.monotonic_ns()
            session_module = importlib.import_module("mlx_qwen3_asr.session")
            aligner_module = importlib.import_module("mlx_qwen3_asr.forced_aligner")
            load_module = importlib.import_module("mlx_qwen3_asr.load_models")
            probe_import_ms = (time.monotonic_ns() - started) / 1_000_000
            probe = LibraryProbe(model, aligner)
            probe.install(session_module.Session, aligner_module.ForcedAligner,
                          aligner_module._MLXForcedAlignerBackend, load_module)
            versions = {}
            for package in ("mlx", "mlx-qwen3-asr", "numpy", "torch", "huggingface-hub"):
                try:
                    versions[package] = importlib.metadata.version(package)
                except importlib.metadata.PackageNotFoundError:
                    versions[package] = None
            git = subprocess.run(["git", "-C", str(root), "rev-parse", "HEAD"], capture_output=True, text=True, check=False)
            env_keys = (*MODEL_KEYS, "INSIGHTKIT_ASR_ENGINE", "INSIGHTKIT_MODEL_DIR", "INSIGHTKIT_ASR_STRICT_LOCAL_ONLY",
                        "INSIGHTKIT_QWEN_MLX_MODEL_PATH", "INSIGHTKIT_QWEN_FORCED_ALIGNER_PATH", "INSIGHTKIT_QWEN_RETURN_TIMESTAMPS",
                        "INSIGHTKIT_VAD_ENABLED", "INSIGHTKIT_DIARIZATION_ENABLED", "INSIGHTKIT_QWEN_LANGUAGE",
                        "INSIGHTKIT_QWEN_MAX_NEW_TOKENS", "HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE")
            report["runtime"] = {
                "python": sys.executable, "python_version": platform.python_version(), "platform": platform.platform(),
                "runtime_root": str(root), "runtime_git_revision": git.stdout.strip() if git.returncode == 0 else None,
                "transcriber_sha256": sha256_file(Path(transcriber.__file__)),
                "phase_timing_sha256": sha256_file(Path(timing.__file__)),
                "library_versions": versions, "runtime_import_ms": import_ms, "probe_import_ms": probe_import_ms,
                "asr_model_path": str(model), "asr_config_sha256": sha256_file(model / "config.json"),
                "aligner_model_path": str(aligner), "aligner_config_sha256": sha256_file(aligner / "config.json"),
                "runtime_config_sha256": sha256_file(args.runtime_config) if args.runtime_config else None,
                "environment": {key: os.environ[key] for key in env_keys if key in os.environ},
            }
            write_report(args.output, report)
            run_measurements(report, chunks, transcriber, timing, probe, args.output)
    except Exception as error:
        report["status"] = "failed"
        report["fatal_error"] = error_info(error)
        traceback.print_exc()
        write_report(args.output, report)
    finally:
        if probe is not None:
            probe.restore()
    return 0 if report["status"] == "completed" else 1


def driver(args) -> int:
    stdout_path, stderr_path = Path(str(args.output) + ".stdout.log"), Path(str(args.output) + ".stderr.log")
    for path in (args.output, stdout_path, stderr_path):
        if path.exists():
            raise ValueError(f"refusing to overwrite experiment evidence: {path}")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    command = [sys.executable, str(Path(__file__).resolve()), "--worker", "--runtime-root", str(args.runtime_root),
               "--model", args.model, "--input", str(args.input), "--reference", str(args.reference), "--output", str(args.output)]
    if args.runtime_config:
        command.extend(["--runtime-config", str(args.runtime_config)])
    started = time.monotonic_ns()
    process = {"command": command, "timeout_seconds": args.timeout_seconds,
               "stdout_path": str(stdout_path), "stderr_path": str(stderr_path)}
    child_env = dict(os.environ, HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", PYTHONDONTWRITEBYTECODE="1")
    with stdout_path.open("x") as stdout, stderr_path.open("x") as stderr:
        os.chmod(stdout_path, 0o600)
        os.chmod(stderr_path, 0o600)
        try:
            completed = subprocess.run(command, env=child_env, stdout=stdout, stderr=stderr,
                                       timeout=args.timeout_seconds, check=False)
            process["returncode"] = completed.returncode
        except subprocess.TimeoutExpired as error:
            process.update({"returncode": None, "timed_out": True, "error": error_info(error)})
        except OSError as error:
            process.update({"returncode": None, "error": error_info(error)})
    process["wall_ms"] = (time.monotonic_ns() - started) / 1_000_000
    report = json.loads(args.output.read_text()) if args.output.exists() else {
        "schema_version": 1, "status": "failed", "passes": [],
        "fatal_error": {"type": "WorkerDidNotReport", "message": "See subprocess logs"}}
    report["process"] = process
    if process["returncode"] != 0 or report.get("status") != "completed":
        report["status"] = "failed"
    write_report(args.output, report)
    print(json.dumps({"status": report["status"], "output": str(args.output)}, ensure_ascii=False))
    return 0 if report["status"] == "completed" else 1


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime-root", required=True, type=Path, help="Accepted runtime checkout to import read-only")
    parser.add_argument("--model", required=True, help="Absolute downloaded model path, or full HF repo ID resolved offline")
    parser.add_argument("--input", required=True, type=Path, help="Frozen mono 16-kHz PCM16 WAV, at least 58 seconds")
    parser.add_argument("--reference", required=True, type=Path, help="Reference JSON with millisecond segments")
    parser.add_argument("--runtime-config", type=Path, help="ASR config snapshot; only its asr fields are used")
    parser.add_argument("--output", required=True, type=Path, help="New JSON result file; sibling stdout/stderr logs are retained")
    parser.add_argument("--timeout-seconds", type=int, default=600, help="Fresh worker process limit (default 600 seconds)")
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    for key in ("runtime_root", "input", "reference", "runtime_config", "output"):
        value = getattr(args, key)
        if value is not None:
            setattr(args, key, value.expanduser().resolve())
    if not 1 <= args.timeout_seconds <= 1800:
        parser.error("--timeout-seconds must be between 1 and 1800")
    try:
        return worker(args) if args.worker else driver(args)
    except (OSError, ValueError) as error:
        print(json.dumps({"status": "failed", "error": error_info(error)}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
