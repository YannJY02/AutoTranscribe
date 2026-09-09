#!/usr/bin/env python3
"""Bounded, offline Qwen text-summary experiment; never a production provider.

Run the controller inside the repository's installed-app resource lock. Model
acquisition and the idle/preservation receipt are separate preflight operations.
The worker loads one model, starts a fresh prompt cache for every request, and
keeps the raw output even when strict product validation rejects it.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import importlib.metadata
import json
import math
import os
from pathlib import Path
import platform
import re
import selectors
import signal
import subprocess
import sys
import time
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

MODEL_REPO = "mlx-community/Qwen3.5-2B-4bit"
MODEL_REPOS = (MODEL_REPO, "mlx-community/Qwen3.5-4B-4bit")
MAX_REQUESTS = 8
SOURCE_FILES = (
    "insightkit/prompts/system_instruction.md",
    "insightkit/prompts/live_insight_prompt.md",
    "insightkit/prompts/final_insight_prompt.md",
    "insightkit/schemas/insight_package_v1.json",
    "insightkit/insights/service.py",
    "insightkit/insights/postprocess.py",
    "insightkit/insights/schema_validator.py",
)


def file_sha256(path: Path) -> str:
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def canonical_sha256(value: Any) -> str:
    return hashlib.sha256(
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def write_json(path: Path, value: Any) -> None:
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n")
    temporary.replace(path)


def finite_number(value: float | int | None) -> float | int | None:
    return value if value is not None and math.isfinite(value) else None


def strict_json_loads(raw: str) -> Any:
    def reject_constant(value: str) -> Any:
        raise ValueError(f"non-finite JSON constant: {value}")

    def parse_float(value: str) -> float:
        parsed = float(value)
        if not math.isfinite(parsed):
            raise ValueError(f"non-finite JSON number: {value}")
        return parsed

    return json.loads(raw, parse_constant=reject_constant, parse_float=parse_float)


def worker_command(python: Path, plan_path: Path) -> list[str]:
    # Resolving this symlink loses pyvenv.cfg and all experiment dependencies.
    return [str(python.absolute()), str(Path(__file__).resolve()), "worker", "--plan", str(plan_path)]


def verify_model_manifest(model_path: Path, manifest_path: Path, *, expected_repo: str = MODEL_REPO) -> dict:
    model_path = model_path.resolve(strict=True)
    manifest = json.loads(manifest_path.read_text())
    if expected_repo not in MODEL_REPOS or manifest.get("repo_id") != expected_repo or not re.fullmatch(
        r"[0-9a-f]{40}", str(manifest.get("revision", ""))
    ):
        raise ValueError("model manifest must pin the selected repository and commit")
    names = set()
    for item in manifest.get("files", []):
        name = item.get("name", "")
        if not isinstance(name, str) or Path(name).name != name or name in names:
            raise ValueError("model manifest contains an unsafe or duplicate filename")
        path = model_path / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"model file is missing or is a symlink: {name}")
        if path.stat().st_size != item.get("bytes") or file_sha256(path) != item.get("sha256"):
            raise ValueError(f"model file does not match frozen manifest: {name}")
        names.add(name)
    if not {"config.json", "tokenizer_config.json", "tokenizer.json"}.issubset(names):
        raise ValueError("model manifest lacks configuration or tokenizer files")
    weights = {p.name for p in model_path.glob("*.safetensors")}
    if not weights or not weights.issubset(names):
        raise ValueError("every loadable weight file must be in the frozen manifest")
    config = json.loads((model_path / "config.json").read_text())
    if config.get("model_type") != "qwen3_5" or config.get("quantization", {}).get("bits") != 4:
        raise ValueError("expected the selected Qwen3.5 four-bit configuration")
    return manifest


def request_transcript(case: dict) -> list[dict]:
    transcript = copy.deepcopy(case["transcript"])
    if case["mode"] == "live" and transcript:
        # Match InsightCoordinator's current transcript-window boundary. This
        # does not claim that diarization labels are stable in the real app.
        lower = max(0, transcript[-1]["end_ms"] - 120_000)
        transcript = [segment for segment in transcript if segment["end_ms"] >= lower]
    return transcript


def make_request(case: dict) -> dict:
    mode = case.get("mode")
    identifier = case.get("id", "")
    if mode not in {"live", "final"} or not re.fullmatch(r"[a-zA-Z0-9_-]{1,100}", identifier):
        raise ValueError("case has invalid mode or identifier")
    transcript = request_transcript(case)
    template_name = "live_insight_prompt.md" if mode == "live" else "final_insight_prompt.md"
    marker = "{{TRANSCRIPT_WINDOW_JSON}}" if mode == "live" else "{{FULL_TRANSCRIPT_JSON}}"
    template = (ROOT / "insightkit/prompts" / template_name).read_text()
    return {
        "case": case,
        "request_transcript": transcript,
        "transcript_sha256": canonical_sha256(transcript),
        "system_prompt": (ROOT / "insightkit/prompts/system_instruction.md").read_text(),
        "user_prompt": template.replace(marker, json.dumps(transcript, ensure_ascii=False)),
    }


def select_cases(cases: list[dict], identifiers: list[str] | None) -> list[dict]:
    if identifiers is None:
        return cases
    by_id = {case["id"]: case for case in cases}
    if (not identifiers or len(identifiers) != len(set(identifiers))
            or any(identifier not in by_id for identifier in identifiers)):
        raise ValueError("case selection must name unique cases from the frozen contract")
    return [by_id[identifier] for identifier in identifiers]


def make_plan(args: argparse.Namespace) -> dict:
    from scripts.local_summary_assessment import load_contract

    if not 1 <= args.max_tokens <= 4096 or not 0 < args.request_timeout <= 300:
        raise ValueError("generation must have bounded tokens and request timeout")
    if not 0 < args.load_timeout <= 300:
        raise ValueError("model loading must have a bounded timeout")
    contract = load_contract(args.dataset)
    cases = select_cases(contract["cases"], args.case_ids)
    if not 1 <= len(cases) <= MAX_REQUESTS or len({case["id"] for case in cases}) != len(cases):
        raise ValueError("the plan must contain one to eight unique requests")
    manifest = verify_model_manifest(args.model_path, args.model_manifest, expected_repo=args.model_repo)
    requests = [make_request(case) for case in cases]
    return {
        "schema_version": 1,
        "issue": "YAN-77",
        "dataset_version": contract["dataset_version"],
        "dataset_sha256": contract["dataset_sha256"],
        "selection": {
            "available_case_count": len(contract["cases"]),
            "selected_case_ids": [case["id"] for case in cases],
        },
        "model": manifest,
        "model_path": str(args.model_path.resolve()),
        "source_files": {name: file_sha256(ROOT / name) for name in SOURCE_FILES},
        "generation": {
            "max_tokens": args.max_tokens,
            "request_timeout_s": args.request_timeout,
            "load_timeout_s": args.load_timeout,
            "temperature": 0.0,
            "seed": 7,
            "enable_thinking": False,
            "model_reuse": "one loaded model for every request",
            "prompt_cache_reuse": False,
            "previous_generated_summary_in_input": False,
        },
        "requests": requests,
        "limits": [
            "Only frozen synthetic text; no audio, live ASR, diarization or product UI.",
            "First request follows download/hash/load, not a rebooted-machine cold baseline.",
            "Token latency is not the time a complete Smart Minutes package can be displayed.",
            "Structural assessment does not establish semantic fidelity; item review is required.",
        ],
    }


def isolated_environment(output: Path) -> dict[str, str]:
    # Keep the real home and shell search path, but do not pass provider keys,
    # telemetry options or the running app's analysis routing into the worker.
    environment = {key: os.environ[key] for key in ("HOME", "PATH", "TMPDIR", "LANG", "LC_ALL") if key in os.environ}
    environment.update({
        "PYTHONUNBUFFERED": "1",
        "PYTHONPATH": str(ROOT),
        "HF_HOME": str(output / "hf-cache"),
        "HF_HUB_OFFLINE": "1",
        "TRANSFORMERS_OFFLINE": "1",
        "HF_HUB_DISABLE_TELEMETRY": "1",
        "HF_HUB_DISABLE_IMPLICIT_TOKEN": "1",
        "TOKENIZERS_PARALLELISM": "false",
    })
    return environment


def product_pipeline(raw: str, transcript: list[dict]) -> dict:
    from insightkit.insights.postprocess import postprocess_insight_package
    from insightkit.insights.schema_validator import validate_insight_package

    result: dict[str, Any] = {"raw_payload": None, "postprocessed_payload": None, "raw_schema_valid": False, "strict_pipeline_status": "failed"}
    started = time.perf_counter()
    try:
        result["raw_payload"] = strict_json_loads(raw)
        validate_insight_package(result["raw_payload"])
        result["raw_schema_valid"] = True
        # The product validates before postprocessing. Do not quietly repair
        # malformed raw output and then call the model schema compliant.
        processed = postprocess_insight_package(copy.deepcopy(result["raw_payload"]), full_transcript=transcript)
        validate_insight_package(processed)
        result["postprocessed_payload"] = processed
        result["strict_pipeline_status"] = "passed"
    except Exception as error:
        result["error"] = {"type": type(error).__name__, "message": str(error)[:3000]}
    result["pipeline_wall_s"] = time.perf_counter() - started
    return result


def emit(message: dict) -> None:
    print(json.dumps(message, ensure_ascii=False, allow_nan=False), flush=True)


def worker(plan_path: Path) -> int:
    # Optional model dependencies are imported only in the isolated worker.
    import mlx.core as mx
    from mlx_lm import load, stream_generate
    from mlx_lm.sample_utils import make_sampler
    from scripts.local_summary_assessment import assess_pair

    plan = json.loads(plan_path.read_text())
    output = plan_path.parent
    parameters = plan["generation"]
    emit({"event": "load_started"})
    started = time.perf_counter()
    model, tokenizer = load(plan["model_path"], tokenizer_config={"trust_remote_code": False}, lazy=False)
    mx.synchronize()
    runtime = {
        "model_load_wall_s": time.perf_counter() - started,
        "packages": {name: importlib.metadata.version(name) for name in (
            "mlx", "mlx-lm", "mlx-metal", "transformers", "huggingface-hub", "jsonschema"
        )},
        "python": platform.python_version(),
        "platform": platform.platform(),
        "machine": platform.machine(),
        "model_class": type(model).__module__ + "." + type(model).__name__,
        "language_only_loader": True,
    }
    write_json(output / "runtime.json", runtime)
    emit({"event": "ready", **runtime})
    for index, request in enumerate(plan["requests"]):
        case = request["case"]
        identifier = case["id"]
        emit({"event": "case_started", "id": identifier, "index": index})
        result: dict[str, Any] = {"id": identifier, "index": index, "mode": case["mode"], "status": "failed"}
        request_started = time.perf_counter()
        raw_path = output / f"{identifier}.raw.txt"
        raw = ""
        try:
            mx.random.seed(parameters["seed"])
            mx.reset_peak_memory()
            messages = [{"role": "system", "content": request["system_prompt"]}, {"role": "user", "content": request["user_prompt"]}]
            prompt = tokenizer.apply_chat_template(messages, tokenize=True, add_generation_prompt=True, enable_thinking=False)
            result["formatted_prompt_tokens"] = len(prompt)
            result["formatted_prompt_ids_sha256"] = canonical_sha256(prompt)
            generation_started = time.perf_counter()
            response = None
            with raw_path.open("w", encoding="utf-8") as raw_file:
                for response in stream_generate(model, tokenizer, prompt, max_tokens=parameters["max_tokens"], sampler=make_sampler(temp=0.0)):
                    now = time.perf_counter()
                    result.setdefault("first_token_wall_s", now - request_started)
                    if response.text:
                        result.setdefault("first_text_wall_s", now - request_started)
                        raw_file.write(response.text)
                        raw_file.flush()
                        raw += response.text
                    if now - request_started > parameters["request_timeout_s"]:
                        raise TimeoutError("request exceeded the recorded wall-clock limit")
            mx.synchronize()
            result["generation_wall_s"] = time.perf_counter() - generation_started
            if response is None:
                raise RuntimeError("model yielded no generation response")
            result.update({
                "finish_reason": response.finish_reason,
                "generation_tokens_including_stop": response.generation_tokens,
                "library_prompt_tokens": response.prompt_tokens,
                "library_prompt_tps": finite_number(response.prompt_tps),
                "library_generation_tps": finite_number(response.generation_tps),
                "mlx_peak_memory_gb": finite_number(response.peak_memory),
                "truncated": response.finish_reason == "length",
            })
            result["pipeline"] = product_pipeline(raw, request["request_transcript"])
            if not result["truncated"] and result["pipeline"]["strict_pipeline_status"] == "passed":
                result["complete_package_available_wall_s"] = time.perf_counter() - request_started
            result["assessment"] = assess_pair(case, raw_payload=result["pipeline"]["raw_payload"], postprocessed_payload=result["pipeline"]["postprocessed_payload"])
            result["status"] = "completed"
        except Exception as error:
            result["error"] = {"type": type(error).__name__, "message": str(error)[:3000]}
            if isinstance(error, TimeoutError):
                result["status"] = "timed_out"
        result["request_wall_s"] = time.perf_counter() - request_started
        result["raw_text"] = raw_path.read_text() if raw_path.exists() else ""
        result["raw_text_sha256"] = hashlib.sha256(result["raw_text"].encode()).hexdigest()
        write_json(output / f"{identifier}.json", result)
        emit({"event": "case_complete", "id": identifier, "status": result["status"], "finish_reason": result.get("finish_reason"), "strict_pipeline_status": result.get("pipeline", {}).get("strict_pipeline_status")})
        if result["status"] == "timed_out":
            emit({"event": "stopped", "reason": "request_timeout", "id": identifier})
            return 2
    emit({"event": "finished"})
    return 0


def stop_process_group(process: subprocess.Popen) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)
    except ProcessLookupError:
        process.wait(timeout=5)


def supervise(command: list[str], output: Path, *, load_timeout: float, request_timeout: float, environment: dict[str, str]) -> dict:
    started = time.monotonic()
    messages = []
    active_case = None
    phase = "loading"
    termination = None
    with (output / "worker.stderr.log").open("w") as stderr, (output / "worker-events.jsonl").open("w") as events:
        process = subprocess.Popen(command, cwd=ROOT, env=environment, stdout=subprocess.PIPE, stderr=stderr, start_new_session=True)
        assert process.stdout is not None
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        buffer = b""
        deadline = time.monotonic() + load_timeout
        try:
            while selector.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    termination = {"reason": "wall_timeout", "phase": phase, "case_id": active_case}
                    stop_process_group(process)
                    break
                for key, _ in selector.select(min(0.2, remaining)):
                    chunk = os.read(key.fileobj.fileno(), 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    buffer += chunk
                    while b"\n" in buffer:
                        line, buffer = buffer.split(b"\n", 1)
                        if not line:
                            continue
                        try:
                            message = strict_json_loads(line)
                        except (ValueError, json.JSONDecodeError):
                            raise RuntimeError("worker stdout violated the structured event protocol")
                        if not isinstance(message, dict) or not isinstance(message.get("event"), str):
                            raise RuntimeError("worker stdout violated the structured event protocol")
                        message["controller_received_wall_s"] = time.monotonic() - started
                        messages.append(message)
                        events.write(json.dumps(message, ensure_ascii=False) + "\n")
                        events.flush()
                        event = message.get("event")
                        if event == "ready":
                            phase = "between_requests"
                            deadline = time.monotonic() + 15
                        elif event == "case_started":
                            active_case = message["id"]
                            phase = "request"
                            deadline = time.monotonic() + request_timeout
                        elif event == "case_complete":
                            active_case = None
                            phase = "between_requests"
                            deadline = time.monotonic() + 15
                        elif event == "finished":
                            phase = "shutdown"
                            deadline = time.monotonic() + 15
                        elif event == "stopped":
                            termination = {"reason": message["reason"], "phase": "request", "case_id": message["id"]}
                            phase = "shutdown"
                            deadline = time.monotonic() + 5
            if buffer.strip() and termination is None:
                raise RuntimeError("worker stdout ended with an incomplete event")
            process.wait(timeout=5)
        except BaseException:
            if process.poll() is None:
                stop_process_group(process)
            raise
        finally:
            selector.close()
            process.stdout.close()
    return {"exit_code": process.returncode, "termination": termination, "messages": messages, "controller_wall_s": time.monotonic() - started}


def controller(args: argparse.Namespace) -> int:
    plan = make_plan(args)  # Verify all input/weight hashes before starting MLX.
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    plan_path = output / "plan.json"
    write_json(plan_path, plan)
    command = worker_command(args.python, plan_path)
    try:
        execution = supervise(command, output, load_timeout=args.load_timeout, request_timeout=args.request_timeout, environment=isolated_environment(output))
    except Exception as error:
        execution = {"exit_code": None, "termination": {"reason": "controller_error", "error_type": type(error).__name__, "message": str(error)[:3000]}}
    results = []
    for request in plan["requests"]:
        identifier = request["case"]["id"]
        result_path = output / f"{identifier}.json"
        if result_path.exists():
            result = json.loads(result_path.read_text())
        else:
            timed_out = (execution.get("termination") or {}).get("case_id") == identifier
            raw_path = output / f"{identifier}.raw.txt"
            raw = raw_path.read_text() if raw_path.exists() else ""
            result = {"id": identifier, "status": "timed_out" if timed_out else "not_run", "raw_text": raw, "raw_text_sha256": hashlib.sha256(raw.encode()).hexdigest(), "reason": execution.get("termination") or "worker_exited_before_result"}
            write_json(result_path, result)
        results.append({"id": identifier, "status": result["status"], "result_file": result_path.name, "result_sha256": file_sha256(result_path)})
    complete = execution["exit_code"] == 0 and all(row["status"] == "completed" for row in results)
    manifest = {"status": "completed" if complete else "stopped_with_failures", "plan_sha256": file_sha256(plan_path), "execution": execution, "results": results, "semantic_review": "pending"}
    write_json(output / "manifest.json", manifest)
    print(json.dumps({"status": manifest["status"], "requests": len(results), "output": str(output)}, ensure_ascii=False))
    return 0 if complete else 2


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    run = subparsers.add_parser("run")
    run.add_argument("--dataset", type=Path, default=ROOT / "evals/local_summary/v1/dataset.json")
    run.add_argument("--model-path", type=Path, required=True)
    run.add_argument("--model-manifest", type=Path, required=True)
    run.add_argument("--model-repo", choices=MODEL_REPOS, default=MODEL_REPO)
    run.add_argument("--case", dest="case_ids", action="append", help="Frozen case ID; repeat in the preregistered order. Defaults to all eight.")
    run.add_argument("--python", type=Path, required=True)
    run.add_argument("--output", type=Path, required=True)
    run.add_argument("--max-tokens", type=int, default=1536)
    run.add_argument("--request-timeout", type=float, default=120)
    run.add_argument("--load-timeout", type=float, default=120)
    internal = subparsers.add_parser("worker")
    internal.add_argument("--plan", type=Path, required=True)
    args = parser.parse_args(argv)
    return worker(args.plan) if args.command == "worker" else controller(args)


if __name__ == "__main__":
    raise SystemExit(main())
