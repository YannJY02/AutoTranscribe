"""Exercise experiment failure receipts without downloading or loading a model."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
from types import ModuleType, SimpleNamespace
import venv

import pytest

from scripts import compare_local_summary as runner


def empty_package():
    return {
        "session_overview": {"title": "Synthetic", "overview": "Input.", "topics": []},
        "highlight_insights": [], "speaker_perspectives": [], "decision_ledger": [],
        "action_tracks": [], "timeline_beats": [], "provenance_links": [],
    }


@pytest.mark.parametrize("raw", ["NaN", '{"session_overview": NaN}', '{"x": 1e400}'])
def test_nonfinite_output_retains_a_serializable_failure_receipt(tmp_path, raw):
    result = runner.product_pipeline(raw, [])
    assert result["strict_pipeline_status"] == "failed"
    assert result["raw_payload"] is None
    assert result["postprocessed_payload"] is None
    runner.write_json(tmp_path / "result.json", result)
    assert json.loads((tmp_path / "result.json").read_text())["error"]["type"] == "ValueError"


@pytest.mark.parametrize("raw", ['{"session_overview": {}}', '```json\n{}\n```', '{"truncated":'])
def test_invalid_raw_does_not_reach_product_repair(monkeypatch, raw):
    import insightkit.insights.postprocess as postprocess

    def forbidden(*args, **kwargs):
        pytest.fail("invalid raw output must not reach product repair")

    monkeypatch.setattr(postprocess, "postprocess_insight_package", forbidden)
    result = runner.product_pipeline(raw, [])
    assert result["raw_schema_valid"] is False
    assert result["postprocessed_payload"] is None


def test_product_mutation_keeps_the_original_payload(monkeypatch):
    import insightkit.insights.postprocess as postprocess

    def repair(payload, **kwargs):
        payload["session_overview"]["title"] = "Repaired"
        return payload

    monkeypatch.setattr(postprocess, "postprocess_insight_package", repair)
    result = runner.product_pipeline(json.dumps(empty_package()), [])
    assert result["strict_pipeline_status"] == "passed"
    assert result["raw_payload"]["session_overview"]["title"] == "Synthetic"
    assert result["postprocessed_payload"]["session_overview"]["title"] == "Repaired"


def test_live_input_uses_native_inclusive_window_and_exact_prompt():
    from insightkit.insights.service import LIVE_PROMPT, SYSTEM_PROMPT

    segments = [{"start_ms": end - 1, "end_ms": end, "speaker": "A", "text": str(end)}
                for end in (9_999, 10_000, 130_000)]
    request = runner.make_request({"id": "window", "mode": "live", "transcript": segments})
    assert request["request_transcript"] == segments[1:]
    assert request["system_prompt"] == SYSTEM_PROMPT
    assert request["user_prompt"] == LIVE_PROMPT.replace("{{TRANSCRIPT_WINDOW_JSON}}", json.dumps(segments[1:], ensure_ascii=False))
    assert len(segments) == 3


def test_model_manifest_rejects_changed_or_unlisted_weights(tmp_path):
    files = {"config.json": json.dumps({"model_type": "qwen3_5", "quantization": {"bits": 4}}),
             "tokenizer_config.json": "{}", "tokenizer.json": "{}", "model.safetensors": "fake-weight"}
    for name, content in files.items():
        (tmp_path / name).write_text(content)
    manifest = {"repo_id": runner.MODEL_REPO, "revision": "a" * 40, "files": [
        {"name": name, "bytes": (tmp_path / name).stat().st_size, "sha256": runner.file_sha256(tmp_path / name)}
        for name in files]}
    manifest_path = tmp_path / "manifest.json"
    runner.write_json(manifest_path, manifest)
    runner.verify_model_manifest(tmp_path, manifest_path)
    (tmp_path / "unlisted.safetensors").write_text("extra")
    with pytest.raises(ValueError, match="every loadable"):
        runner.verify_model_manifest(tmp_path, manifest_path)
    (tmp_path / "unlisted.safetensors").unlink()
    (tmp_path / "model.safetensors").write_text("changed")
    with pytest.raises(ValueError, match="does not match"):
        runner.verify_model_manifest(tmp_path, manifest_path)


def test_venv_symlink_remains_an_environment_entrypoint(tmp_path):
    env_path = tmp_path / "venv"
    venv.EnvBuilder(with_pip=False, symlinks=True).create(env_path)
    executable = runner.worker_command(env_path / "bin/python", tmp_path / "plan.json")[0]
    result = subprocess.check_output([executable, "-c", "import sys; print(sys.prefix)"], text=True)
    assert Path(result.strip()) == env_path


def test_worker_environment_does_not_inherit_provider_credentials_or_routing(tmp_path, monkeypatch):
    for name in ("OPENAI_API_KEY", "HF_TOKEN", "INSIGHTKIT_ANALYSIS_MODE", "INSIGHTKIT_PROVIDER_VENDOR"):
        monkeypatch.setenv(name, "must-not-reach-worker")
    environment = runner.isolated_environment(tmp_path)
    assert not any(value == "must-not-reach-worker" for value in environment.values())
    assert environment["HF_HUB_OFFLINE"] == "1"
    assert environment["HF_HUB_DISABLE_IMPLICIT_TOKEN"] == "1"


def test_case_subset_keeps_frozen_inputs_and_explicit_order():
    from scripts.local_summary_assessment import load_contract

    cases = load_contract()["cases"]
    identifiers = [cases[6]["id"], cases[3]["id"]]
    selected = runner.select_cases(cases, identifiers)
    assert selected == [cases[6], cases[3]]
    assert [request["case"]["id"] for request in map(runner.make_request, selected)] == identifiers
    assert len(cases) == 8


@pytest.mark.parametrize("identifiers", [[], ["missing"], ["same", "same"]])
def test_case_subset_rejects_empty_unknown_or_duplicate_ids(identifiers):
    with pytest.raises(ValueError, match="unique cases"):
        runner.select_cases([{"id": "same"}], identifiers)


def test_model_selection_must_match_manifest_before_loading(tmp_path):
    manifest = tmp_path / "manifest.json"
    runner.write_json(manifest, {"repo_id": runner.MODEL_REPO, "revision": "a" * 40})
    with pytest.raises(ValueError, match="selected repository"):
        runner.verify_model_manifest(tmp_path, manifest, expected_repo="mlx-community/Qwen3.5-4B-4bit")


def test_conditional_4b_plan_has_no_new_or_repeated_inputs():
    from scripts.local_summary_assessment import load_contract

    contract = load_contract()
    plan = json.loads((runner.ROOT / "evals/local_summary/v1/qwen-4b-screen.json").read_text())
    assert plan["baseline_dataset_sha256"] == contract["dataset_sha256"]
    stage_a, stage_b = plan["stage_a"]["case_ids"], plan["stage_b"]["case_ids"]
    assert len(stage_a) == 5 and len(stage_b) == 3
    assert not set(stage_a) & set(stage_b)
    assert set(stage_a + stage_b) == {case["id"] for case in contract["cases"]}


def fake_command(code):
    return [sys.executable, "-u", "-c", code]


def test_supervisor_times_out_kills_worker_and_preserves_partial_text(tmp_path):
    raw = tmp_path / "first.raw.txt"
    code = (
        "import json, signal, time; from pathlib import Path; "
        "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
        "print(json.dumps({'event':'ready'}), flush=True); "
        "print(json.dumps({'event':'case_started','id':'first'}), flush=True); "
        f"Path({str(raw)!r}).write_text('partial'); time.sleep(20)"
    )
    result = runner.supervise(fake_command(code), tmp_path, load_timeout=5, request_timeout=0.2, environment=os.environ.copy())
    assert result["termination"] == {"reason": "wall_timeout", "phase": "request", "case_id": "first"}
    assert result["exit_code"] != 0
    assert raw.read_text() == "partial"


@pytest.mark.parametrize("output", ["not-json", "[]", '{"event":'])
def test_supervisor_rejects_unstructured_stdout(tmp_path, output):
    with pytest.raises(RuntimeError, match="protocol"):
        runner.supervise(fake_command(f"print({output!r})"), tmp_path, load_timeout=5, request_timeout=5, environment=os.environ.copy())


def test_controller_records_all_cases_after_early_exit(tmp_path, monkeypatch):
    plan = {"requests": [{"case": {"id": "first"}}, {"case": {"id": "second"}}]}
    monkeypatch.setattr(runner, "make_plan", lambda args: plan)

    def failed_supervisor(command, output, **kwargs):
        (output / "first.raw.txt").write_text("partial")
        return {"exit_code": -15, "termination": {"case_id": "first", "reason": "wall_timeout"}}

    monkeypatch.setattr(runner, "supervise", failed_supervisor)
    output = tmp_path / "run"
    args = argparse.Namespace(output=output, python=Path(sys.executable), load_timeout=1, request_timeout=1)
    assert runner.controller(args) == 2
    manifest = json.loads((output / "manifest.json").read_text())
    assert [row["status"] for row in manifest["results"]] == ["timed_out", "not_run"]
    assert json.loads((output / "first.json").read_text())["raw_text"] == "partial"


def test_worker_own_timeout_never_starts_the_next_request(tmp_path, monkeypatch):
    calls = []
    core = ModuleType("mlx.core")
    core.synchronize = lambda: None
    core.reset_peak_memory = lambda: None
    core.random = SimpleNamespace(seed=lambda _: None)
    mlx = ModuleType("mlx")
    mlx.core = core
    lm = ModuleType("mlx_lm")
    lm.load = lambda *args, **kwargs: (object(), SimpleNamespace(apply_chat_template=lambda *args, **kwargs: [1]))

    def generate(*args, **kwargs):
        calls.append("generate")
        yield SimpleNamespace(text="partial")

    lm.stream_generate = generate
    sampler = ModuleType("mlx_lm.sample_utils")
    sampler.make_sampler = lambda **kwargs: None
    for name, module in (("mlx", mlx), ("mlx.core", core), ("mlx_lm", lm), ("mlx_lm.sample_utils", sampler)):
        monkeypatch.setitem(sys.modules, name, module)
    monkeypatch.setattr(runner.importlib.metadata, "version", lambda _: "fake")
    plan_path = tmp_path / "plan.json"
    runner.write_json(plan_path, {
        "generation": {"seed": 7, "max_tokens": 3, "request_timeout_s": -1}, "model_path": "fake",
        "requests": [{"case": {"id": name, "mode": "final"}, "system_prompt": "", "user_prompt": ""}
                     for name in ("first", "second")],
    })
    assert runner.worker(plan_path) == 2
    assert calls == ["generate"]
    assert json.loads((tmp_path / "first.json").read_text())["status"] == "timed_out"
    assert (tmp_path / "first.raw.txt").read_text() == "partial"
    assert not (tmp_path / "second.raw.txt").exists()
